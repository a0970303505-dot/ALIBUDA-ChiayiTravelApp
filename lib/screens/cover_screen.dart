import 'dart:ui';
import 'package:flutter/material.dart';
import 'loading_screen.dart';
import 'login_screen.dart';
import 'register_screen.dart';
import 'onboarding_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  封面頁（更新版）
//  ・訪客瀏覽 → LoadingScreen(destination: 'onboarding')
//  ・登入帳號 → LoginScreen（登入後由 LoginScreen 自行跳 LoadingScreen）
//  ・建立帳號 → RegisterScreen（同上）
// ═══════════════════════════════════════════════════════════════

class CoverScreen extends StatefulWidget {
  const CoverScreen({super.key});

  @override
  State<CoverScreen> createState() => _CoverScreenState();
}

class _CoverScreenState extends State<CoverScreen>
    with TickerProviderStateMixin {
  bool _panelVisible = false;

  late AnimationController _panelCtrl;
  late AnimationController _floatCtrl;
  late AnimationController _fadeInCtrl;

  late Animation<double> _slideAnim;
  late Animation<double> _fadeAnim;
  late Animation<double> _floatAnim;
  late Animation<double> _pageInAnim;
  late Animation<double> _centerShiftAnim;

  @override
  void initState() {
    super.initState();

    _panelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _slideAnim = Tween<double>(begin: 140, end: 0).animate(
      CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutQuart),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _panelCtrl, curve: Curves.easeIn),
    );
    _centerShiftAnim = Tween<double>(begin: 0, end: -60).animate(
      CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutQuart),
    );

    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _floatAnim = Tween<double>(begin: -6, end: 6).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );

    _fadeInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
    _pageInAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _fadeInCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _panelCtrl.dispose();
    _floatCtrl.dispose();
    _fadeInCtrl.dispose();
    super.dispose();
  }

  void _onTap() {
    if (!_panelVisible) {
      setState(() => _panelVisible = true);
      _panelCtrl.forward();
    }
  }

  // 訪客瀏覽 → LoadingScreen → OnboardingScreen → ProfileSetupScreen → HomeScreen
  void _goGuestLoading() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
        const LoadingScreen(destination: 'onboarding'),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  // 登入帳號 → LoginScreen（登入成功後 LoginScreen 自己跳 LoadingScreen）
  void _goToLogin() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoadingScreen(destination: 'login'),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  // 建立帳號 → RegisterScreen
  void _goToRegister() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const RegisterScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _pageInAnim,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            return GestureDetector(
              onTap: _onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ── 1. 背景照片 ──
                  Positioned.fill(
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        Colors.black.withOpacity(0.35),
                        BlendMode.darken,
                      ),
                      child: Image.asset(
                        'assets/images/mountain_Ali.jpg',
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Container(color: const Color(0xFF2A3125)),
                      ),
                    ),
                  ),

                  // ── 2. 漸層遮罩 ──
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.4, 1.0],
                          colors: [
                            Colors.black.withOpacity(0.3),
                            Colors.transparent,
                            Colors.black.withOpacity(0.6),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── 3. 左上角 EXPLORE CHIAYI ──
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 32,
                    left: 40,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EXPLORE',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: const Color(0xFFF9F8F4).withOpacity(0.8),
                            fontSize: 14,
                            letterSpacing: 4,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'CHIAYI',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: const Color(0xFFF9F8F4),
                            fontSize: 14,
                            letterSpacing: 4,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── 4. 中央主視覺（帶上移動畫）──
                  AnimatedBuilder(
                    animation: _panelCtrl,
                    builder: (_, child) => Positioned(
                      left: 0,
                      right: 0,
                      top: h * 0.20 + _centerShiftAnim.value,
                      child: child!,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _floatAnim,
                          builder: (_, child) => Transform.translate(
                            offset: Offset(0, _floatAnim.value),
                            child: child,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(55),
                            child: BackdropFilter(
                              filter:
                              ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.25),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFF9F8F4)
                                        .withOpacity(0.25),
                                    width: 1,
                                  ),
                                ),
                                child: Center(
                                  child: Transform.scale(
                                    scale: 1.9,
                                    child: Image.asset(
                                      'assets/images/icon.png',
                                      width: 80,
                                      height: 80,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color:
                              const Color(0xFFF9F8F4).withOpacity(0.3),
                              width: 1,
                            ),
                            color: Colors.black.withOpacity(0.15),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.my_location_rounded,
                                  color: Color(0xFFA5CBD4), size: 14),
                              SizedBox(width: 8),
                              Text(
                                "23°30' N   120°44' E",
                                style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  color: Color(0xFFA5CBD4),
                                  fontSize: 16,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'ALIBUDA',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: const Color(0xFFF9F8F4),
                            fontSize: 64,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 16,
                            shadows: [
                              Shadow(
                                color: const Color(0xFFF9F8F4).withOpacity(0.3),
                                blurRadius: 10,
                              ),
                              Shadow(
                                color: const Color(0xFF8BAA88).withOpacity(0.5),
                                blurRadius: 40,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                            width: 80,
                            height: 1,
                            color: const Color(0xFFF9F8F4).withOpacity(0.5)),
                        const SizedBox(height: 12),
                        const Text(
                          '山 林 裡 的 慢 旅 行',
                          style: TextStyle(
                            color: Color(0xFFF9F8F4),
                            fontSize: 16,
                            letterSpacing: 6,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '嘉 義 等 你 來 翻 頁',
                          style: TextStyle(
                            color: Color(0xFF8BAA88),
                            fontSize: 12,
                            letterSpacing: 4,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── 5. 底部提示（未展開時）──
                  if (!_panelVisible)
                    Positioned(
                      bottom: 40,
                      left: 0,
                      right: 0,
                      child: Column(
                        children: [
                          AnimatedBuilder(
                            animation: _floatAnim,
                            builder: (_, child) => Transform.translate(
                              offset: Offset(0, _floatAnim.value * 0.5),
                              child: child,
                            ),
                            child: Icon(
                              Icons.keyboard_arrow_up_rounded,
                              color:
                              const Color(0xFFF9F8F4).withOpacity(0.8),
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '輕 觸 開 始 旅 程',
                            style: TextStyle(
                              color: const Color(0xFFF9F8F4).withOpacity(0.9),
                              fontSize: 12,
                              letterSpacing: 6,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── 6. 底部面板（點擊後滑出）──
                  if (_panelVisible)
                    AnimatedBuilder(
                      animation: _panelCtrl,
                      builder: (_, child) => Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Transform.translate(
                          offset: Offset(0, _slideAnim.value),
                          child: Opacity(
                            opacity: _fadeAnim.value,
                            child: child,
                          ),
                        ),
                      ),
                      child: _BottomPanel(
                        onLogin: _goToLogin,
                        onGuest: _goGuestLoading, // ← 訪客：先 Loading 再 Onboarding
                        onRegister: _goToRegister,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─── 底部面板（原版，不變）────────────────────────────────────────

class _BottomPanel extends StatelessWidget {
  final VoidCallback onLogin;
  final VoidCallback onGuest;
  final VoidCallback onRegister;

  const _BottomPanel({
    required this.onLogin,
    required this.onGuest,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(36)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 44),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F8F4).withOpacity(0.35),
            borderRadius:
            const BorderRadius.vertical(top: Radius.circular(36)),
            border: Border.all(
              color: const Color(0xFF8BAA88).withOpacity(0.30),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF9E9182).withOpacity(0.65),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Welcome to Chiayi',
                        style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Color(0xFF9E9182),
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '里山 × 慢遊 × AI 嚮導',
                        style: TextStyle(
                          color: Color(0xFF8BAA88),
                          fontSize: 13,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8BAA88).withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Text('🌿',
                        style: TextStyle(fontSize: 22)),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              _ActionBtn(
                label: '登入帳號',
                sublabel: 'Sign in',
                bgColor: const Color(0xFF8BAA88),
                textColor: const Color(0xFFF9F8F4),
                onTap: onLogin,
              ),
              const SizedBox(height: 12),
              _ActionBtn(
                label: '訪客瀏覽',
                sublabel: 'Guest mode',
                bgColor: const Color(0xFFF9F8F4).withOpacity(0.15),
                textColor: const Color(0xFFF9F8F4).withOpacity(0.95),
                borderColor: const Color(0xFFF9F8F4).withOpacity(0.4),
                onTap: onGuest,
              ),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: onRegister,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '初次造訪？',
                      style: TextStyle(
                        color: const Color(0xFF9E9182).withOpacity(0.8),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '立即建立帳號 →',
                      style: TextStyle(
                        color: const Color(0xFF8BAA88),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                        decorationColor:
                        const Color(0xFF8BAA88).withOpacity(0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final String sublabel;
  final Color bgColor;
  final Color textColor;
  final Color? borderColor;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.label,
    required this.sublabel,
    required this.bgColor,
    required this.textColor,
    this.borderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(18),
            border: borderColor != null
                ? Border.all(color: borderColor!, width: 1.5)
                : Border.all(
                color: const Color(0xFFF9F8F4).withOpacity(0.60),
                width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                sublabel,
                style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: textColor.withOpacity(0.65),
                  fontSize: 16,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}