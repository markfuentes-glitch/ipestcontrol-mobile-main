import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';

class RpiService {
  static final RpiService _instance = RpiService._internal();
  factory RpiService() => _instance;
  RpiService._internal();

  // --- Configuration ---
  static const int CAMERA_PORT = 5000; 
  static const int MANAGER_PORT = 80;  

  static const String HOTSPOT_SSID = 'IPESTCONTROL';
  static const String HOTSPOT_IP = '10.42.0.1';
  static const String HOME_IP = '10.229.150.107'; // Your specific home IP
  static const String DEVICE_HOSTNAME = 'ipestcontrol'; 
  
  String? rpiIpAddress;
  bool isConnected = false;
  String connectionMode = 'Offline'; 
  bool _isExplicitlyDisconnected = false;

  final _frameController = StreamController<Uint8List>.broadcast();
  final _metadataController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _batteryController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Uint8List> get frameStream => _frameController.stream;
  Stream<Map<String, dynamic>> get metadataStream => _metadataController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<Map<String, dynamic>> get batteryStream => _batteryController.stream;

  Timer? _reconnectTimer;
  Timer? _batteryTimer;
  Timer? _metadataTimer;
  bool _isScanning = false;
  bool _isDisposed = false;
  http.Client? _streamClient;
  
  final Connectivity _connectivity = Connectivity();
  final NetworkInfo _networkInfo = NetworkInfo();

