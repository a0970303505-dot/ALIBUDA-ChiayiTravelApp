import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  建立帳號頁面 ─ 動畫升級版（修正版）
//  修正項目：
//    FIX 2: 返回按鈕正確導向登入頁
//    FIX 3: 副標題改為 "Welcome to Chiayi"
//    FIX 4: 密碼強度指示器與提示配色符合主題
//    FIX 5: 建立帳號按鈕功能正常（加入 onChanged 觸發 rebuild）
//  色調：抹茶綠 #8BAA88 / 暖褐 #7D6E5D / 米白 #F9F8F4
// ═══════════════════════════════════════════════════════════════

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with TickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePw = true;
  bool _obscureConfirmPw = true;

  // ── 進場動畫 ──
  late AnimationController _entranceCtrl;
  late AnimationController _floatCtrl;
  late List<Animation<double>> _itemFades;
  late List<Animation<Offset>> _itemSlides;
  late Animation<double> _floatAnim;

  // ── 按鈕彈跳動畫 ──
  late AnimationController _btnCtrl;
  late Animation<double> _btnScale;

  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();

    _itemFades = List.generate(7, (i) {
      return Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _entranceCtrl,
          curve: Interval(
            i * 0.10,
            (i * 0.10 + 0.5).clamp(0.0, 1.0),
            curve: Curves.easeOut,
          ),
        ),
      );
    });

    _itemSlides = List.generate(7, (i) {
      return Tween<Offset>(
        begin: const Offset(0, 0.15),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(
          parent: _entranceCtrl,
          curve: Interval(
            i * 0.09,
            (i * 0.09 + 0.55).clamp(0.0, 1.0),
            curve: Curves.easeOutCubic,
          ),
        ),
      );
    });

    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);
    _floatAnim = Tween<double>(begin: -5, end: 5).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );

    _btnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _btnScale = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _btnCtrl, curve: Curves.easeInOut),
    );

    // FIX 5: 監聽密碼輸入變化以觸發強度指示器更新
    _pwCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    _confirmPwCtrl.dispose();
    _entranceCtrl.dispose();
    _floatCtrl.dispose();
    _btnCtrl.dispose();
    super.dispose();
  }

  // ── 表單驗證 ──
  String? _validate() {
    if (_emailCtrl.text.trim().isEmpty) return '請輸入電子信箱';
    if (!_emailCtrl.text.contains('@')) return '信箱格式不正確';
    if (_pwCtrl.text.length < 6) return '密碼至少需要 6 個字元';
    if (_pwCtrl.text != _confirmPwCtrl.text) return '兩次密碼輸入不一致';
    return null;
  }

  // 建立帳號功能（修正：success flag 避免 finally 競爭）
  Future<void> _signUp() async {
    // 先驗證表單
    final error = _validate();
    if (error != null) {
      _showSnack(error, isError: true);
      return;
    }

    // 按鈕動畫回饋
    await _btnCtrl.forward();
    await _btnCtrl.reverse();

    setState(() => _isLoading = true);
    bool success = false;
    try {
      // 建立 Firebase 帳號
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _pwCtrl.text.trim(),
      );

      // 登出讓使用者手動登入，確認流程正確
      await FirebaseAuth.instance.signOut();
      success = true;
    } on FirebaseAuthException catch (e) {
      print("Firebase錯誤代碼: ${e.code}");
      print("Firebase錯誤訊息: ${e.message}");

      String msg = '註冊失敗，請稍後再試';
      if (e.code == 'weak-password') msg = '密碼強度不足，請使用更複雜的密碼';
      if (e.code == 'email-already-in-use') msg = '此信箱已被註冊，請直接登入';
      if (e.code == 'invalid-email') msg = '信箱格式不正確';
      if (mounted) _showSnack(msg, isError: true);
    } catch (e) {
      if (mounted) _showSnack('建立帳號時發生錯誤，請稍後再試', isError: true);
    } finally {
      if (mounted && !success) setState(() => _isLoading = false);
    }

    if (!success) return;

    // 成功：先更新狀態，顯示提示，再跳轉
    if (!mounted) return;
    setState(() => _isLoading = false);
    _showSnack('帳號建立成功！請登入開啟旅程 ✨', isError: false);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  void _showSnack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isError ? const Color(0xFF7D6E5D) : const Color(0xFF8BAA88),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.all(16),
      ),
    );
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
          // ── 上方背景圖 ──
          Positioned(
            top: 0, left: 0, right: 0,
            height: 260,
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
                      stops: const [0.0, 0.55, 1.0],
                      colors: [
                        Colors.black.withOpacity(0.45),
                        Colors.black.withOpacity(0.1),
                        const Color(0xFFF9F8F4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── 主要內容 ──
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 48),
              child: Column(
                children: [
                  const SizedBox(height: 90),

                  // ── 浮動 Icon + 標題 ──
                  _animItem(
                    0,
                    Column(
                      children: [
                        // 浮動圖示
                        AnimatedBuilder(
                          animation: _floatAnim,
                          builder: (_, child) => Transform.translate(
                            offset: Offset(0, _floatAnim.value),
                            child: child,
                          ),
                          child: Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                  color: const Color(0xFF8BAA88), width: 6.0),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF8BAA88).withOpacity(0.2),
                                  blurRadius: 28,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Transform.scale(
                                scale: 1.9,
                                child: Image.asset(
                                  'assets/images/icon.png',
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.eco_rounded,
                                    color: Color(0xFF8BAA88),
                                    size: 36,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 22),

                        const Text(
                          'Create Account',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: Color(0xFF7D6E5D),
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 4),

                        // FIX 3: 副標題改為與登入頁一致的英文標題
                        const Text(
                          'Welcome to Chiayi',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: Color(0xFF8BAA88),
                            fontSize: 16,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // ── 表單卡片 ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: const Color(0xFF8BAA88).withOpacity(0.18),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          // 信箱欄
                          _animItem(
                            1,
                            _RegTextField(
                              controller: _emailCtrl,
                              label: '電子信箱',
                              hint: 'your@email.com',
                              icon: Icons.mail_outline_rounded,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // 密碼欄
                          _animItem(
                            2,
                            _RegTextField(
                              controller: _pwCtrl,
                              label: '設定密碼',
                              hint: '至少 6 個字元',
                              icon: Icons.lock_outline_rounded,
                              obscure: _obscurePw,
                              suffix: GestureDetector(
                                onTap: () =>
                                    setState(() => _obscurePw = !_obscurePw),
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
                            ),
                          ),
                          const SizedBox(height: 20),

                          // 確認密碼欄
                          _animItem(
                            3,
                            _RegTextField(
                              controller: _confirmPwCtrl,
                              label: '確認密碼',
                              hint: '再次輸入密碼',
                              icon: Icons.lock_outline_rounded,
                              obscure: _obscureConfirmPw,
                              suffix: GestureDetector(
                                onTap: () => setState(
                                        () => _obscureConfirmPw = !_obscureConfirmPw),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Icon(
                                    _obscureConfirmPw
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: const Color(0xFF9E9182),
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // FIX 4 & FIX 5: 密碼強度提示（主題配色 + 即時更新）
                          _animItem(
                            4,
                            _PasswordStrengthHint(password: _pwCtrl.text),
                          ),

                          const SizedBox(height: 24),

                          // FIX 5: 主要 CTA 按鈕（確保 onTap 正常觸發）
                          _animItem(
                            5,
                            AnimatedBuilder(
                              animation: _btnScale,
                              builder: (_, child) => Transform.scale(
                                scale: _btnScale.value,
                                child: child,
                              ),
                              child: GestureDetector(
                                onTap: _isLoading ? null : _signUp,
                                child: Container(
                                  height: 60,
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF8BAA88),
                                        Color(0xFF6D9470),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF8BAA88)
                                            .withOpacity(0.35),
                                        blurRadius: 20,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: _isLoading
                                        ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                        : const Text(
                                      '建立帳號  →',
                                      style: TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 已有帳號導引
                  _animItem(
                    6,
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '已有帳號？',
                          style: TextStyle(
                            color: const Color(0xFF9E9182).withOpacity(0.9),
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // FIX 2: 返回登入 → 使用 pop（返回上一頁）
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).pushReplacement(
                              PageRouteBuilder(
                                pageBuilder: (_, __, ___) => const LoginScreen(),
                                transitionsBuilder: (_, anim, __, child) =>
                                    FadeTransition(opacity: anim, child: child),
                              ),
                            );
                          },
                          child: const Text(
                            '返回登入',
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
                  ),
                ],
              ),
            ),
          ),
          // ★ 返回按鈕放 Stack 最後確保最高層（z-order 最高）
          Positioned(
            top: MediaQuery.of(context).padding.top + 14,
            left: 18,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  Navigator.of(context).pushReplacement(
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => const LoginScreen(),
                      transitionsBuilder: (_, anim, __, child) =>
                          SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(-1, 0),
                              end: Offset.zero,
                            ).animate(CurvedAnimation(
                                parent: anim, curve: Curves.easeOutCubic)),
                            child: child,
                          ),
                      transitionDuration: const Duration(milliseconds: 400),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.22),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded,
                      size: 20, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── FIX 4: 密碼強度提示列（主題配色版）────────────────────────────

class _PasswordStrengthHint extends StatelessWidget {
  final String password;
  const _PasswordStrengthHint({required this.password});

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();

    int strength = 0;
    if (password.length >= 6) strength++;
    if (password.length >= 10) strength++;
    if (password.contains(RegExp(r'[A-Z]'))) strength++;
    if (password.contains(RegExp(r'[0-9]'))) strength++;
    if (password.contains(RegExp(r'[!@#\$%^&*]'))) strength++;

    final labels = ['太弱', '稍弱', '普通', '良好', '強度佳'];

    // FIX 4: 以主題色系取代原本的紅/橘/黃
    // 弱 → 暖褐色系；普通 → 中性暖色；強 → 抹茶綠系
    final colors = [
      const Color(0xFFC4836A), // 弱：暖磚紅（符合主題暖色系）
      const Color(0xFFB8967E), // 稍弱：暖褐
      const Color(0xFF9E9182), // 普通：中性棕
      const Color(0xFF8BAA88), // 良好：抹茶綠
      const Color(0xFF6D9470), // 強：深抹茶
    ];

    final idx = (strength - 1).clamp(0, 4);
    final currentColor = colors[idx];
    final trackColor = const Color(0xFFE8DFC8); // 未填充段：米色

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 強度條
        Row(
          children: [
            ...List.generate(5, (i) => Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                height: 5,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: i <= idx ? currentColor : trackColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            )),
            const SizedBox(width: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                labels[idx],
                key: ValueKey(idx),
                style: TextStyle(
                  color: currentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // FIX 4: 密碼建議卡片（主題配色）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF8BAA88).withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF8BAA88).withOpacity(0.20),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 14,
                    color: const Color(0xFF8BAA88).withOpacity(0.8),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '密碼建議',
                    style: TextStyle(
                      color: const Color(0xFF7D6E5D).withOpacity(0.8),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._buildSuggestions(password),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSuggestions(String pw) {
    final suggestions = [
      (pw.length >= 6, '至少 6 個字元'),
      (pw.length >= 10, '10 個字元以上更安全'),
      (pw.contains(RegExp(r'[A-Z]')), '包含大寫英文字母'),
      (pw.contains(RegExp(r'[0-9]')), '包含數字'),
      (pw.contains(RegExp(r'[!@#\$%^&*]')), '包含特殊符號 (!@#\$%^&*)'),
    ];

    return suggestions.map((item) {
      final done = item.$1;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Icon(
              done
                  ? Icons.check_circle_outline_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 13,
              color: done
                  ? const Color(0xFF8BAA88)
                  : const Color(0xFF9E9182).withOpacity(0.5),
            ),
            const SizedBox(width: 6),
            Text(
              item.$2,
              style: TextStyle(
                color: done
                    ? const Color(0xFF7D6E5D)
                    : const Color(0xFF9E9182).withOpacity(0.6),
                fontSize: 12,
                fontWeight: done ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      );
    }).toList();
  }
}

// ─── 統一輸入框 ──────────────────────────────────────────────────

class _RegTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;

  const _RegTextField({
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
            prefixIcon: Icon(icon, color: const Color(0xFF8BAA88), size: 20),
            suffixIcon: suffix,
            filled: true,
            fillColor: const Color(0xFFF9F8F4),
            contentPadding: const EdgeInsets.symmetric(vertical: 17),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                  color: Color(0xFF8BAA88), width: 0.5),
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