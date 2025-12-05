import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/rpi_service.dart';
import 'dart:math';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen>
    with AutomaticKeepAliveClientMixin {
  final RpiService _rpiService = RpiService();
  final Connectivity _connectivity = Connectivity();

  bool _hasInternet = false;
  bool _isScanning = false;
  String _statusMessage = 'Checking connection...';

  Uint8List? _currentFrame;
  Map<String, dynamic>? _currentMetadata;
  int _frameSkipCounter = 0;

  // ✨ Matching home screen colors
  static const Color primaryTeal = Color(0xFF00B4A6);
  static const Color primaryIndigo = Color(0xFF6366F1);
  static const Color softBg = Color(0xFFF8FAFC);
  static const Color cardWhite = Color(0xFFFFFFFF);
  static const Color textDark = Color(0xFF1E293B);
  static const Color textMuted = Color(0xFF64748B);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _checkInternetAndConnect();

    _rpiService.frameStream.listen((frame) {
      if (!mounted) return;
      _frameSkipCounter++;
      if (_frameSkipCounter % 2 == 0) {
        setState(() => _currentFrame = frame);
      }
    });

    _rpiService.metadataStream.listen((metadata) {
      if (mounted) setState(() => _currentMetadata = metadata);
    });

    _rpiService.statusStream.listen((status) {
      if (mounted) setState(() => _statusMessage = status);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _checkInternetAndConnect() async {
    if (!mounted) return;

    setState(() {
      _isScanning = true;
      _statusMessage = 'Connecting... ';
    });

    try {
      // Fix for connectivity_plus v5.0.2 Single Result
      var connectivityResult = await _connectivity.checkConnectivity();
      bool hasConnection = connectivityResult == ConnectivityResult.wifi;

      if (mounted) {
        setState(() => _hasInternet = hasConnection);
      }

      if (hasConnection) {
        bool connected = await _rpiService.scanAndConnect();
        if (mounted && !connected) {
          setState(() => _statusMessage = 'Camera not found');
        }
      } else {
        if (mounted) {
          setState(() => _statusMessage = 'No WiFi');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Connection error');
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Size getImageSize() {
    if (_currentMetadata != null &&
        _currentMetadata!['resolution'] is List &&
        (_currentMetadata!['resolution'] as List).length == 2) {
      var res = _currentMetadata!['resolution'];
      return Size(res[0].toDouble(), res[1].toDouble());
    }
    return const Size(416, 416);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final metadata = _currentMetadata ?? {};

    int fps = 0;
    if (metadata.containsKey('fps')) {
      final fpsValue = metadata['fps'];
      if (fpsValue is double) {
        fps = fpsValue.toInt();
      } else if (fpsValue is int) {
        fps = fpsValue;
      }
    }

    List detections = [];
    if (metadata.containsKey('detections') && metadata['detections'] is List) {
      detections = metadata['detections'] as List;
    }

    final hasDetection = detections.isNotEmpty;
    final totalDetections = metadata['total_detections'] ?? 0;

    String detectedClass = '';
    double confidence = 0.0;

    if (hasDetection && detections.first is Map) {
      final firstDetection = detections.first as Map;
      detectedClass = firstDetection['class']?.toString() ?? 'Unknown';
      final confValue = firstDetection['confidence'];
      if (confValue is double) {
        confidence = confValue;
      } else if (confValue is int) {
        confidence = confValue.toDouble();
      }
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFFF8FAFC), Color(0xFFEDE9FE)],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),

              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildVideoPanel(detections),
                        const SizedBox(height: 16),
                        _buildCompactStats(
                          hasDetection,
                          detectedClass,
                          confidence,
                          totalDetections,
                          fps,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    // Determine color based on connection mode
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off_rounded;
    
    if (_rpiService.isConnected) {
      if (_rpiService.connectionMode.contains('Hotspot')) {
         statusColor = Colors.orangeAccent; // Hotspot = Orange
         statusIcon = Icons.wifi_tethering;
      } else {
         statusColor = Colors.greenAccent; // WiFi = Green
         statusIcon = Icons.wifi;
      }
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [primaryTeal, primaryIndigo],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primaryIndigo.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.videocam_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LIVE MONITORING',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 6),
                // ✅ NEW MODE BADGE
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withOpacity(0.5), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 12),
                      const SizedBox(width: 6),
                      Text(
                        _rpiService.isConnected 
                           ? _rpiService.connectionMode 
                           : 'Offline',
                        style: TextStyle(
                          fontSize: 11,
                          color: statusColor, // Use status color for text too
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(),
              icon: _isScanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(
                      Icons.refresh_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
              onPressed: _isScanning ? null : _checkInternetAndConnect,
            ),
          ),
        ],
      ),
    );
  }

  // ... (Keep existing _buildVideoPanel, _buildVideoContent, _buildCompactStats, etc.)
  // They don't need changes. COPY THEM FROM THE PREVIOUS FILE IF NEEDED.
  // I will include them below for completeness.

  Widget _buildVideoPanel(List detections) {
    return Container(
      width: double.infinity,
      height: 298,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: primaryIndigo.withOpacity(0.15), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color.fromARGB(255, 117, 117, 235).withOpacity(0.15),
            blurRadius: 10,
            offset: const Offset(0,5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            _buildVideoContent(),

            if (_rpiService.isConnected &&
                _currentFrame != null &&
                detections.isNotEmpty)
              Positioned.fill(
                child: CustomPaint(
                  painter: DetectionBoxPainter(
                    detections: detections,
                    imageSize: getImageSize(),
                  ),
                ),
              ),

            if (_rpiService.isConnected && _currentFrame != null)
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEF4444).withOpacity(0.4),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoContent() {
    if (_isScanning) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(primaryTeal),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Connecting.. .',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (!_hasInternet) {
      return _buildEmptyState(
        Icons.wifi_off_rounded,
        'No Connection',
        'Connect to WiFi',
      );
    }

    if (!_rpiService.isConnected) {
      return _buildEmptyState(
        Icons.videocam_off_rounded,
        'Camera Offline',
        _statusMessage,
      );
    }

    if (_currentFrame == null) {
      return Center(
        child: SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(primaryTeal),
          ),
        ),
      );
    }

    return Image.memory(
      _currentFrame!,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }

  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: Colors.white54),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
  
  Widget _buildCompactStats(
    bool hasDetection,
    String detectedClass,
    double confidence,
    int totalDetections,
    int fps,
  ) {
    return Container(
      width: double.infinity,
      height: 156, 
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 10,
      ), 
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: cardWhite,
        border: Border.all(
          color: Colors.black,
          width: 0.01
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primaryIndigo.withOpacity(0.0),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 3,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: hasDetection
                          ? [const Color(0xFFEF4444), const Color(0xFFDC2626)]
                          : [const Color(0xFF10B981), const Color(0xFF059669)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: hasDetection
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF10B981),
                          letterSpacing: 0.2,
                          height: 1.2,
                        ),
                        child: Text(
                          hasDetection
                              ? '🐀 ${detectedClass.toUpperCase()}'
                              : '✓ No Detection',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasDetection
                            ? '${(confidence * 100).toStringAsFixed(1)}% confidence'
                            : 'Monitoring...',
                        style: const TextStyle(
                          fontSize: 9,
                          color: textMuted,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          Expanded(
            flex: 2,
            child: Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.speed_rounded,
                    value: fps.toString(),
                    label: 'FPS',
                    color: primaryTeal,
                  ),
                ),
                Container(
                  width: 1,
                  height: double.infinity,
                  color: textMuted.withOpacity(0.2),
                ),
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.pest_control_rounded,
                    value: totalDetections.toString(),
                    label: 'Total',
                    color: primaryIndigo,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 12, color: color),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: const TextStyle(
            fontSize: 8,
            color: textMuted,
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

class DetectionBoxPainter extends CustomPainter {
  final List detections;
  final Size imageSize;

  DetectionBoxPainter({required this.detections, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    double scaleX = size.width / imageSize.width;
    double scaleY = size.height / imageSize.height;

    for (var det in detections) {
      if (det is! Map) continue;
      var bbox = det['bbox'];
      if (bbox is List && bbox.length == 4) {
        double x1 = (bbox[0] ?? 0) * scaleX, y1 = (bbox[1] ?? 0) * scaleY;
        double x2 = (bbox[2] ?? 0) * scaleX, y2 = (bbox[3] ?? 0) * scaleY;

        bool isHighConf = det['high_confidence'] == true;
        Paint paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isHighConf ? 3.0 : 2.0
          ..color = isHighConf
              ? const Color(0xFF10B981)
              : const Color(0xFFEF4444);

        Rect rect = Rect.fromLTRB(x1, y1, x2, y2);
        canvas.drawRect(rect, paint);

        String label = det['class'] != null
            ? '${det['class']} ${(det['confidence'] * 100).toStringAsFixed(1)}%'
            : '';

        if (label.isNotEmpty) {
          TextSpan span = TextSpan(
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 11.0,
              backgroundColor: paint.color.withOpacity(0.8),
            ),
            text: ' $label ',
          );
          TextPainter tp = TextPainter(
            text: span,
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
          );
          tp.layout();
          Offset textOffset = Offset(max(0, x1), max(0, y1 - tp.height - 3));
          tp.paint(canvas, textOffset);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}