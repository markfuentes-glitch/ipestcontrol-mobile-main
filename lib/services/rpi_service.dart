// rpi_service.dart
// IPESTCONTROL - Dynamic Auto-Discovery Version
import 'dart:async';
import 'dart:typed_data';
import 'dart:io'; 
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
  static const int WEBSOCKET_PORT = 8765;

  static const String HOTSPOT_SSID = 'IPESTCONTROL';
  static const String HOTSPOT_IP = '10.42.0.1';
  // Note: HOME_IP is now just a fallback, the scanner will find the real one!
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

  // Send Mode Configuration to Pi
  Future<void> setSystemModes(bool pestMode, bool insectMode) async {
    if (rpiIpAddress == null) return;
    try {
      await http.post(
        Uri.parse('http://$rpiIpAddress:$CAMERA_PORT/set_mode'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'pest_mode': pestMode,
          'insect_mode': insectMode,
        }),
      );
    } catch (e) {
      print("Error setting modes: $e");
    }
  }

  // --- CONNECTIVITY & AUTO DISCOVERY ---
  Future<bool> scanAndConnect() async {
    if (_isScanning || _isDisposed) return false;

    stopStreaming();
    _isScanning = true;
    _isExplicitlyDisconnected = false;
    connectionMode = 'Scanning...';

    try {
      _addStatus('Checking Network...');

      String? wifiName;
      String? wifiIP;
      var connectivityResult = await _connectivity.checkConnectivity();

      if (connectivityResult == ConnectivityResult.wifi) {
        wifiName = await _networkInfo.getWifiName();
        wifiName = wifiName?.replaceAll('"', '');
        wifiIP = await _networkInfo.getWifiIP();
      }

      print('📶 Network: $wifiName ($wifiIP)');

      // 1. FAST CHECK: Try known addresses first (Hotspot & mDNS)
      List<String> fastTargets = [
        HOTSPOT_IP,
        if (rpiIpAddress != null) rpiIpAddress!, // Try last known IP
        '$DEVICE_HOSTNAME.local',
        DEVICE_HOSTNAME
      ];

      // Remove duplicates
      fastTargets = fastTargets.toSet().toList();

      for (var host in fastTargets) {
        if (await _tryHandshake(host)) return true;
      }

      // 2. DEEP SCAN: If Fast Check failed, scan the whole WiFi subnet
      if (wifiIP != null && wifiIP != '0.0.0.0') {
        _addStatus('Auto-Discovering Pi...');
        print('🔍 Starting Subnet Scan on Port $CAMERA_PORT...');
        
        String? foundIP = await _scanSubnet(wifiIP);
        
        if (foundIP != null) {
          if (await _tryHandshake(foundIP)) return true;
        }
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

  // Helper: Try to connect to a specific IP
  Future<bool> _tryHandshake(String host) async {
    if (_isDisposed) return false;
    try {
      print('👉 Trying: $host...');
      final response = await http
          .get(Uri.parse('http://$host:$CAMERA_PORT/status'))
          .timeout(const Duration(milliseconds: 600)); 

      if (response.statusCode == 200) {
        rpiIpAddress = host;
        isConnected = true;
        connectionMode = (host == HOTSPOT_IP) ? 'Hotspot Mode' : 'WiFi Mode';
        
        _addStatus('Connected: $connectionMode');
        print('✅ FOUND PI AT: $host');

        _startWsVideoStream(); 
        _startMetadataStream();
        _startBatteryMonitoring();
        return true;
      }
    } catch (e) {
      // print('Failed to connect to $host');
    }
    return false;
  }

  // Helper: Scan 1-254 on the current subnet
  Future<String?> _scanSubnet(String myIp) async {
    String subnet = myIp.substring(0, myIp.lastIndexOf('.'));
    List<Future<String?>> futures = [];

    // Create 254 parallel tasks to check Port 5000
    for (int i = 1; i < 255; i++) {
      String targetIp = '$subnet.$i';
      if (targetIp == myIp) continue; // Skip myself
      futures.add(_checkPortOpen(targetIp));
    }

    // Wait for all to finish (takes max 500ms due to parallel execution)
    List<String?> results = await Future.wait(futures);

    // Return the first valid IP found
    for (var ip in results) {
      if (ip != null) return ip;
    }
    return null;
  }

  // Helper: Fast TCP check to see if Port 5000 is open
  Future<String?> _checkPortOpen(String ip) async {
    try {
      final socket = await Socket.connect(ip, CAMERA_PORT, timeout: const Duration(milliseconds: 500));
      socket.destroy();
      return ip; // Found it!
    } catch (e) {
      return null;
    }
  }

  void _addStatus(String status) {
    if (!_isDisposed && !_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  // ----------  WebSocket video  ----------
  void _startWsVideoStream() {
    if (rpiIpAddress == null || _isDisposed) return;

    final wsUrl = 'ws://$rpiIpAddress:$WEBSOCKET_PORT';
    print('📡 Opening WebSocket video stream...');

    WebSocket.connect(wsUrl).then((socket) {
      if (_isDisposed) {
        socket.close();
        return;
      }
      socket.listen(
        (data) {
          if (data is Uint8List) {
            if (!_isDisposed && !_frameController.isClosed) {
              _frameController.add(data);
            }
          } else if (data is String) {
            try {
              final meta = json.decode(data);
              if (!_isDisposed && !_metadataController.isClosed) {
                _metadataController.add(meta);
              }
            } catch (_) {}
          }
        },
        onError: (e) {
          print('❌ WS stream error: $e → fallback to MJPEG');
          _startVideoStream();
        },
        onDone: () {
          if (!_isExplicitlyDisconnected && isConnected) {
            _startVideoStream();
          }
        },
        cancelOnError: true,
      );
    }).catchError((e) {
      print('❌ WS connect failed: $e → using MJPEG');
      _startVideoStream();
    });
  }

  // --- ORIGINAL MJPEG FALLBACK ---
  void _startVideoStream() {
    if (rpiIpAddress == null || _isDisposed) return;

    _streamClient?.close();
    final streamUrl = 'http://$rpiIpAddress:$CAMERA_PORT/video_feed';
    _streamClient = http.Client();

    print('📹 Opening video stream (MJPEG)...');

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
      final response = await http
          .get(Uri.parse('http://$rpiIpAddress:$CAMERA_PORT/battery'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200 && !_isDisposed) {
        final rawData = json.decode(response.body);
        if (rawData.containsKey('internal')) {
          _batteryController.add(rawData);
        } else {
          _batteryController.add({
            'internal': rawData,
            'external': {'available': false}
          });
        }
      }
    } catch (e) {
      print("Battery fetch error: $e");
    }
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