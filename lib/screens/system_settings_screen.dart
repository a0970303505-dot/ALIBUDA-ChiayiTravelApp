// ═══════════════════════════════════════════════════════════════
//  system_settings_screen.dart
//  系統設定頁面
//  配色：抹茶綠 #8BAA88 / 深咖啡 #7D6E5D / 米白 #FDFCF5
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  // ★ 靜態方法：供其他頁面在觸發通知前先確認開關狀態
  static Future<bool> isNotifyEnabled(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? true;
  }

  // ★ 常數 key（讓其他頁面用）
  static const kNotifyProximity  = 'notify_proximity';
  static const kNotifyCommunity  = 'notify_community';
  static const kNotifyItinerary  = 'notify_itinerary';

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen> {
  static const Color _green = Color(0xFF8BAA88);
  static const Color _brown = Color(0xFF7D6E5D);
  static const Color _bg    = Color(0xFFFDFCF5);

  // ── 設定狀態 ────────────────────────────────────────────────
  bool _notifyProximity    = true;   // 景點接近提醒
  bool _notifyCommunity    = true;   // 社群互動通知
  bool _notifyItinerary    = true;   // 行程提醒
  bool _highQualityImages  = true;   // 高畫質圖片
  bool _offlineCache       = true;   // 離線快取
  bool _isLoading          = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notifyProximity   = prefs.getBool('notify_proximity')   ?? true;
      _notifyCommunity   = prefs.getBool('notify_community')   ?? true;
      _notifyItinerary   = prefs.getBool('notify_itinerary')   ?? true;
      _highQualityImages = prefs.getBool('high_quality_images')  ?? true;
      _offlineCache      = prefs.getBool('offline_cache')       ?? true;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notify_proximity',    _notifyProximity);
    await prefs.setBool('notify_community',    _notifyCommunity);
    await prefs.setBool('notify_itinerary',    _notifyItinerary);
    await prefs.setBool('high_quality_images', _highQualityImages);
    await prefs.setBool('offline_cache',       _offlineCache);
  }

  Future<void> _clearCache() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      // 清除頭像快取（保留設定值）
      final keys = prefs.getKeys().where((k) =>
      k.startsWith('avatar_cache_') || k.startsWith('user_avatar_bytes_')).toList();
      for (final k in keys) await prefs.remove(k);
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ 快取已清除', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
          backgroundColor: _green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('清除失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Colors.red[400],
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showPrivacyInfo() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('隱私政策', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: _brown)),
        content: const SingleChildScrollView(
          child: Text(
            '探索嘉義 App 非常重視您的隱私安全。\n\n'
                '• 您的個人資料（帳號、頭像、設定）僅用於提供 App 服務，不會出售或與廣告商分享。\n\n'
                '• 位置資訊僅在您使用地圖與景點接近提醒功能時存取，不會在背景持續追蹤。\n\n'
                '• 您的 AI 對話紀錄僅儲存在您的裝置與您個人的雲端帳號，不會用於訓練模型。\n\n'
                '• 社群貼文中您主動公開的內容將對其他使用者可見。\n\n'
                '如有任何問題，請聯絡 support@chiayi-explore.app',
            style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: _brown, height: 1.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('關閉', style: TextStyle(fontFamily: 'MyCustomFont', color: _green, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),

          // ── 通知設定 ──────────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionHeader(Icons.notifications_outlined, '通知設定')),
          SliverToBoxAdapter(child: _buildCard([
            _buildSwitch('景點接近提醒', '進入景點 100m 範圍時通知', Icons.location_on_rounded, _notifyProximity, (v) {
              setState(() => _notifyProximity = v);
              _savePrefs();
            }),
            _buildDivider(),
            _buildSwitch('社群互動通知', '貼文被按讚或留言時通知', Icons.favorite_outline_rounded, _notifyCommunity, (v) {
              setState(() => _notifyCommunity = v);
              _savePrefs();
            }),
            _buildDivider(),
            _buildSwitch('行程提醒通知', '行程當天提前提醒', Icons.calendar_today_rounded, _notifyItinerary, (v) {
              setState(() => _notifyItinerary = v);
              _savePrefs();
            }),
          ])),

          // ── 顯示設定 ──────────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionHeader(Icons.tune_rounded, '顯示設定')),
          SliverToBoxAdapter(child: _buildCard([
            _buildSwitch('高畫質圖片', '景點圖片以原始解析度載入（耗流量）', Icons.high_quality_rounded, _highQualityImages, (v) {
              setState(() => _highQualityImages = v);
              _savePrefs();
            }),
          ])),

          // ── 資料與儲存 ────────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionHeader(Icons.storage_rounded, '資料與儲存')),
          SliverToBoxAdapter(child: _buildCard([
            _buildSwitch('啟用離線快取', '景點資料預先快取，無網路也可瀏覽', Icons.offline_bolt_rounded, _offlineCache, (v) {
              setState(() => _offlineCache = v);
              _savePrefs();
            }),
            _buildDivider(),
            _buildTappable('清除快取', '清除暫存的圖片與頭像資料', Icons.cleaning_services_rounded, const Color(0xFF7FA3B0), _clearCache),
          ])),

          // ── 關於 / 法律 ───────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionHeader(Icons.info_outline_rounded, '關於與法律')),
          SliverToBoxAdapter(child: _buildCard([
            _buildTappable('隱私政策', '查看個人資料使用說明', Icons.privacy_tip_outlined, _green, _showPrivacyInfo),
            _buildDivider(),
            _buildInfoRow('App 版本', 'v2.5.0-Release (2026)'),
            _buildDivider(),
            _buildInfoRow('開發團隊', '探索嘉義 Development Team'),
          ])),

          const SliverToBoxAdapter(child: SizedBox(height: 60)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 52, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [_green.withOpacity(0.13), _bg],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white, shape: BoxShape.circle,
                border: Border.all(color: _green.withOpacity(0.2)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: _brown),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: const TextSpan(
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                  children: [
                    TextSpan(text: 'SYSTEM ', style: TextStyle(color: _brown)),
                    TextSpan(text: 'SETTINGS', style: TextStyle(color: _green)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: _green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _green.withOpacity(0.3), width: 1.2),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.settings_rounded, size: 13, color: _green),
                  SizedBox(width: 6),
                  Text('個人偏好設定', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _brown, fontWeight: FontWeight.bold)),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(color: _green.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: _green.withOpacity(0.3))),
          child: Icon(icon, size: 17, color: _green),
        ),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
      ]),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _green.withOpacity(0.12)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.025), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider() => Divider(height: 1, color: const Color(0xFFE2E8F0).withOpacity(0.7), indent: 16, endIndent: 16);

  Widget _buildSwitch(String title, String sub, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _green.withOpacity(0.09), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: _green),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w700, color: _brown)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
        ])),
        Switch(
          value: value, onChanged: onChanged,
          activeColor: _green,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ]),
    );
  }

  Widget _buildChooser(String title, IconData icon, List<String> options, String current, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _green.withOpacity(0.09), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: _green),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w700, color: _brown))),
        GestureDetector(
          onTap: () => _showPicker(title, options, current, onChanged),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: _green.withOpacity(0.08), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _green.withOpacity(0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(current, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: _brown)),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down_rounded, size: 18, color: _green),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildTappable(String title, String sub, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(0.09), borderRadius: BorderRadius.circular(10)),
            child: _isLoading && title == '清除快取'
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: color, strokeWidth: 2))
                : Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
          ])),
          Icon(Icons.arrow_forward_ios_rounded, size: 13, color: color.withOpacity(0.5)),
        ]),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w700, color: _brown))),
        Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
      ]),
    );
  }

  void _showPicker(String title, List<String> options, String current, ValueChanged<String> onChanged) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(28)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
          const SizedBox(height: 12),
          ...options.map((opt) => ListTile(
            title: Text(opt, style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold,
                color: opt == current ? _green : _brown)),
            trailing: opt == current ? const Icon(Icons.check_rounded, color: _green) : null,
            onTap: () { Navigator.pop(ctx); onChanged(opt); },
          )),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}