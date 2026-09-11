import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'cover_screen.dart';
import 'loading_screen.dart';
import 'register_screen.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';
import 'firebase_sync_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ═══════════════════════════════════════════════════════════════
//  登入頁面 ─ Google / Facebook 第三方登入版（已完整實作）
//  流程：登入成功 → LoadingScreen → HomeScreen
// ═══════════════════════════════════════════════════════════════

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _obscurePw = true;
  bool _isLoading = false;
  String? _loadingProvider; // 'email' | 'google' | 'facebook'

  late AnimationController _fadeCtrl;
  late AnimationController _slideCtrl;
  late List<Animation<double>> _itemFades;
  late List<Animation<Offset>> _itemSlides;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..forward();
    _slideCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..forward();

    _itemFades = List.generate(7, (i) {
      return Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
        parent: _fadeCtrl,
        curve: Interval(i * 0.11, (i * 0.11 + 0.5).clamp(0, 1),
            curve: Curves.easeOut),
      ));
    });
    _itemSlides = List.generate(7, (i) {
      return Tween<Offset>(
          begin: const Offset(0, 0.12), end: Offset.zero)
          .animate(CurvedAnimation(
        parent: _slideCtrl,
        curve: Interval(i * 0.10, (i * 0.10 + 0.6).clamp(0, 1),
            curve: Curves.easeOutCubic),
      ));
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── 成功後跳轉 ──
  // ── 成功後跳轉與停權檢查 ──
  Future<void> _onLoginSuccess() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      try {
        // 🚨 1. 去 Firestore 檢查這個人有沒有被停權
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>;
          if (data['isSuspended'] == true) {
            // 💥 2. 抓到了！立刻把他的 FirebaseAuth 強制登出
            await FirebaseAuth.instance.signOut();

            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _loadingProvider = null;
            });

            // ⛔ 3. 跳出警告視窗，不讓他跳轉
            showDialog(
              context: context,
              barrierDismissible: false, // 強制使用者只能按按鈕關閉
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFFFDFCF5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                title: const Row(
                  children: [
                    Icon(Icons.block_rounded, color: Color(0xFFB07070)),
                    SizedBox(width: 8),
                    Text('帳號停權通知', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                  ],
                ),
                content: const Text('非常抱歉，您的帳號目前已被系統管理員停權。\n如有疑問請聯繫客服。', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), height: 1.5)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('我知道了', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
            return; // 直接結束函式，不執行後面的跳轉！
          }
        }
      } catch (e) {
        debugPrint('檢查停權狀態失敗: $e');
      }
    }

    // ── 如果安全過關，繼續原本的成功流程 ──
    if (!mounted) return;
    setState(() { _isLoading = false; _loadingProvider = null; });

    // ★ 登入成功後立即把手機本地資料推上 Firebase
    FirebaseSyncService.instance.uploadToFirebase().catchError((e) {
      debugPrint('⚠️ 登入後上傳本地資料失敗：$e');
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const OnboardingScreen(),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 700),
        ),
            (route) => false,
      );
    });
  }

  void _backToCover() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const CoverScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
          (route) => false,
    );
  }

  // ── 信箱登入 ──
  Future<void> _loginEmail() async {
    if (_emailCtrl.text.trim().isEmpty || _pwCtrl.text.isEmpty) {
      _showSnack('請輸入帳號與密碼');
      return;
    }
    setState(() {
      _isLoading = true;
      _loadingProvider = 'email';
    });
    bool success = false;
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _pwCtrl.text.trim(),
      );
      success = true;
    } on FirebaseAuthException catch (e) {

      String msg = '登入失敗，請稍後再試';
      if (e.code == 'user-not-found') msg = '找不到此帳號';
      if (e.code == 'wrong-password') msg = '密碼錯誤';
      if (e.code == 'invalid-credential') msg = '帳號或密碼不正確';
      if (mounted) _showSnack(msg);

    } finally {
      if (mounted && !success) setState(() { _isLoading = false; _loadingProvider = null; });
    }
    if (success) await _onLoginSuccess();
  }

  // ── Google 登入（完整實作）──
  Future<void> _loginGoogle() async {
    setState(() { _isLoading = true; _loadingProvider = 'google'; });
    bool success = false;
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        if (mounted) setState(() { _isLoading = false; _loadingProvider = null; });
        return;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      success = true;
    } on FirebaseAuthException catch (e) {
      print('==== Google 登入底層錯誤 ====');
      print(e.toString());
      if (mounted) //_showSnack('Google 登入失敗：${e.message ?? '請再試一次'}');
        _showSnack('錯誤：${e.toString()}');
    } catch (e) {
      //if (mounted) _showSnack('Google 登入失敗，請再試一次');
      print('==== Google 登入底層錯誤 ====');
      print(e.toString());
      if (mounted) //_showSnack('Google 登入失敗：${e.message ?? '請再試一次'}');
        _showSnack('錯誤：${e.toString()}');
    } finally {
      if (mounted && !success) setState(() { _isLoading = false; _loadingProvider = null; });
    }
    if (success) await _onLoginSuccess();
  }

  // ── Facebook 登入（完整實作，需 flutter_facebook_auth）──
  Future<void> _loginFacebook() async {
    setState(() { _isLoading = true; _loadingProvider = 'facebook'; });
    bool success = false;
    try {
      final loginResult = await FacebookAuth.instance.login(
        permissions: ['email', 'public_profile'],
      );

      if (loginResult.status == LoginStatus.success) {
        final accessToken = loginResult.accessToken;
        if (accessToken == null) {
          if (mounted) _showSnack('Facebook 登入失敗，無法取得授權');
          return;
        }
        final credential = FacebookAuthProvider.credential(accessToken.tokenString);
        await FirebaseAuth.instance.signInWithCredential(credential);
        success = true;
      } else if (loginResult.status == LoginStatus.cancelled) {
        // 使用者取消，靜默處理
      } else {
        if (mounted) _showSnack('Facebook 登入失敗：${loginResult.message ?? '請再試一次'}');
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'account-exists-with-different-credential') {
        if (mounted) _showSnack('此信箱已使用其他方式登入，請改用 Google 或信箱登入');
      } else {
        if (mounted) _showSnack('Facebook 登入失敗：${e.message ?? '請再試一次'}');
      }
    } catch (e) {
      if (mounted) _showSnack('Facebook 登入失敗，請再試一次');
    } finally {
      if (mounted && !success) setState(() { _isLoading = false; _loadingProvider = null; });
    }
    if (success) await _onLoginSuccess();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: const Color(0xFF7D6E5D),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.all(16),
    ));
  }

  Widget _animItem(int index, Widget child) => FadeTransition(
    opacity: _itemFades[index],
    child: SlideTransition(position: _itemSlides[index], child: child),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 1. 上方背景圖 ──
          Positioned(
            top: 0, left: 0, right: 0, height: 280,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/images/mountain_Ali.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: const Color(0xFF8BAA88)),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.6, 1.0],
                      colors: [
                        Colors.black.withOpacity(0.4),
                        Colors.black.withOpacity(0.1),
                        const Color(0xFFF9F8F4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── 2. 主要內容 ──
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 48),
              child: Column(
                children: [
                  const SizedBox(height: 110),

                  // Logo + 標題
                  _animItem(0, Column(
                    children: [
                      Container(
                        width: 92, height: 92,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(color: const Color(0xFF8BAA88), width: 7.0),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 25,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Transform.scale(
                            scale: 1.9,
                            child: Image.asset(
                              'assets/images/icon.png',
                              width: 55, height: 55,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                              const Icon(Icons.eco_rounded, color: Color(0xFF8BAA88), size: 36),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'Sign in to ALIBUDA',
                        style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Color(0xFF7D6E5D),
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Welcome back to Chiayi',
                        style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Color(0xFF8BAA88),
                          fontSize: 17,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  )),

                  const SizedBox(height: 30),

                  // 表單卡片
                  _animItem(1, Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9F8F4),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                            color: const Color(0xFF8BAA88).withOpacity(0.2)),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 24,
                              offset: const Offset(0, 8)),
                        ],
                      ),
                      child: Column(
                        children: [
                          // 信箱
                          _animItem(2, _LoginTextField(
                            controller: _emailCtrl,
                            label: '電子信箱',
                            hint: 'your@email.com',
                            icon: Icons.mail_outline_rounded,
                          )),
                          const SizedBox(height: 20),

                          // 密碼
                          _animItem(3, _LoginTextField(
                            controller: _pwCtrl,
                            label: '密碼',
                            hint: '請輸入密碼',
                            icon: Icons.lock_outline_rounded,
                            obscure: _obscurePw,
                            suffix: GestureDetector(
                              onTap: () => setState(() => _obscurePw = !_obscurePw),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Icon(
                                  _obscurePw
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: const Color(0xFF9E9182),
                                  size: 20,
                                ),
                              ),
                            ),
                          )),

                          const SizedBox(height: 8),

                          // 忘記密碼
                          Align(
                            alignment: Alignment.centerRight,
                            child: GestureDetector(
                              onTap: () {
                                // TODO: 忘記密碼流程
                              },
                              child: const Text(
                                '忘記密碼？',
                                style: TextStyle(
                                  color: Color(0xFF8BAA88),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // 登入按鈕
                          _animItem(4, GestureDetector(
                            onTap: (_isLoading) ? null : _loginEmail,
                            child: Container(
                              height: 60,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF8BAA88), Color(0xFF6D9470)],
                                ),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF8BAA88).withOpacity(0.35),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: _loadingProvider == 'email'
                                    ? const SizedBox(
                                  width: 22, height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                                    : const Text(
                                  '踏上旅程  →',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ),
                            ),
                          )),
                        ],
                      ),
                    ),
                  )),

                  const SizedBox(height: 26),

                  // 分隔線
                  _animItem(5, Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Expanded(child: Container(height: 1.5,
                            color: const Color(0xFF8BAA88).withOpacity(0.25))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Or Sign in with',
                            style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: const Color(0xFF9E9182).withOpacity(0.9),
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Expanded(child: Container(height: 1.5,
                            color: const Color(0xFF8BAA88).withOpacity(0.25))),
                      ],
                    ),
                  )),

                  const SizedBox(height: 20),

                  // 第三方按鈕（FIX 1: 改用主題配色圖示）
                  _animItem(6, Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SocialBtn(
                            label: 'Google',
                            isLoading: _loadingProvider == 'google',
                            icon: const _ThemedGoogleIcon(),
                            onTap: _isLoading ? null : _loginGoogle,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _SocialBtn(
                            label: 'Facebook',
                            isLoading: _loadingProvider == 'facebook',
                            icon: const _ThemedFacebookIcon(),
                            onTap: _isLoading ? null : _loginFacebook,
                          ),
                        ),
                      ],
                    ),
                  )),

                  const SizedBox(height: 36),

                  // 去註冊
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '初次造訪嘉義？',
                        style: TextStyle(
                            color: Color(0xFF9E9182), fontSize: 14),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder: (_, __, ___) => const RegisterScreen(),
                            transitionsBuilder: (_, anim, __, child) =>
                                SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(1, 0),
                                    end: Offset.zero,
                                  ).animate(CurvedAnimation(
                                      parent: anim,
                                      curve: Curves.easeOutCubic)),
                                  child: child,
                                ),
                            transitionDuration:
                            const Duration(milliseconds: 500),
                          ),
                        ),
                        child: const Text(
                          '立即建立帳號',
                          style: TextStyle(
                            color: Color(0xFF8BAA88),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                            decorationColor: Color(0xFF8BAA88),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── 3. 返回按鈕（最上層）──
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 18,
            child: IconButton(
              onPressed: _backToCover,
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  size: 22, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 輸入框元件 ──────────────────────────────────────────────────

class _LoginTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;

  const _LoginTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF7D6E5D),
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                color: const Color(0xFF9E9182).withOpacity(0.5), fontSize: 14),
            prefixIcon:
            Icon(icon, color: const Color(0xFF8BAA88), size: 20),
            suffixIcon: suffix,
            filled: true,
            fillColor: const Color(0xFFF9F8F4),
            contentPadding: const EdgeInsets.symmetric(vertical: 18),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide:
              const BorderSide(color: Color(0xFF8BAA88), width: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                  color: const Color(0xFF8BAA88).withOpacity(0.25), width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide:
              const BorderSide(color: Color(0xFF8BAA88), width: 1.8),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── 第三方登入按鈕 ──────────────────────────────────────────────

class _SocialBtn extends StatelessWidget {
  final String label;
  final Widget icon;
  final bool isLoading;
  final VoidCallback? onTap;

  const _SocialBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFFF9F8F4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFF8BAA88).withOpacity(0.3), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ],
        ),
        child: Center(
          child: isLoading
              ? const SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF8BAA88),
            ),
          )
              : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: Color(0xFF7D6E5D),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── FIX 1: 主題配色 Google 圖示（抹茶綠風格）──────────────────
