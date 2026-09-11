import 'dart:ui';
import 'package:flutter/material.dart';
import 'home_screen.dart'; // 導向主頁

// ═══════════════════════════════════════════════════════════════
//  Onboarding 介紹頁（雙色分頁版 ─ 專屬 Icon 配色升級）
//  色調：抹茶綠 #8BAA88 / 暖褐 #7D6E5D / 米白 #F9F8F4
// ═══════════════════════════════════════════════════════════════

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;

  // 定義分頁資料 (將 Emoji 改為高質感 IconData)
  final _pages = const [
    _OnboardPage(
      mainIcon: Icons.map_rounded, // 首頁主圖標
      title: '慢遊地圖\n嘉義全收錄',
      titleEn: 'Slow Travel Map',
      desc: '從阿里山雲海到布袋鹽田，\n每一處都是一頁值得細讀的風景。\nAI 幫你規劃，你只管放慢腳步。',
      accentColor: Color(0xFF8BAA88), // 抹茶綠
      bgColor: Color(0xFFF1F4EE),    // 第一頁：淺綠底
      featureItems: [
        (Icons.park_rounded, '智慧行程規劃'),
        (Icons.near_me_rounded, '離線地圖導航'),
        (Icons.signpost_rounded, '在地秘境推薦'),
      ],
    ),
    _OnboardPage(
      mainIcon: Icons.restaurant_menu_rounded, // 第二頁主圖標
      title: '舌尖上的\n嘉義記憶',
      titleEn: 'Taste of Chiayi',
      desc: '雞肉飯的香氣、文化路的煙火氣、\n奮起湖便當的山林滋味。\n阿哩布達帶你找到最道地的那一口。',
      accentColor: Color(0xFF7D6E5D), // 暖褐色做為強調色
      bgColor: Color(0xFFF9F8F4),    // 第二頁：米色底
      featureItems: [
        (Icons.ramen_dining_rounded, '美食地圖'),
        (Icons.star_rounded, '在地評分系統'),
        (Icons.menu_book_rounded, '店家故事誌'),
      ],
    ),
  ];

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _goHome();
    }
  }

  void _goHome() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 取得當前頁面的背景色
    final currentBgColor = _pages[_currentPage].bgColor;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        color: currentBgColor, // ★ 讓背景切換更滑順
        child: Stack(
          children: [
            // ── 1. 頁面內容 ──
            PageView.builder(
              controller: _pageCtrl,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _currentPage = i),
              itemBuilder: (_, i) => _pages[i],
            ),

            // ── 2. 底部導航區 ──
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
                  child: Row(
                    children: [
                      // 點點指示器
                      Row(
                        children: List.generate(_pages.length, (i) {
                          final selected = i == _currentPage;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            margin: const EdgeInsets.only(right: 8),
                            width: selected ? 28 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: const Color(0xFF8BAA88)
                                  .withOpacity(selected ? 1.0 : 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          );
                        }),
                      ),
                      const Spacer(),

                      // 跳過文字
                      if (_currentPage < _pages.length - 1)
                        GestureDetector(
                          onTap: _goHome,
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: const Color(0xFF7D6E5D).withOpacity(0.5),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),

                      const SizedBox(width: 24),

                      // 下一步按鈕
                      GestureDetector(
                        onTap: _next,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8BAA88),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF8BAA88).withOpacity(0.3),
                                blurRadius: 15,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Text(
                            _currentPage < _pages.length - 1
                                ? 'Next →'
                                : 'Start ✦',
                            style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 單一介紹頁元件 ───────────────────────────────────────────────────────────────

class _OnboardPage extends StatelessWidget {
  final IconData mainIcon; // 改用 IconData
  final String title;
  final String titleEn;
  final String desc;
  final Color accentColor;
  final Color bgColor;
  final List<(IconData, String)> featureItems; // 改用 (IconData, String) 組合

  const _OnboardPage({
    required this.mainIcon,
    required this.title,
    required this.titleEn,
    required this.desc,
    required this.accentColor,
    required this.bgColor,
    required this.featureItems,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景裝飾圓
          Positioned(
            top: -100,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accentColor.withOpacity(0.06),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 80, 36, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ★ 改版：大主圖標容器
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: accentColor.withOpacity(0.3),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        mainIcon,
                        size: 48,
                        color: accentColor, // 套用專屬顏色
                      ),
                    ),
                  ),

                  const SizedBox(height: 48),

                  // 英文副標
                  Text(
                    titleEn,
                    style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: accentColor,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),

                  const SizedBox(height: 8),

                  // 中文主標題
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Color(0xFF7D6E5D),
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      height: 1.2,
                      letterSpacing: 2,
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 說明文字
                  Text(
                    desc,
                    style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: const Color(0xFF7D6E5D).withOpacity(0.8),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      height: 1.8,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const SizedBox(height: 40),

                  // ★ 改版：精緻特色列表
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF8BAA88).withOpacity(0.15),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: featureItems
                          .map((f) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          children: [
                            // 帶底色的圓形小圖標
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: accentColor.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                f.$1, // 第一個參數 IconData
                                color: accentColor,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              f.$2, // 第二個參數文字
                              style: const TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: Color(0xFF7D6E5D),
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}