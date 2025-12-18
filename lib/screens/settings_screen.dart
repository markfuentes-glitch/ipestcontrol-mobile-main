import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_information_screen.dart';
import '../services/rpi_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  final RpiService _rpiService = RpiService();
  
  // 0 = Hotspot Mode, 1 = WiFi Client Mode
  int _connectionMode = 0; 

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  static const Color primaryTeal = Color(0xFF00B4A6);
  static const Color primaryIndigo = Color(0xFF6366F1);
  static const Color cardWhite = Color(0xFFFFFFFF);
  static const Color textDark = Color(0xFF1E293B);
  static const Color textMuted = Color(0xFF64748B);

  static const String PI_PORTAL_URL = 'http://10.42.0.1';

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
    
    // Auto-detect mode
    if (_rpiService.rpiIpAddress == RpiService.HOTSPOT_IP) {
      _connectionMode = 0;
    } else {
      _connectionMode = 1;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _launchPortal() async {
    final Uri url = Uri.parse(PI_PORTAL_URL);
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch $url');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not open portal: $e")),
        );
      }
    }
  }

  void _toggleConnectionMode(int index) {
    if (_connectionMode == index) return;

    setState(() {
      _connectionMode = index;
    });

    if (index == 0) {
      // Hotspot Mode
      _rpiService.stopStreaming();
      _rpiService.rpiIpAddress = RpiService.HOTSPOT_IP;
      _rpiService.scanAndConnect();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Switched to Hotspot Mode (Target: 10.42.0.1)"),
          backgroundColor: primaryTeal,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      // WiFi Mode
      _rpiService.stopStreaming();
      _rpiService.rpiIpAddress = null; 
      _rpiService.scanAndConnect();
      
      ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(
          content: const Text("Switched to WiFi Mode (Scanning Network...)"),
          backgroundColor: primaryIndigo,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _confirmShutdown() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.power_settings_new_rounded, color: Colors.red, size: 28),
              SizedBox(width: 10),
              Flexible(child: Text('Shutdown System?', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: const Text(
            'This will turn off the Raspberry Pi completely.\nYou will need to manually unplug and replug the power cable to turn it back on.',
            style: TextStyle(color: textMuted, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel', style: TextStyle(color: textMuted)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Shutdown'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sending shutdown command...')),
      );
      if (_rpiService.rpiIpAddress == null) await _rpiService.scanAndConnect();
      await _rpiService.shutdownSystem();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFFF8FAFC), Color(0xFFEDE9FE)],
        ),
      ),
      child: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 32),
                
                const Text("Connectivity Mode", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textMuted)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ]
                  ),
                  child: Row(
                    children: [
                      _buildModeBtn("Hotspot", 0, Icons.wifi_tethering),
                      _buildModeBtn("WiFi Client", 1, Icons.wifi),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 8),
                  child: Text(
                    "Switch mode depending on how your phone connects to the Pi.",
                    style: TextStyle(fontSize: 11, color: textMuted, fontStyle: FontStyle.italic),
                  ),
                ),
                
                const SizedBox(height: 24),

                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        
                        _buildSettingsItem(
                          context, // Position 1: Correctly matches definition below
                          icon: Icons.public,
                          iconColor: primaryTeal,
                          title: 'Open Configuration Portal',
                          subtitle: 'Manage Pi WiFi Connection (Hotspot Only)',
                          onTap: _launchPortal,
                        ),

                        const SizedBox(height: 16),

                        _buildSettingsItem(
                          context, // Position 1: Correctly matches definition below
                          icon: Icons.info_outline_rounded,
                          iconColor: primaryIndigo,
                          title: 'App Information',
                          subtitle: 'About app and developers',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const AppInformationScreen(),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 32),

                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _confirmShutdown,
                            icon: const Icon(Icons.power_settings_new),
                            label: const Text("Shutdown System"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade50,
                              foregroundColor: Colors.red,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeBtn(String label, int index, IconData icon) {
    bool isSelected = _connectionMode == index;
    Color activeColor = index == 0 ? primaryTeal : primaryIndigo;

    return Expanded(
      child: GestureDetector(
        onTap: () => _toggleConnectionMode(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isSelected ? activeColor.withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? activeColor : Colors.transparent,
              width: 2
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isSelected ? activeColor : textMuted, size: 26),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isSelected ? textDark : textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [primaryTeal, primaryIndigo],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: primaryIndigo.withOpacity(0.3), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.settings_rounded, color: Colors.white, size: 34),
          ),
          const SizedBox(width: 18),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SETTINGS',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.2),
                ),
                SizedBox(height: 6),
                Text(
                  'Configure System',
                  style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ✅ FIXED DEFINITION: context is now a positional argument
  Widget _buildSettingsItem(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: iconColor.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textDark)),
                      Text(subtitle, style: const TextStyle(fontSize: 12, color: textMuted)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, size: 16, color: iconColor.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}