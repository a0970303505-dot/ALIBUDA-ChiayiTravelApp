import 'dart:ui';
import 'package:flutter/material.dart';
import 'onboarding_screen.dart';
import 'login_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  載入過場頁 ─ destination 版
//  destination = 'onboarding' → OnboardingScreen（訪客／登入成功後）
//  destination = 'login'      → LoginScreen（保留，目前未使用）
// ═══════════════════════════════════════════════════════════════

class LoadingScreen extends StatefulWidget {
  final String destination; // 'onboarding' | 'login'

  const LoadingScreen({
    super.key,
    this.destination = 'onboarding',
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _textAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..forward();

    _textAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic),
      ),
    );

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.75, 1.0, curve: Curves.easeIn),
      ),
    );

    Future.delayed(const Duration(milliseconds: 4500), _navigate);
  }

  void _navigate() {
    if (!mounted) return;
    final Widget next = widget.destination == 'login'
        ? const LoginScreen()
        : const OnboardingScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => next,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 背景照片 ──
          Positioned.fill(
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.black.withOpacity(0.4),
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

          // ── 中央主區域 ──
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 100,
                    width: constraints.maxWidth,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _textAnim,
                        builder: (_, child) => Transform.translate(
                          offset: Offset(-60 * (1 - _textAnim.value), 0),
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: _textAnim.value,
                              child: child,
                            ),
                          ),
                        ),
                        child: Text(
                          'ALIBUDA',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: const Color(0xFFF9F8F4),
                            fontSize: 68,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 12,
                            shadows: [
                              Shadow(
                                color: const Color(0xFF8BAA88).withOpacity(0.8),
                                blurRadius: 30,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: Column(
                      children: [
                        const Text(
                          'EXPLORE CHIAYI',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: Color(0xFFA5CBD4),
                            fontSize: 20,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '正在準備您的嘉義之旅...',
                          style: TextStyle(
                            color: const Color(0xFFF9F8F4).withOpacity(0.7),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 24),
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                Color(0xFF8BAA88)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 底部版權 ──
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: const Center(
                child: Text(
                  '© 2026 ALIBUDA STUDIO',
                  style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Color(0xFF9E9182),
                    fontSize: 11,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}