import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class AdminBackupScreen extends StatefulWidget {
  const AdminBackupScreen({super.key});

  @override
  State<AdminBackupScreen> createState() => _AdminBackupScreenState();
}

class _AdminBackupScreenState extends State<AdminBackupScreen> {
  bool _isExporting = false;
  String _exportStatus = '';

  // 定義要備份的資料表
  final Map<String, String> _collections = {
    'Activities': '活動',
    'Attractions': '景點',
    'Hotels': '住宿',
    'Restaurants': '美食',
    'users': '會員帳號',
  };

  // 🚀 核心匯出功能
  Future<void> _exportData({String? specificCollection}) async {
    setState(() {
      _isExporting = true;
      _exportStatus = '正在準備打包資料...';
    });

    try {
      final db = FirebaseFirestore.instance;
      Map<String, dynamic> exportData = {};

      // 決定要抓哪些集合 (單一還是全部)
      List<String> targetCollections = specificCollection != null
          ? [specificCollection]
          : _collections.keys.toList();

      for (String collection in targetCollections) {
        setState(() => _exportStatus = '正在下載 ${_collections[collection]} 資料...');

        final snap = await db.collection(collection).get();
        List<Map<String, dynamic>> docsList = [];

        for (var doc in snap.docs) {
          docsList.add({
            'documentId': doc.id,
            'data': doc.data(),
          });
        }
        exportData[collection] = docsList;
      }

      setState(() => _exportStatus = '正在產生備份檔案...');

      // 1. 將資料轉成 JSON 格式字串
      final String jsonString = jsonEncode(exportData);

      // 2. 取得手機的暫存資料夾
      final directory = await getTemporaryDirectory();

      // 3. 建立檔案名稱 (加上當下日期時間)
      final now = DateTime.now();
      final timeStr = "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour}${now.minute}";
      final fileName = specificCollection != null
          ? 'Backup_${specificCollection}_$timeStr.json'
          : 'Backup_All_$timeStr.json';

      final File file = File('${directory.path}/$fileName');

      // 4. 將 JSON 字串寫入實體檔案
      await file.writeAsString(jsonString);

      setState(() => _exportStatus = '準備分享檔案...');

      // 5. 呼叫手機原生的分享視窗
      final xFile = XFile(file.path);
      await Share.shareXFiles(
        [xFile],
        text: '嘉義旅遊導覽 App - 資料庫備份檔 ($timeStr)',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ 備份檔已成功匯出！'), backgroundColor: Color(0xFF8BAA88)),
      );

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ 匯出失敗: $e'), backgroundColor: const Color(0xFFB07070)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _exportStatus = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Color(0xFF7D6E5D)),
        title: const Text('資料匯出與備份', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
      ),
      body: _isExporting
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFF8BAA88)),
            const SizedBox(height: 24),
            Text(_exportStatus, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('請勿關閉畫面', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
          ],
        ),
      )
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 說明卡片
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF8BAA88).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: Color(0xFF8BAA88)),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '備份功能會將雲端資料庫轉出為標準的 JSON 格式檔案。您可以將檔案傳送至您的電腦、Email 或雲端硬碟妥善保存。',
                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // 一鍵全備份
            const Text('一鍵完整備份', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _exportData(), // 不傳參數就是全部備份
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF8BAA88), Color(0xFF6D9470)]),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 5))],
                ),
                child: const Column(
                  children: [
                    Icon(Icons.cloud_download_rounded, color: Colors.white, size: 36),
                    SizedBox(height: 8),
                    Text('備份所有資料庫', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('(包含景點、活動、住宿、美食與會員)', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),

            // 個別分類備份
            const Text('個別分類備份', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 12),
            ..._collections.entries.map((entry) => _buildSingleExportCard(entry.key, entry.value)).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleExportCard(String collectionKey, String title) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: const Color(0xFF6B8EAD).withOpacity(0.1), shape: BoxShape.circle),
          child: const Icon(Icons.folder_zip_rounded, color: Color(0xFF6B8EAD)),
        ),
        title: Text('僅備份「$title」', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
        trailing: ElevatedButton(
          onPressed: () => _exportData(specificCollection: collectionKey),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6B8EAD),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('匯出', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}