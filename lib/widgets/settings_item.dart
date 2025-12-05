import 'package:flutter/material.dart';

class SettingsItem extends StatelessWidget {
  final String title;
  final IconData icon;

  const SettingsItem(this.title, this.icon, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ListTile(
        leading: Icon(icon, size: 28, color: const Color(0xFF6C5CE7)),
        title: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.w500, color: Color(0xFF2D3142))),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      ),
    );
  }
}
