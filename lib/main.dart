import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// 引入 Firebase 核心與自動生成的設定檔
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'screens/cover_screen.dart';

import 'dart:io';

void main() async {
  // 1. 確保 Flutter 引擎與 Widget 樹綁定完成
  WidgetsFlutterBinding.ensureInitialized();

  // 2. 初始化 Firebase
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase 初始化成功！');
  } catch (e) {
    debugPrint('❌ Firebase 初始化失敗: $e');
  }

  // 3. 設定系統狀態列：透明背景 + 深色圖標（配合 App 米白主色）
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // 4. 鎖定直向（避免橫轉破版）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  HttpOverrides.global = MyHttpOverrides();

  // 5. 啟動應用程式
  runApp(const AlibudaApp());
}

class AlibudaApp extends StatelessWidget {
  const AlibudaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '探索嘉義',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8BAA88),
          primary: const Color(0xFF8BAA88),    // 抹茶綠
          secondary: const Color(0xFF7D6E5D),  // 暖褐
          surface: const Color(0xFFFDFCF5),    // 米白背景
        ),
        scaffoldBackgroundColor: const Color(0xFFFDFCF5),
        textTheme: GoogleFonts.notoSansTextTheme(),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFDFCF5),
          foregroundColor: Color(0xFF7D6E5D),
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const CoverScreen(),
    );
  }
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}