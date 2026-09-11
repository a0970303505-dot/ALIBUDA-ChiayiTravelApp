// ═══════════════════════════════════════════════════════════════
//  help_support_screen.dart
//  幫助與支援頁面
//  配色：抹茶綠 #8BAA88 / 深咖啡 #7D6E5D / 米白 #FDFCF5
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  // 目前展開的 FAQ index（null = 全部收合）
  int? _expandedFaqIndex;

  static const Color _green = Color(0xFF8BAA88);
  static const Color _brown = Color(0xFF7D6E5D);
  static const Color _bg = Color(0xFFFDFCF5);

  // ── FAQ 資料 ────────────────────────────────────────────────
  static const List<Map<String, String>> _faqs = [
    {
      'q': '如何建立我的帳號？',
      'a': '在首頁點選「登入 / 註冊」，選擇 Google 或 Facebook 第三方登入，即可快速完成帳號建立，您的所有資料將即時同步至雲端。',
    },
    {
      'q': '收藏的景點存在哪裡？',
      'a': '收藏資料會即時儲存到您帳號的雲端（Firebase），在任何裝置登入後都能看到相同的收藏清單。未登入的訪客無法使用收藏功能。',
    },
    {
      'q': 'AI 行程規劃功能怎麼用？',
      'a': '前往「AI 助理」頁面，輸入您的出發日期、天數及旅遊偏好（美食、文化、親子等），AI 會根據您的需求生成完整行程，並可直接儲存到行事曆。您也可以先在「我的收藏」勾選喜歡的景點，再請 AI 依此規劃。',
    },
    {
      'q': '如何獲得印章與解鎖吉祥物？',
      'a': '前往景點後點擊地圖上的景點標記，完成「知識問答」即可獲得該景點印章。集滿不同數量的印章可解鎖不同的嘉義特色吉祥物，可在「個人資料 → 我的印章收集」中查看。',
    },
    {
      'q': '行程存檔後要如何查看或修改？',
      'a': '到「地圖」頁面下方的行程列表，點選已儲存的行程即可查看或重新編輯。行程資料同樣儲存在雲端，換裝置也不怕遺失。',
    },
    {
      'q': '社群貼文如何發布？',
      'a': '進入「社群」頁面，點選右下角的「＋」按鈕，選擇貼文類型（景點 / 美食 / 住宿 / 其他），填寫內容及圖片後即可發布。貼文發布後可在「我的發布紀錄」中管理或刪除。',
    },
    {
      'q': '忘記如何切換帳號怎麼辦？',
      'a': '點選側邊欄或「個人資料」頁面下方的「安全登出」按鈕，確認登出後即可以另一個帳號重新登入。不同帳號之間的資料（收藏、印章、行程）完全隔離，不會混用。',
    },
    {
      'q': 'App 有哪些交通資訊功能？',
      'a': '在「交通」頁面可查詢嘉義市公車即時動態、台鐵時刻表與誤點資訊、YouBike 站位餘量，以及停車場即時剩餘車位。資料每 30 秒自動刷新。',
    },
  ];

  // ── 功能分類 ───────────────────────────────────────────────
  static const List<Map<String, dynamic>> _features = [
    {'icon': Icons.explore_rounded,        'label': '景點探索',    'desc': '尋找嘉義熱門與隱藏景點'},
    {'icon': Icons.restaurant_rounded,     'label': '美食地圖',    'desc': '在地小吃與餐廳推薦'},
    {'icon': Icons.hotel_rounded,          'label': '住宿搜尋',    'desc': '各類型住宿一站查詢'},
    {'icon': Icons.auto_awesome_rounded,   'label': 'AI 行程規劃', 'desc': '智慧生成客製化行程'},
    {'icon': Icons.map_rounded,            'label': '互動地圖',    'desc': '即時定位與景點導航'},
    {'icon': Icons.account_balance_wallet_rounded, 'label': '旅遊預算', 'desc': '記帳與預算管理'},
    {'icon': Icons.people_rounded,         'label': '旅遊社群',    'desc': '分享與探索旅遊心得'},
    {'icon': Icons.directions_bus_rounded, 'label': '即時交通',    'desc': '公車、台鐵、YouBike'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── Header ──────────────────────────────────────────
          SliverToBoxAdapter(child: _buildHeader(context)),

          // ── App 功能總覽 ──────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionTitle(Icons.grid_view_rounded, '功能總覽', '探索嘉義 App 提供的服務')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildFeatureCell(_features[i]),
                childCount: _features.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.6,
              ),
            ),
          ),

          // ── 常見問題 ─────────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionTitle(Icons.quiz_rounded, '常見問題', '點擊問題查看詳細解答')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildFaqTile(i),
                childCount: _faqs.length,
              ),
            ),
          ),

          // ── 聯絡我們 ─────────────────────────────────────
          SliverToBoxAdapter(child: _buildSectionTitle(Icons.support_agent_rounded, '聯絡我們', '有其他問題隨時聯繫')),
          SliverToBoxAdapter(child: _buildContactSection()),

          // ── 版本資訊 ─────────────────────────────────────
          SliverToBoxAdapter(child: _buildVersionInfo()),

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
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_green.withOpacity(0.15), _bg],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: _green.withOpacity(0.2)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: _brown),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: const TextSpan(
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    children: [
                      TextSpan(text: 'HELP & ', style: TextStyle(color: _brown)),
                      TextSpan(text: 'SUPPORT', style: TextStyle(color: _green)),
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
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.help_outline_rounded, size: 13, color: _green),
                      SizedBox(width: 6),
                      Text('幫助與支援中心', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _brown, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(IconData icon, String title, String sub) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _green.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _green.withOpacity(0.3)),
            ),
            child: Icon(icon, size: 20, color: _green),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 17, fontWeight: FontWeight.w900, color: _brown)),
              Text(sub, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureCell(Map<String, dynamic> f) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _green.withOpacity(0.15)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(color: _green.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(f['icon'] as IconData, size: 18, color: _green),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(f['label'] as String, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: _brown), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(f['desc'] as String, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqTile(int index) {
    final faq = _faqs[index];
    final isExpanded = _expandedFaqIndex == index;

    return GestureDetector(
      onTap: () => setState(() => _expandedFaqIndex = isExpanded ? null : index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isExpanded ? _green.withOpacity(0.04) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isExpanded ? _green.withOpacity(0.5) : _green.withOpacity(0.15),
            width: isExpanded ? 1.5 : 1,
          ),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 26, height: 26,
                    decoration: BoxDecoration(
                      color: isExpanded ? _green : _green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text('Q', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: isExpanded ? Colors.white : _green)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      faq['q']!,
                      style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: isExpanded ? _green : _brown,
                      ),
                    ),
                  ),
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: isExpanded ? _green : Colors.grey,
                    size: 22,
                  ),
                ],
              ),
              if (isExpanded) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _green.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 22, height: 22,
                        margin: const EdgeInsets.only(top: 1, right: 10),
                        decoration: BoxDecoration(color: _brown.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                        child: const Center(child: Text('A', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.w900, color: _brown))),
                      ),
                      Expanded(
                        child: Text(faq['a']!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: _brown, height: 1.6)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          _buildContactTile(
            icon: Icons.email_outlined,
            color: const Color(0xFF7FA3B0),
            title: '電子郵件',
            subtitle: 'support@chiayi-explore.app',
            onTap: () => _launchUrl('mailto:support@chiayi-explore.app'),
          ),
          const SizedBox(height: 10),
          _buildContactTile(
            icon: Icons.language_rounded,
            color: _green,
            title: '官方網站',
            subtitle: 'www.chiayi-explore.app',
            onTap: () => _launchUrl('https://www.chiayi-explore.app'),
          ),
          const SizedBox(height: 10),
          _buildContactTile(
            icon: Icons.chat_bubble_outline_rounded,
            color: const Color(0xFFB09070),
            title: '意見回饋',
            subtitle: '告訴我們您的想法，協助我們改善',
            onTap: () => _showFeedbackDialog(),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(0.2)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: _brown)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: color.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionInfo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _green.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _green.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Image.asset(
              'assets/images/vo/vo1.png',
              height: 60,
              errorBuilder: (_, __, ___) => const Icon(Icons.explore_rounded, size: 48, color: _green),
            ),
            const SizedBox(height: 10),
            const Text('探索嘉義', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: _brown)),
            const SizedBox(height: 4),
            const Text('版本 v2.5.0-Release (2026)', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            const Text(
              '本 App 以嘉義在地文化為核心，結合 AI 智慧推薦、即時交通資訊與社群互動，希望帶給每位旅人最棒的嘉義旅遊體驗。',
              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _brown, height: 1.6),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無法開啟連結', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _brown),
        );
      }
    }
  }

  void _showFeedbackDialog() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(28)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
              ),
              const Text('意見回饋', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: _brown)),
              const SizedBox(height: 4),
              const Text('您的意見是我們進步的動力 🌿', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown),
                decoration: InputDecoration(
                  hintText: '請輸入您的建議、問題或回饋…',
                  hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _green, width: 1.5)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity, height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('💌 感謝您的回饋，我們會持續改善！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                        backgroundColor: _green,
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('送出回饋', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}