  // --- SHUTDOWN ---
  Future<bool> shutdownSystem() async {
    if (rpiIpAddress == null) return false;
    try {
      print('🚨 Sending shutdown command to $rpiIpAddress:$MANAGER_PORT...');
      stopStreaming();
      final response = await http.post(
        Uri.parse('http://$rpiIpAddress:$MANAGER_PORT/shutdown'),
      ).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        _addStatus('System Shutting Down...');
        return true;
      }
    } catch (e) {
      print('Shutdown failed: $e');
    }
    return false;
  }

  // --- CONNECTIVITY ---
  Future<bool> scanAndConnect() async {
    if (_isScanning || _isDisposed) return false;
    
    stopStreaming(); 
    _isScanning = true;
    _isExplicitlyDisconnected = false;
    connectionMode = 'Scanning...';

    try {
      _addStatus('Scanning networks...');

      String? wifiName;
      var connectivityResult = await _connectivity.checkConnectivity();
      
      if (connectivityResult == ConnectivityResult.wifi) {
        wifiName = await _networkInfo.getWifiName();
        wifiName = wifiName?.replaceAll('"', '');
      }
      
      print('📶 Current WiFi SSID: $wifiName');

      // ✅ UNIVERSAL SCAN LIST
      // We check Hotspot IP first because it's the fastest response if connected
      List<String> possibleHosts = [
        HOTSPOT_IP,             // 10.42.0.1 (Priority 1)
        HOME_IP,                // 10.229.150.107 (Priority 2)
        DEVICE_HOSTNAME,        // ipestcontrol (Priority 3)
        '$DEVICE_HOSTNAME.local' // ipestcontrol.local (Priority 4)
      ];
      
      for (var host in possibleHosts) {
        if (_isDisposed) break;
        try {
          print('🔍 Scanning: $host...');
          final response = await http
              .get(Uri.parse('http://$host:$CAMERA_PORT/status'))
              .timeout(const Duration(milliseconds: 5));

          if (response.statusCode == 200) {
             rpiIpAddress = host;
             isConnected = true;
             
             // ✅ FIXED MODE LOGIC:
             // 1. If SSID matches IPESTCONTROL -> Hotspot
             // 2. If connected via 10.42.0.1 -> Hotspot
             // 3. Otherwise -> WiFi Mode
             if (wifiName == HOTSPOT_SSID || host == HOTSPOT_IP) {
                 connectionMode = 'Hotspot Mode';
             } else {
                 connectionMode = 'WiFi Mode';
             }
             
             _addStatus('Connected: $connectionMode');
             print('✅ Connected to $host ($connectionMode)');
             
             _startVideoStream();
             _startMetadataStream();
             _startBatteryMonitoring();
             return true;
          }
        } catch (e) { continue; }
      }

      _addStatus('Pi not found');
      connectionMode = 'Offline';
      return false;
      
    } catch (e) {
      print('Scan Error: $e');
      return false;
    } finally {
      _isScanning = false;
    }
  }

  void _addStatus(String status) {
    if (!_isDisposed && !_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _startVideoStream() {
    if (rpiIpAddress == null || _isDisposed) return;
    
    _streamClient?.close();
    final streamUrl = 'http://$rpiIpAddress:$CAMERA_PORT/video_feed';
    _streamClient = http.Client();
    
    print('📹 Opening video stream...');
    
    Future.microtask(() async {
        try {
            final request = http.Request('GET', Uri.parse(streamUrl));
            final response = await _streamClient!.send(request);

            List<int> buffer = [];
            response.stream.listen((chunk) {
                if (_isDisposed || _isExplicitlyDisconnected) return;
                buffer.addAll(chunk);
                
                while (buffer.length > 4) {
                    int startIndex = -1;
                    for (int i = 0; i < buffer.length - 1; i++) {
                        if (buffer[i] == 0xFF && buffer[i + 1] == 0xD8) {
                            startIndex = i;
                            break;
                        }
                    }
                    if (startIndex == -1) { buffer.clear(); break; }
                    
                    int endIndex = -1;
                    for (int i = startIndex + 2; i < buffer.length - 1; i++) {
                        if (buffer[i] == 0xFF && buffer[i + 1] == 0xD9) {
                            endIndex = i + 2;
                            break;
                        }
                    }
                    if (endIndex == -1) break;
                    
                    final frame = Uint8List.fromList(buffer.sublist(startIndex, endIndex));
                    if (!_isDisposed && !_frameController.isClosed) {
                        _frameController.add(frame);
                    }
                    buffer = buffer.sublist(endIndex);
                }
            }, 
            onError: (e) {
                if (!_isExplicitlyDisconnected && isConnected) {
                    print('❌ Stream dropped: $e');
                    _scheduleReconnect();
                }
            },
            onDone: () {
                 if (!_isExplicitlyDisconnected && isConnected) {
                    _scheduleReconnect();
                 }
            },
            cancelOnError: true);
        } catch (e) {
             if (!_isExplicitlyDisconnected) _scheduleReconnect();
        }
    });
  }

  void _startMetadataStream() {
    if (rpiIpAddress == null || _isDisposed) return;
    _metadataTimer?.cancel();
    _metadataTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (!isConnected || _isExplicitlyDisconnected) {
          timer.cancel();
          return;
      }
      try {
        final response = await http.get(Uri.parse('http://$rpiIpAddress:$CAMERA_PORT/metadata')).timeout(const Duration(seconds: 1));
        if (response.statusCode == 200) {
           if (!_isDisposed) _metadataController.add(json.decode(response.body));
        }
      } catch (e) {}
    });
  }

  void _startBatteryMonitoring() {
    if (rpiIpAddress == null || _isDisposed) return;
    _fetchBatteryData();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!isConnected || _isExplicitlyDisconnected) {
          timer.cancel();
          return;
      }
      _fetchBatteryData();
    });
  }

  Future<void> _fetchBatteryData() async {
    try {
      final response = await http.get(Uri.parse('http://$rpiIpAddress:$CAMERA_PORT/battery')).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200 && !_isDisposed) {
        _batteryController.add(json.decode(response.body));
      }
    } catch (e) {}
  }

  void _scheduleReconnect() {
    if (_isDisposed || _reconnectTimer?.isActive == true || _isExplicitlyDisconnected) return;
    
    isConnected = false;
    _addStatus('Reconnecting...');
    
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
        if (!_isExplicitlyDisconnected) scanAndConnect();
    });
  }

  void stopStreaming() {
    print('⏸️ Stopping streams...');
    _isExplicitlyDisconnected = true; 
    isConnected = false;
    
    _streamClient?.close();
    _streamClient = null;
    
    _reconnectTimer?.cancel();
    _batteryTimer?.cancel();
    _metadataTimer?.cancel();
    
    rpiIpAddress = null;
  }

  void dispose() {
    _isDisposed = true;
    stopStreaming();
    _frameController.close();
    _metadataController.close();
    _statusController.close();
    _batteryController.close();
  }
}