class _ThemedGoogleIcon extends StatelessWidget {
  const _ThemedGoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF8BAA88).withOpacity(0.12),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CustomPaint(painter: _MatchaGooglePainter()),
        ),
      ),
    );
  }
}

// 抹茶主題的 Google "G" 圖示，以主題色替代原版彩色
class _MatchaGooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final accentColor = const Color(0xFF8BAA88);
    final darkColor = const Color(0xFF6D9470);
    final midColor = const Color(0xFF7D9E7A);
    final lightColor = const Color(0xFFA5C8A2);

    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // 四段弧線，以抹茶色系表現 G 圖示
    final paint = Paint()
      ..strokeWidth = size.width * 0.22
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 上弧 (深抹茶)
    paint.color = darkColor;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.78),
        -2.36, 1.57, false, paint);

    // 右弧 (抹茶)
    paint.color = accentColor;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.78),
        -0.79, 1.57, false, paint);

    // 下弧 (中抹茶)
    paint.color = midColor;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.78),
        0.79, 0.79, false, paint);

    // 左弧 (淺抹茶)
    paint.color = lightColor;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.78),
        1.57, 1.175, false, paint);

    // G 的橫槓
    final barPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c.dx - r * 0.05, c.dy - r * 0.20, r * 0.85, r * 0.40),
        const Radius.circular(3),
      ),
      barPaint,
    );
    // 白色遮罩清除左半段橫槓（保留 G 形狀）
    final clearPaint = Paint()
      ..color = const Color(0xFFF9F8F4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(c.dx - r * 0.15, c.dy - r * 0.28, r * 0.2, r * 0.56),
      clearPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─── FIX 1: 主題配色 Facebook 圖示（抹茶綠風格）──────────────────
class _ThemedFacebookIcon extends StatelessWidget {
  const _ThemedFacebookIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF8BAA88).withOpacity(0.12),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          Icons.facebook_rounded,
          size: 20,
          color: const Color(0xFF8BAA88),
        ),
      ),
    );
  }
}