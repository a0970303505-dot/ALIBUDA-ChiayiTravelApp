import 'package:flutter/material.dart';
// 🌟 1. 記得在這裡 import 你的 admin_dashboard_screen.dart 檔案
import 'admin_dashboard_screen.dart';
import 'admin_data_manage_screen.dart';
import 'admin_account_manage_screen.dart';
import 'admin_backup_screen.dart';

class AdminMainScreen extends StatelessWidget {
  const AdminMainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        title: const Text('管理員控制中心', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: [
            _buildMenuCard(
                context,
                title: '新增資料',
                icon: Icons.add_circle_outline,
                color: const Color(0xFF8BAA88),
                onTap: () {
                  // 🌟 2. 把這裡的註解拿掉，並正確導向 AdminDashboardScreen
                  Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AdminDashboardScreen())
                  );
                }
            ),
            _buildMenuCard(
                context,
                title: '資料管理',
                icon: Icons.edit_document,
                color: const Color(0xFF6B8EAD),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminDataManageScreen()));
                }
            ),
            _buildMenuCard(
                context,
                title: '帳號管理',
                icon: Icons.manage_accounts,
                color: const Color(0xFFD4A373),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminAccountManageScreen()));
                }
            ),
            _buildMenuCard(
                context,
                title: '匯出與備份',
                icon: Icons.cloud_sync,
                color: const Color(0xFFB07070),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminBackupScreen()));
                }
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCard(BuildContext context, {required String title, required IconData icon, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: color.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4)),
          ],
          border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, size: 36, color: color),
            ),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}