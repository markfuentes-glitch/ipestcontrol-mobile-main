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

  static const int HTTP_PORT = 5000;
  // ✅ NEW CONSTANTS
  static const String HOTSPOT_SSID = 'IPESTCONTROL';
  static const String HOTSPOT_IP = '10.42.0.1';
  static const String MDNS_HOSTNAME = 'ipestcontrol. local';
  
  String?  rpiIpAddress;
  bool isConnected = false;

  // ✅ Use broadcast controllers that don't close
  final _frameController = StreamController<Uint8List>.broadcast();
  final _metadataController = StreamController<Map<String, dynamic>>. broadcast();
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
  // ✅ NEW INSTANCES
  final Connectivity _connectivity = Connectivity();
  final NetworkInfo _networkInfo = NetworkInfo();

  /// Scan and connect to Raspberry Pi
  Future<bool> scanAndConnect() async {
    if (_isScanning || _isDisposed) return false;
    _isScanning = true;

    try {
      _addStatus('Checking network type...');

      // ✅ FIXED: Handle both old and new connectivity_plus API
      String? wifiName;
      
      // Check connectivity type
      final connectivityResult = await _connectivity.checkConnectivity();
      
      // Handle both single ConnectivityResult and List<ConnectivityResult>
      bool isWifi = false;
      if (connectivityResult is List) {
        isWifi = (connectivityResult as List).contains(ConnectivityResult.wifi);
      } else {
        isWifi = connectivityResult == ConnectivityResult.wifi;
      }
      
      if (isWifi) {
        wifiName = await _networkInfo. getWifiName();
        // Remove quotes if present (e.g., "IPESTCONTROL" -> IPESTCONTROL)
        wifiName = wifiName?.replaceAll('"', '');
        print('📶 Current WiFi: $wifiName');
      }

      List<String> possibleHosts = [];

      // ✅ NEW LOGIC: Prioritize IP based on WiFi network
      if (wifiName == HOTSPOT_SSID) {
        _addStatus('Connected to Hotspot. Trying direct IP...');
        possibleHosts = [HOTSPOT_IP, MDNS_HOSTNAME];
        print('🎯 Hotspot detected. Prioritizing $HOTSPOT_IP');
      } else {
         _addStatus('Scanning home network...');
        // On home network, prioritize hostname
        possibleHosts = [
          MDNS_HOSTNAME,
          'rpi.local',
        ];
        print('🏠 Home network detected. Prioritizing $MDNS_HOSTNAME');
      }
      
      // Continue with existing scanning logic...
      for (var host in possibleHosts) {
        try {
          print('🔍 Trying to connect to $host...');
          // Short timeout for quicker scanning
          final response = await http
              .get(Uri.parse('http://$host:$HTTP_PORT/status'))
              .timeout(const Duration(milliseconds: 1500));

          if (response.statusCode == 200) {
            // Verify it's actually our Pi API
            try {
                final data = json.decode(response.body);
                if (data is Map && data.containsKey('status')) {
                     rpiIpAddress = host;
                     isConnected = true;
                     _addStatus('Connected to $host');
                     
                     print('✅ Connected to $host');
                     if(data. containsKey('model')) print('📋 Model: ${data['model']}');
                     
                     _startVideoStream();
                     _startMetadataStream();
                     _startBatteryMonitoring();
                     
                     return true;
                }
            } catch(e) {
                 print('⚠️ Found a server at $host but response was invalid JSON.');
            }
          }
        } catch (e) {
          print('❌ Failed to connect to $host: ${e.toString(). split('\n')[0]}');
          continue;
        }
      }

      _addStatus('Camera not found');
      return false;
      
    } catch (e) {
      print('❌ Scan error: $e');
      _addStatus('Connection error');
      return false;
    } finally {
      _isScanning = false;
    }
  }

  /// Safe status message adding
  void _addStatus(String status) {
    if (!_isDisposed && !_statusController. isClosed) {
      _statusController.add(status);
    }
  }

  /// Start video stream (MJPEG)
  void _startVideoStream() {
    if (rpiIpAddress == null || _isDisposed) return;

    // Cancel existing stream if any
    _streamClient?.close();
    
    final streamUrl = 'http://$rpiIpAddress:$HTTP_PORT/video_feed';
    print('📹 Starting video stream: $streamUrl');
    
    _streamClient = http.Client();
    
    _streamClient!.send(http.Request('GET', Uri.parse(streamUrl))).then((response) {
      List<int> buffer = [];
      int frameCount = 0;
      
      response.stream.listen(
        (chunk) {
          if (_isDisposed) return;
          
          buffer.addAll(chunk);
          
          // Look for JPEG boundaries (0xFFD8 = start, 0xFFD9 = end)
          while (buffer.length > 4) {
            int startIndex = -1;
            for (int i = 0; i < buffer. length - 1; i++) {
              if (buffer[i] == 0xFF && buffer[i + 1] == 0xD8) {
                startIndex = i;
                break;
              }
            }

            if (startIndex == -1) {
              buffer.clear();
              break;
            }

            int endIndex = -1;
            for (int i = startIndex + 2; i < buffer.length - 1; i++) {
              if (buffer[i] == 0xFF && buffer[i + 1] == 0xD9) {
                endIndex = i + 2;
                break;
              }
            }

            if (endIndex == -1) break;

            final frame = Uint8List.fromList(buffer.sublist(startIndex, endIndex));
            
            if (! _isDisposed && !_frameController. isClosed) {
              _frameController.add(frame);
              frameCount++;
              if (frameCount % 30 == 0) {
                // print('📸 Received $frameCount frames'); // Reduced spam
              }
            }
            
            buffer = buffer.sublist(endIndex);
          }
        },
        onError: (error) {
          print('❌ Video stream error: $error');
          if (!_isDisposed) {
            isConnected = false;
            _scheduleReconnect();
          }
        },
        onDone: () {
          print('⚠️  Video stream closed');
          if (!_isDisposed) {
            isConnected = false;
            _scheduleReconnect();
          }
        },
        cancelOnError: false,
      );
    }). catchError((error) {
      print('❌ Failed to start video stream: $error');
      if (!_isDisposed) {
        isConnected = false;
        _scheduleReconnect();
      }
    });
  }

  /// Start metadata polling (detection info, FPS, etc.)
  void _startMetadataStream() {
    if (rpiIpAddress == null || _isDisposed) return;

    _metadataTimer?.cancel();
    // Increased poll interval slightly to reduce load
    _metadataTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!isConnected || _isDisposed) {
        timer.cancel();
        return;
      }

      _fetchMetadata();
    });
  }

  Future<void> _fetchMetadata() async {
    if (rpiIpAddress == null || _isDisposed) return;

    try {
      final response = await http
          .get(Uri.parse('http://$rpiIpAddress:$HTTP_PORT/metadata'))
          .timeout(const Duration(seconds: 1)); // Shorter timeout for metadata

      if (response.statusCode == 200) {
        final metadata = json.decode(response.body);
        
        if (!_isDisposed && !_metadataController.isClosed) {
          _metadataController.add(metadata);
        }
      }
    } catch (e) {
      // Silent fail - metadata is optional
    }
  }

  /// Start battery monitoring (updates every 30 seconds)
  void _startBatteryMonitoring() {
    if (rpiIpAddress == null || _isDisposed) return;

    // Initial fetch
    _fetchBatteryData();

    // Periodic updates every 30 seconds
    _batteryTimer?. cancel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!isConnected || _isDisposed) {
        timer.cancel();
        return;
      }
      _fetchBatteryData();
    });
  }

  Future<void> _fetchBatteryData() async {
    if (rpiIpAddress == null || _isDisposed) return;

    try {
      final response = await http
          .get(Uri.parse('http://$rpiIpAddress:$HTTP_PORT/battery'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final batteryData = json.decode(response.body);
        
        print('🔋 Battery: ${batteryData['percentage']}% '
              '${batteryData['voltage']}V '
              '${batteryData['is_charging'] ? '⚡Charging' : '🔌On Battery'}');
        
        if (! _isDisposed && !_batteryController.isClosed) {
          _batteryController.add(batteryData);
        }
      }
    } catch (e) {
      print('⚠️  Battery fetch error: $e');
    }
  }

  /// Schedule reconnection attempt
  void _scheduleReconnect() {
    if (_isDisposed || _reconnectTimer?. isActive == true) return;
    
    _reconnectTimer?. cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!isConnected && ! _isDisposed) {
        print('🔄 Attempting to reconnect...');
        scanAndConnect();
      }
    });
  }

  /// Stop all streams and timers (but don't close controllers)
  void stopStreaming() {
    print('⏸️  Stopping streams...');
    _streamClient?.close();
    _streamClient = null;
    _reconnectTimer?.cancel();
    _batteryTimer?.cancel();
    _metadataTimer?.cancel();
    isConnected = false;
    rpiIpAddress = null;
  }

  /// Dispose all resources (only call when app is closing)
  void dispose() {
    print('🗑️  Disposing RpiService...');
    _isDisposed = true;
    stopStreaming();
    
    // Close controllers
    _frameController.close();
    _metadataController. close();
    _statusController. close();
    _batteryController.close();
  }
}