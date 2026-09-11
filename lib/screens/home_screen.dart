import 'dart:ui';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:typed_data';

import 'news_screen.dart';
import 'attractions_screen.dart';
import 'food_screen.dart';
import 'accommodation_screen.dart';
import 'calendar_screen.dart';
import 'calendar_screen.dart' show CalendarEventService, AppNotification, CalendarEvent, CalendarEventType, EventDetailScreen;
import 'map_screen.dart';
import 'ai_screen.dart';
import 'favorites_screen.dart';
import 'community_screen.dart';
import 'budget_screen.dart';
import 'profile_screen.dart';
import 'traffic_screen.dart';
import 'app_state.dart';
import 'admin_dashboard_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'weather_service.dart';
import 'local_db_service.dart' as local_db_service;
import 'itinerary_save_service.dart';
import 'login_screen.dart';
import 'system_settings_screen.dart';
import 'help_support_screen.dart';
import 'admin_main_screen.dart';


// ═══════════════════════════════════════════════════════════════
//  主頁面 ─ 直接抓取 Firestore 防閃爍版
// ═══════════════════════════════════════════════════════════════


class _UnifiedItem {
  final String id;
  final String name;
  final String desc;
  final String address;
  final String imageUrl;
  final String imageBase64; // ✨ Base64 圖片支援
  final String tag;
  final String subtitle;
  final dynamic originalModel;

  const _UnifiedItem({
    required this.id,
    required this.name,
    required this.desc,
    required this.address,
    required this.imageUrl,
    this.imageBase64 = '',
    required this.tag,
    required this.subtitle,
    required this.originalModel,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ✨ 這是你加對的監聽器變數
  StreamSubscription<DocumentSnapshot>? _userDocSubscription;
  int _currentIndex = 0;
  bool _isAdmin = false; // ✨ 管理員狀態

  final List<Widget> _pages = [
    const _HomeContent(),
    const MapScreen(),
    const AiScreen(),
    const FavoritesScreen(),
    const CommunityScreen(),
    const BudgetScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // 🌟 關鍵修復 1：這裡的名字要改成你下面寫好的新函式！
    _checkAdminAndSuspensionStatus();

    AppStateManager.currentTabNotifier.addListener(() {
      if (mounted) {
        setState(() {
          _currentIndex = AppStateManager.currentTabNotifier.value;
        });
      }
    });
  }

  // 🌟 關鍵修復 2：加上這個 dispose，離開首頁時關閉監聽，才不會報錯或浪費效能
  @override
  void dispose() {
    _userDocSubscription?.cancel();
    super.dispose();
  }

  // 👇 這段你已經寫得很完美了，保持原樣即可 👇
  Future<void> _checkAdminAndSuspensionStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // ✨ 啟動即時監聽！
    _userDocSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) async {
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;

        // 🚨 即時抓包：如果變成停權狀態
        if (data['isSuspended'] == true) {
          _userDocSubscription?.cancel(); // 停止監聽
          await FirebaseAuth.instance.signOut(); // 強制登出

          if (mounted) {
            // 踢回登入頁面
            Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (_) => false
            );

            // 跳出提示
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('⛔ 您的帳號已被系統停權，已強制登出。', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                  backgroundColor: Color(0xFFB07070),
                  duration: Duration(seconds: 5),
                )
            );
          }
          return;
        }

        // 檢查管理員身分
        if (data['isAdmin'] == true && mounted) {
          setState(() => _isAdmin = true);
        } else if (mounted) {
          setState(() => _isAdmin = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      drawer: const _HomeTxtStyleDrawer(),
      body: _pages[_currentIndex],
      bottomNavigationBar: _BottomNav(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          AppStateManager.currentTabNotifier.value = i;
        },
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return const _HomeTxtStyleDrawer();
  }

  void _showLoginRequired(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('請先登入才能使用此功能喔！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
            backgroundColor: Color(0xFF7D6E5D)
        )
    );
  }
}

// 🌟 從 Firebase 直接讀取雲端頭像 (完全防閃爍版)
class UserAvatar extends StatefulWidget {
  final User? user;
  final double radius;
  const UserAvatar({required this.user, this.radius = 20});

  @override
  State<UserAvatar> createState() => UserAvatarState();
}

class UserAvatarState extends State<UserAvatar> {
  bool _isLoading = true; // 🌟 載入狀態
  Uint8List? _cloudAvatarBytes;
  String? _cloudPhotoUrl;

  @override
  void initState() {
    super.initState();
    _loadCloudAvatar();
  }

  Future<void> _loadCloudAvatar() async {
    if (widget.user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final querySnap = await FirebaseFirestore.instance
          .collection('users')
          .where('uid', isEqualTo: widget.user!.uid)
          .limit(1)
          .get();

      if (querySnap.docs.isNotEmpty) {
        final data = querySnap.docs.first.data();

        // 🌟 關鍵修復：加入 Base64 強制淨化防呆機制！
        if (data.containsKey('avatarBase64') && data['avatarBase64'] != null) {
          final String rawBase64 = data['avatarBase64'].toString();
          if (rawBase64.length > 100) { // 確保不是亂碼或空字串
            try {
              // 幫 Base64 洗澡，過濾掉所有不合法的符號或隱藏換行
              final cleanBase64 = rawBase64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
              _cloudAvatarBytes = base64Decode(cleanBase64);
            } catch (e) {
              debugPrint('頭像解碼失敗: $e');
            }
          }
        }

        // 備用的網址圖片
        if (data.containsKey('photoUrl')) {
          _cloudPhotoUrl = data['photoUrl'];
        }
      }
    } catch (e) {
      debugPrint('讀取雲端頭像失敗: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false; // Firestore 確定查完了
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.user?.displayName ?? widget.user?.email ?? '旅';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '旅';

    // 如果還在讀取，顯示預設的綠底白字
    if (_isLoading) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: const Color(0xFF8BAA88),
        child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)),
      );
    }

    ImageProvider? finalImage;
    if (_cloudAvatarBytes != null) {
      finalImage = MemoryImage(_cloudAvatarBytes!); // 🚀 第一優先：完美讀取你傳來的 Base64
    } else if (_cloudPhotoUrl != null && _cloudPhotoUrl!.isNotEmpty) {
      finalImage = NetworkImage(_cloudPhotoUrl!); // 第二優先：照片網址
    } else if (widget.user?.photoURL != null) {
      finalImage = NetworkImage(widget.user!.photoURL!); // 第三優先：Google 預設頭貼
    }

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF8BAA88),
      backgroundImage: finalImage,
      // 如果沒有任何圖片，就顯示名字第一個字 (Initial)
      child: finalImage == null ? Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)) : null,
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.home_rounded, '首頁'), (Icons.map_rounded, '地圖'), (Icons.auto_awesome_rounded, 'AI'),
      (Icons.favorite_rounded, '收藏'), (Icons.people_rounded, '社群'), (Icons.account_balance_wallet_rounded, '記帳'),
      (Icons.person_rounded, '我的'),
    ];

    return Container(
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, -3))]),
      child: SafeArea(
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (i) {
              final selected = i == currentIndex;
              return GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(items[i].$1, size: 22, color: selected ? const Color(0xFF8BAA88) : Colors.grey[400]),
                    const SizedBox(height: 4),
                    Text(items[i].$2, style: TextStyle(fontSize: 10, color: selected ? const Color(0xFF8BAA88) : Colors.grey[400], fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _HomeContent extends StatefulWidget {
  const _HomeContent();
  @override
  State<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<_HomeContent> with TickerProviderStateMixin {
  int _bannerIndex = 0;
  final PageController _pageController = PageController();
  Timer? _timer;

  // ── 頭像淡入動畫 ──────────────────────────────────────────────
  late AnimationController _avatarFadeCtrl;
  late Animation<double> _avatarFade;

  // ── 吉祥物不倒翁晃動 ─────────────────────────────────────────
  late AnimationController _wobbleCtrl;
  late Animation<double> _wobbleAnim;

  List<ActivityItem> _activities = [];
  List<_UnifiedItem> _foodItems = [];
  List<_UnifiedItem> _hotelItems = [];
  List<_UnifiedItem> _hotItems = [];
  List<_UnifiedItem> _attractionItems = [];

  List<Map<String, dynamic>> _banners = [];
  List<_UnifiedItem> _searchResults = [];
  final _searchCtrl = TextEditingController();

  bool _dataLoaded = false;
  String _tickerText = '正在載入最新消息...';
  final _db = FirebaseFirestore.instance;
  final _rng = Random();

  // ── 吉祥物 ───────────────────────────────────────────────────
  static const List<(int, String, String)> _allMascots = [
    (1, '阿里山小精靈', 'vo1'),
    (2, '鐵道站長阿布', 'vo2'),
    (3, '木棉花仙子', 'vo3'),
    (4, '咖啡農夫熊大力', 'vo4'),
    (5, '布袋魚市小老闆', 'vo5'),
    (6, '雞肉飯小當家', 'vo6'),
    (7, '鳳梨乳牛阿嘉', 'vo7'),
    (8, '方塊酥小師傅', 'vo8'),
    (9, '陣頭小天后', 'vo9'),
  ];
  List<(int, String, String)> _unlockedMascots = [];
  int _activeMascotIdx = 0;
  Timer? _mascotTimer;

  // ── 天氣狀態 ───────────────────────────────────────────────────
  WeatherData? _weatherData;
  bool _weatherLoading = true;
  bool _rainAlertShown = false;   // 避免重複彈出雨天提醒

  final _quickEntries = [
    (Icons.newspaper_rounded, '最新消息', const Color(0xFF8BAA88)),
    (Icons.landscape_rounded, '景點導覽', const Color(0xFFA5CBD4)),
    (Icons.directions_bus_rounded, '交通資訊', const Color(0xFF9E9182)),
    (Icons.restaurant_rounded, '美食推薦', const Color(0xFFE8DFC8)),
    (Icons.hotel_rounded, '住宿資訊', const Color(0xFF7D6E5D)),
    (Icons.calendar_month_rounded, '活動月曆', const Color(0xFF8BAA88)),
  ];

  @override
  void initState() {
    super.initState();
    _loadFirebaseData();
    _loadUnlockedMascots();
    _loadWeather(); // ★ 載入天氣

    _avatarFadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _avatarFade = CurvedAnimation(parent: _avatarFadeCtrl, curve: Curves.easeIn);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _avatarFadeCtrl.forward();
    });

    // 不倒翁左右晃動：2秒一個來回，無限循環
    _wobbleCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _wobbleAnim = Tween<double>(begin: -6.0, end: 6.0).animate(
      CurvedAnimation(parent: _wobbleCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _mascotTimer?.cancel();
    _avatarFadeCtrl.dispose();
    _wobbleCtrl.dispose();
    _pageController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── 從 Firebase 讀取已解鎖吉祥物數量 ─────────────────────────
  Future<void> _loadUnlockedMascots() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('stamps').get();
      final count = snap.docs.length;
      final unlocked = _allMascots.where((m) => count >= m.$1).toList();
      if (!mounted) return;

      // ★ 從 SharedPreferences 讀取上次選擇的吉祥物 asset key
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString('selected_mascot_key_$uid') ?? '';
      int savedIdx = 0;
      if (savedKey.isNotEmpty) {
        final idx = unlocked.indexWhere((m) => m.$3 == savedKey);
        if (idx >= 0) savedIdx = idx;
      }

      setState(() {
        _unlockedMascots = unlocked;
        _activeMascotIdx = savedIdx;
      });
    } catch (_) {}
  }

  // ── 點擊吉祥物：彈出選擇哪隻走動的 dialog ────────────────────
  void _showMascotPicker(BuildContext context) {
    if (_unlockedMascots.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const Text('選擇你的旅行夥伴', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 6),
            const Text('牠會一直陪著你在首頁走動 🐾', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 14, runSpacing: 14,
              children: _unlockedMascots.asMap().entries.map((e) {
                final selected = e.key == _activeMascotIdx;
                return GestureDetector(
                  onTap: () async {
                    setState(() => _activeMascotIdx = e.key);
                    // ★ 持久化儲存選擇
                    final uid = FirebaseAuth.instance.currentUser?.uid;
                    if (uid != null) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('selected_mascot_key_$uid', e.value.$3);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 90,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF8BAA88).withOpacity(0.12) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.2),
                        width: selected ? 2.5 : 1,
                      ),
                      boxShadow: selected ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 3))] : null,
                    ),
                    child: Column(
                      children: [
                        if (selected)
                          Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(6)),
                            child: const Text('使用中', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        Image.asset(
                          'assets/images/vo/${e.value.$3}.png',
                          width: 60, height: 60, fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.pets_rounded, color: Color(0xFF8BAA88), size: 44),
                        ),
                        const SizedBox(height: 6),
                        Text(e.value.$2,
                            style: TextStyle(
                              fontFamily: 'MyCustomFont', fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: selected ? const Color(0xFF8BAA88) : const Color(0xFF7D6E5D),
                            ),
                            textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('關閉', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }

  // ── 天氣載入 ─────────────────────────────────────────────────
  Future<void> _loadWeather({bool forceRefresh = false}) async {
    if (mounted) setState(() => _weatherLoading = true);
    try {
      final data = await WeatherService.instance.getChiayiWeather(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _weatherData = data;
          _weatherLoading = false;
        });
        // 天氣載入後檢查是否需要雨天提醒
        if (data != null && !_rainAlertShown) {
          _checkRainAlert(data);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _weatherLoading = false);
    }
  }

  // ── 天氣詳情彈窗（點擊天氣圖示觸發）────────────────────────
  void _showWeatherDetailDialog(WeatherData weather) {
    // 根據天氣給出建議
    String suggestion;
    String suggestionIcon;
    if (weather.isPrepareRainy) {
      suggestion = '今日降雨機率高，建議攜帶雨具，優先安排室內景點。';
      suggestionIcon = '☂️';
    } else if ((weather.precipitation ?? 0) > 0) {
      suggestion = '天氣尚可，外出時帶把傘以防萬一。';
      suggestionIcon = '🌤️';
    } else {
      suggestion = '今日天氣良好，適合戶外踏青與景點探索！';
      suggestionIcon = '🌞';
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: const Color(0xFFFDFCF5),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 標題列
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (weather.weatherColor ?? Colors.orange).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(weather.weatherEmoji, style: const TextStyle(fontSize: 26)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(weather.displayDesc, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF7D6E5D))),
                        Text('嘉義市 · 今日天氣', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey[500])),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF8BAA88), size: 20),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _loadWeather(forceRefresh: true); // 重新抓天氣資料
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 數據格子
              Row(
                children: [
                  _WeatherStatChip(icon: Icons.thermostat_rounded, label: '氣溫', value: weather.displayTemp, color: const Color(0xFFE8916A)),
                  const SizedBox(width: 10),
                  _WeatherStatChip(icon: Icons.water_drop_rounded, label: '降雨', value: '${weather.precipitation ?? 0}%', color: const Color(0xFF7FA3B0)),
                  const SizedBox(width: 10),
                  _WeatherStatChip(icon: Icons.air_rounded, label: '濕度', value: '${weather.humidity ?? '--'}%', color: const Color(0xFF8BAA88)),
                ],
              ),
              const SizedBox(height: 16),
              // 建議橫幅
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF7FA3B0).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.25)),
                ),
                child: Row(
                  children: [
                    Text(suggestionIcon, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(suggestion, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.45))),
                  ],
                ),
              ),
              if (weather.isPrepareRainy) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      // 重新觸發行程檢查並開備案 sheet
                      AppStateManager.currentTabNotifier.value = 2;
                    },
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('查看 AI 雨天備案', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7FA3B0),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── 下雨提醒：當天有行程且降雨機率 ≥ 30% 時提醒 ──────────────
  Future<void> _checkRainAlert(WeatherData weather) async {
    if (!weather.isPrepareRainy) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // ★ 用 SharedPreferences 記錄今天是否已提醒過（持久化，重啟不重複彈）
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final alertKey = 'rain_alert_shown_${uid}_$todayStr';
    if (prefs.getBool(alertKey) == true) return; // 今天已提醒過

    try {
      // ★ 查行程時同時過濾掉已刪除的行程（防止已刪但 Firebase 墓碑尚未同步的情況）
      final db = await local_db_service.LocalDbService.instance.db;
      final rows = await db.rawQuery(
        '''
        SELECT * FROM saved_itineraries
        WHERE user_id = ?
          AND (start_date LIKE ? OR (start_date <= ? AND end_date >= ?))
          AND id NOT IN (
            SELECT id FROM deleted_itinerary_ids WHERE user_id = ?
          )
        LIMIT 1
        ''',
        [uid, '$todayStr%', '${todayStr}T23:59:59', '${todayStr}T00:00:00', uid],
      );

      if (rows.isEmpty) return;

      // ★ 標記今天已提醒，同時更新 in-memory flag
      await prefs.setBool(alertKey, true);
      _rainAlertShown = true;

      if (!mounted) return;
      final itineraryTitle = rows.first['title']?.toString() ?? '今日行程';
      final itineraryId = rows.first['id']?.toString() ?? '';

      // ★ 立刻寫入鈴鐺通知（不等使用者按按鈕，確保紀錄留存）
      _writeRainAlertNotification(weather, itineraryTitle);

      // ★ 改用 Dialog 彈跳式視窗，不會卡在每個頁面頂部
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: const Color(0xFFFDFCF5),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 天氣圖示
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7FA3B0).withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Text(weather.weatherEmoji, style: const TextStyle(fontSize: 32)),
                ),
                const SizedBox(height: 14),
                Text(
                  '今日降雨機率 ${weather.precipitation}%！',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF7D6E5D)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '「$itineraryTitle」可能受到影響\n要讓 AI 提供雨天備案嗎？',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey, height: 1.5),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          side: const BorderSide(color: Color(0xFFBCAAA4)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('稍後再說', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(ctx).pop(); // 先關閉彈跳視窗
                          AppStateManager.currentTabNotifier.value = 2; // ✨ 直接切換到底部導覽列的 AI 頁面 (Index 2)
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7FA3B0),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          elevation: 0,
                        ),
                        child: const Text('查備案 ☂️', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [RainAlert] $e');
    }
  }

  // ── 寫入鈴鐺通知（rain_alert）─────────────────────────────
  Future<void> _writeRainAlertNotification(WeatherData weather, String itineraryTitle) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final notifId = 'rain_alert_${DateTime.now().millisecondsSinceEpoch}';
      await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('app_notifications')
          .doc(notifId).set({
        'id': notifId,
        'type': 'rain_alert',
        'title': '☂️ 雨天備案提醒',
        'body': '「\$itineraryTitle」今日降雨 \${weather.precipitation}%，已為你規劃雨天備案。',
        'senderName': 'AI 助理',
        'senderUid': uid,
        'payload': {'precipitation': weather.precipitation, 'itineraryTitle': itineraryTitle},
        'isRead': false,
        'createdAt': DateTime.now().toIso8601String(),
      });
      debugPrint('🔔 雨天通知已寫入鈴鐺');
    } catch (e) {
      debugPrint('⚠️ 寫入雨天通知失敗：\$e');
    }
  }

  // ── AI 雨備方案 bottom sheet ─────────────────────────────────
  void _showRainAlternativeSheet(WeatherData weather, String itineraryTitle, {String itineraryId = ''}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _RainAlternativeSheet(
        weather: weather,
        itineraryTitle: itineraryTitle,
        itineraryId: itineraryId,
      ),
    );
  }

  String _getValidImageUrl(dynamic data) {
    if (data == null) return '';
    if (data is String) return data.startsWith('http') ? data : '';
    if (data is List && data.isNotEmpty) {
      var first = data[0];
      if (first is Map && first['url'] != null) {
        String url = first['url'].toString();
        return url.startsWith('http') ? url : '';
      }
      if (first is String) return first.startsWith('http') ? first : '';
    }
    return '';
  }

  String _getCleanName(String rawName) {
    return rawName.replaceAll(RegExp(r'[\(（].*?[\)）]'), '').replaceAll(RegExp(r'\s+'), '').trim();
  }

  Future<void> _loadFirebaseData() async {
    try {
      final results = await Future.wait([
        _db.collection('Activities').get(),
        _db.collection('Hotels').get(),
        _db.collection('Restaurants').get(),
        _db.collection('Attractions').get(),
      ]);

      _activities = results[0].docs.map((doc) {
        final d = (doc.data() as Map<String, dynamic>?) ?? {};
        List<String> parsedTags = [];
        if (d['Tags'] is List) {
          parsedTags = (d['Tags'] as List).map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
        }
        return ActivityItem(
          id: doc.id,
          name: d['ActivityName']?.toString() ?? '(未命名)',
          category: d['Category']?.toString() ?? '一般活動',
          date: d['Date']?.toString() ?? '',
          description: d['Description']?.toString() ?? '',
          imageUrl: _getValidImageUrl(d['ImageUrl']),
          imageBase64: d['ImageBase64']?.toString() ?? '', // ✨
          tags: parsedTags,
        );
      }).toList();

      Map<String, _UnifiedItem> nameToFood = {};
      for (var doc in results[2].docs) {
        final d = doc.data();
        String name = d['RestaurantName']?.toString() ?? '未命名美食';
        String cleanKey = _getCleanName(name);
        String address = d['StreetAddress']?.toString() ?? d['Address']?.toString() ?? '嘉義';
        String desc = d['Description']?.toString().trim() ?? '';
        if (desc == '沒有') desc = '';
        String img = _getValidImageUrl(d['Images'] ?? d['ImageUrl']);
        String base64Food = d['ImageBase64']?.toString() ?? ''; // ✨

        if (nameToFood.containsKey(cleanKey)) {
          if (nameToFood[cleanKey]!.desc.length >= desc.length) continue;
        }

        String phoneStr = '沒有提供';
        if (d['Telephones'] is List && (d['Telephones'] as List).isNotEmpty) {
          var firstTel = (d['Telephones'] as List)[0];
          if (firstTel is Map) phoneStr = firstTel['phoneNumber']?.toString() ?? '沒有提供';
        }

        String priceStr = d['Price']?.toString() ?? '';
        int parsedPrice = 0;
        if (priceStr != '沒有' && priceStr.isNotEmpty && priceStr != '0' && priceStr != '0.0') {
          parsedPrice = int.tryParse(priceStr.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        }
        if (priceStr == '沒有' || priceStr == '0' || priceStr == '0.0' || priceStr.trim().isEmpty) priceStr = '';

        String timeStr = d['ServiceTimeInfo']?.toString() ?? '';
        if (timeStr == '沒有' || timeStr.isEmpty) {
          timeStr = '依現場公告';
        } else {
          timeStr = timeStr.split(RegExp(r'[;；]')).map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
        }

        String webUrl = d['WebsiteUrl']?.toString() ?? '';
        if (webUrl == '沒有') webUrl = '';

        final foodModel = FoodModel(
          name: name, shortDesc: desc.length > 40 ? '${desc.substring(0, 40)}...' : desc,
          location: address, price: priceStr, parsedPrice: parsedPrice, distance: '探索中',
          phone: phoneStr, category: '特色餐館', serviceTime: timeStr, websiteUrl: webUrl,
          images: [img.isNotEmpty ? img : 'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=800'],
          tags: ['在地美食'], recommendedDishes: const [], fullDesc: desc.isEmpty ? '暫無詳細介紹' : desc,
          othersComments: const [], hasImage: img.isNotEmpty || base64Food.isNotEmpty, // ✨
        );

        nameToFood[cleanKey] = _UnifiedItem(
          id: doc.id, name: name, desc: desc, address: address,
          imageUrl: img, imageBase64: base64Food, // ✨
          tag: '美食', subtitle: d['Town']?.toString() ?? '嘉義美食', originalModel: foodModel,
        );
      }
      _foodItems = nameToFood.values.toList();

      Map<String, _UnifiedItem> nameToHotel = {};
      for (var doc in results[1].docs) {
        final d = doc.data();
        String name = d['HotelName']?.toString() ?? '未命名旅宿';
        String cleanKey = _getCleanName(name);
        String address = d['StreetAddress']?.toString() ?? d['Address']?.toString() ?? '嘉義';
        String desc = d['Description']?.toString().trim() ?? '';
        if (desc == '沒有') desc = '';
        String img = _getValidImageUrl(d['Images'] ?? d['ImageUrl']);
        String base64Hotel = d['ImageBase64']?.toString() ?? ''; // ✨

        if (nameToHotel.containsKey(cleanKey)) {
          if (nameToHotel[cleanKey]!.desc.length >= desc.length) continue;
        }

        String phone = '';
        if (d['Telephones'] is List && (d['Telephones'] as List).isNotEmpty) {
          var firstTel = (d['Telephones'] as List)[0];
          if (firstTel is Map) phone = firstTel['phoneNumber']?.toString() ?? '';
        }

        int parsedPrice = 0;
        if (d['LowestPrice'] != null) {
          parsedPrice = int.tryParse(d['LowestPrice'].toString()) ?? 0;
        }

        double starVal = 0.0;
        if (d['HotelStars'] != null) {
          starVal = double.tryParse(d['HotelStars'].toString()) ?? 0.0;
        }
        String ratingStr = starVal > 0 ? starVal.toStringAsFixed(1) : '';

        String inTime = d['CheckInTime']?.toString() ?? '';
        String outTime = d['CheckOutTime']?.toString() ?? '';
        String timeInfo = '';
        if (inTime.isNotEmpty && inTime != '沒有') timeInfo += '入住: $inTime';
        if (outTime.isNotEmpty && outTime != '沒有') {
          timeInfo += timeInfo.isNotEmpty ? ' / 退房: $outTime' : '退房: $outTime';
        }
        if (timeInfo.isEmpty) timeInfo = '依現場規定';

        String webUrl = d['WebsiteUrl']?.toString() ?? '';
        if (webUrl == '沒有') webUrl = '';

        final hotelModel = HotelModel(
          name: name, desc: desc, address: address, phone: phone, price: parsedPrice, rating: ratingStr,
          tags: ['優質住宿'], images: [img.isNotEmpty ? img : 'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=800'],
          imageBase64: base64Hotel, // ✨
          facilities: const [], rooms: const [], comments: const [], category: '合法飯店', checkTimeInfo: timeInfo, websiteUrl: webUrl,
        );

        nameToHotel[cleanKey] = _UnifiedItem(
          id: doc.id, name: name, desc: desc, address: address,
          imageUrl: img, imageBase64: base64Hotel, // ✨
          tag: '住宿', subtitle: d['Town']?.toString() ?? '嘉義住宿', originalModel: hotelModel,
        );
      }
      _hotelItems = nameToHotel.values.toList();

      Map<String, _UnifiedItem> nameToAttr = {};
      for (var doc in results[3].docs) {
        final d = doc.data();
        String name = d['AttractionName']?.toString() ?? '未命名景點';
        String cleanKey = _getCleanName(name);
        String address = d['Address']?.toString() ?? d['StreetAddress']?.toString() ?? '嘉義';
        String desc = d['Description']?.toString().trim() ?? '';
        if (desc == '沒有') desc = '';
        String img = _getValidImageUrl(d['Images'] ?? d['ImageUrl']);
        String base64Attr = d['ImageBase64']?.toString() ?? '';

        if (nameToAttr.containsKey(cleanKey)) {
          if (nameToAttr[cleanKey]!.desc.length >= desc.length) continue;
        }

        // ✨ 1. 先將 Firebase 抓到的資料轉成 AttractionModel
        List<String> tags = [];
        if (d['Tags'] is List) {
          for (var t in d['Tags']) {
            if (t.toString().trim().isNotEmpty && t.toString() != '沒有') {
              tags.add(t.toString().startsWith('#') ? t.toString() : '#${t.toString()}');
            }
          }
        }

        String ratingStr = d['Star_rating']?.toString() ?? '';
        if (ratingStr == '0' || ratingStr == '0.0' || ratingStr.trim().isEmpty) ratingStr = '';

        String timeInfo = d['ServiceTimeInfo']?.toString() ?? '';
        if (timeInfo == '沒有' || timeInfo.isEmpty) timeInfo = '依現場公告為主';

        String transInfo = d['TrafficInfo']?.toString() ?? '';
        if (transInfo == '沒有' || transInfo.isEmpty) transInfo = '建議自行開車或搭乘大眾運輸工具';

        double? lat = double.tryParse(d['PositionLat']?.toString() ?? '');
        double? lon = double.tryParse(d['PositionLon']?.toString() ?? '');

        final attrModel = AttractionModel(
          name: name,
          shortDesc: desc.length > 40 ? '${desc.substring(0, 40)}...' : desc,
          rating: ratingStr,
          hasAI: desc.length > 50,
          tags: tags,
          images: img.isNotEmpty ? [img] : [],
          imageBase64: base64Attr, // ✨ 這裡把 Base64 傳入 Model
          fullDesc: desc.isEmpty ? '暫無詳細介紹' : desc,
          infoTime: timeInfo,
          infoLoc: address,
          infoTrans: transInfo,
          comments: const [], // 首頁預載不用抓完整留言沒關係
          quizzes: const [],  // 首頁預載不用抓完整題庫
          lat: lat,
          lon: lon,
        );

// ✨ 2. 把建立好的 attrModel 塞進 _UnifiedItem
        nameToAttr[cleanKey] = _UnifiedItem(
          id: doc.id,
          name: name,
          desc: desc,
          address: address,
          imageUrl: img,
          imageBase64: base64Attr,
          tag: '景點',
          subtitle: tags.isNotEmpty ? tags[0] : '嘉義景點',
          originalModel: attrModel, // ✨ 完美傳入！
        );
      }
      _attractionItems = nameToAttr.values.toList();

      final actWithImage = _activities.where((a) => a.imageUrl.isNotEmpty || a.imageBase64.isNotEmpty).toList(); // ✨
      actWithImage.shuffle(_rng);

      final banners = actWithImage.take(3).map((a) {
        return {
          'title': a.name,
          'desc': a.description.length > 30 ? '${a.description.substring(0, 30)}...' : a.description,
          'image': a.imageUrl,
          'imageBase64': a.imageBase64, // ✨
          'model': a,
        };
      }).toList();

      final tickerDocs = List.from(_activities)..shuffle(_rng);
      final tickerNames = tickerDocs.take(5).map((d) => d.name).where((s) => s.isNotEmpty).join('　✦　');

      final List<_UnifiedItem> combinedHot = [];

      final sortedActs = List<ActivityItem>.from(_activities)..sort((a, b) => b.description.length.compareTo(a.description.length));
      for (var a in sortedActs.where((element) => element.imageUrl.isNotEmpty || element.imageBase64.isNotEmpty).take(2)) { // ✨
        combinedHot.add(_UnifiedItem(id: a.id, name: a.name, desc: a.description, address: '', imageUrl: a.imageUrl, imageBase64: a.imageBase64, tag: '活動', subtitle: a.category, originalModel: a));
      }

      final sortedFoods = List<_UnifiedItem>.from(_foodItems)..sort((a, b) => b.desc.length.compareTo(a.desc.length));
      combinedHot.addAll(sortedFoods.where((element) => element.imageUrl.isNotEmpty || element.imageBase64.isNotEmpty).take(2)); // ✨

      final sortedHotels = List<_UnifiedItem>.from(_hotelItems)..sort((a, b) => b.desc.length.compareTo(a.desc.length));
      combinedHot.addAll(sortedHotels.where((element) => element.imageUrl.isNotEmpty || element.imageBase64.isNotEmpty).take(2)); // ✨

      combinedHot.shuffle(_rng);

      if (!mounted) return;
      setState(() {
        _banners = banners;
        _tickerText = tickerNames.isNotEmpty ? tickerNames : '探索嘉義，開啟您的慢旅行 ✨';
        _hotItems = combinedHot;
        _dataLoaded = true;
      });

      _startBannerTimer();
    } catch (e) {
      debugPrint('首頁載入失敗: $e');
      if (mounted) setState(() => _dataLoaded = true);
    }
  }

  void _startBannerTimer() {
    _timer?.cancel();
    if (_banners.isEmpty) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      _bannerIndex = (_bannerIndex + 1) % _banners.length;
      if (_pageController.hasClients) {
        _pageController.animateToPage(_bannerIndex, duration: const Duration(milliseconds: 800), curve: Curves.easeInOutCubic);
      }
    });
  }

  void _doLocalSearch(String query) {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    final q = query.trim().toLowerCase();
    final List<_UnifiedItem> results = [];

    for (var a in _activities) {
      if (a.name.toLowerCase().contains(q)) {
        results.add(_UnifiedItem(id: a.id, name: a.name, desc: a.description, address: '', imageUrl: a.imageUrl, imageBase64: a.imageBase64, tag: '活動', subtitle: a.category, originalModel: a)); // ✨
      }
    }
    for (var f in _foodItems) {
      if (f.name.toLowerCase().contains(q)) results.add(f);
    }
    for (var h in _hotelItems) {
      if (h.name.toLowerCase().contains(q)) results.add(h);
    }

    for (var attr in _attractionItems) {
      if (attr.name.toLowerCase().contains(q)) results.add(attr);
    }

    setState(() {
      _searchResults = results;
    });
  }

  void _navigateToDetail(String tag, dynamic model) {
    FocusScope.of(context).unfocus();
    if (tag == '活動' && model is ActivityItem) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => NewsDetailScreen(activity: model)));
    } else if (tag == '美食' && model is FoodModel) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => FoodDetailScreen(foodData: model)));
    } else if (tag == '住宿' && model is HotelModel) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => HotelDetailScreen(hotel: model)));
    }else if (tag == '景點' && model is AttractionModel) {
      // ✨ 判斷 model 確實是 AttractionModel 後，安全跳轉並傳入 spotData
      Navigator.push(context, MaterialPageRoute(builder: (_) => AttractionDetailScreen(spotData: model)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;

    return Stack(
      children: [
        // ── 主要內容 ───────────────────────────────────────────
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverToBoxAdapter(child: _buildSearchBar()),

            if (_searchCtrl.text.isNotEmpty)
              SliverToBoxAdapter(child: _buildSearchResults()),

            if (_searchCtrl.text.isEmpty) ...[
              SliverToBoxAdapter(child: _buildTicker()),
              SliverToBoxAdapter(child: _buildBanner()),
              SliverToBoxAdapter(child: _buildQuickEntries(context)),
              SliverToBoxAdapter(child: _buildHotSpots()),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? '旅人';
    final now = DateTime.now();
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dateStr = '${months[now.month - 1]} ${now.day}';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 50, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 頂部工具列 ──────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Builder(builder: (ctx) => IconButton(onPressed: () => Scaffold.of(ctx).openDrawer(), icon: const Icon(Icons.menu_rounded, size: 30, color: Color(0xFF7D6E5D)))),
              Row(
                children: [
                  // ★ 動態天氣顯示（點擊看詳情）
                  GestureDetector(
                    onTap: () {
                      if (_weatherData != null) {
                        _showWeatherDetailDialog(_weatherData!);
                      } else {
                        _loadWeather(forceRefresh: true);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _weatherLoading
                            ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8BAA88)))
                            : Icon(
                          _weatherData?.weatherIcon ?? Icons.wb_sunny_rounded,
                          color: _weatherData?.weatherColor ?? Colors.orange,
                          size: 18,
                        ),
                        Text(
                          _weatherData?.displayTemp ?? '--°C',
                          style: const TextStyle(fontSize: 10, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),

                  StreamBuilder<int>(
                    stream: CalendarEventService.instance.watchUnreadCount(),
                    builder: (ctx, snap) {
                      final unread = snap.data ?? 0;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _HeaderBtn(
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppNotificationScreen())),
                            child: const Icon(Icons.notifications_none_rounded, size: 20, color: Color(0xFF7D6E5D)),
                          ),
                          if (unread > 0)
                            Positioned(
                              top: -2, right: -2,
                              child: Container(
                                width: 16, height: 16,
                                decoration: const BoxDecoration(color: Color(0xFFE57373), shape: BoxShape.circle),
                                child: Center(
                                  child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(width: 8),

                  _HeaderBtn(
                      onTap: () async {
                        final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const QRScanScreen()));
                        if (result != null && context.mounted) {
                          showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                title: const Text('🎉 掃描成功', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                                content: Text('掃描內容：\n$result', style: const TextStyle(height: 1.5)),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('確定', style: TextStyle(color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)))
                                ],
                              )
                          );
                        }
                      },
                      child: const Icon(Icons.qr_code_scanner_rounded, size: 18, color: Color(0xFF7D6E5D))
                  ),
                  const SizedBox(width: 10),

                  GestureDetector(
                    onTap: () { AppStateManager.currentTabNotifier.value = 6; },
                    child: Container(width: 40, height: 40, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88), width: 2)), child: ClipOval(child: UserAvatar(user: user, radius: 20))),
                  ),
                ],
              ),
            ],
          ),

          // ── EXPLORE CHIAYI + 問候 + 吉祥物 ──────────────
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左：EXPLORE CHIAYI 標題
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('EXPLORE', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), height: 1.0)),
                    Text('CHIAYI', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 42, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), height: 1.0)),
                  ],
                ),

                // 中：吉祥物不倒翁晃動（緊貼標題右邊）
                if (_unlockedMascots.isNotEmpty) ...[
                  Transform.translate(
                    offset: const Offset(0, 10),
                    child: GestureDetector(
                      onTap: () => _showMascotPicker(context),
                      child: AnimatedBuilder(
                        animation: _wobbleAnim,
                        builder: (_, child) => Transform.translate(
                          offset: Offset(_wobbleAnim.value, 0),
                          child: child,
                        ),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: OverflowBox(
                            maxWidth: 160,
                            maxHeight: 160,
                            child: Image.asset(
                              'assets/images/vo/${_unlockedMascots[_activeMascotIdx].$3}.png',
                              width: 160,
                              height: 160,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Text('🐾', style: TextStyle(fontSize: 56)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                const Spacer(),

                // 右：日期 + Hi
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          Text(dateStr, style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFF7D6E5D).withOpacity(0.6), fontSize: 16)),
                          const SizedBox(width: 4),
                          const Icon(Icons.eco_rounded, color: Color(0xFF8BAA88), size: 16),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                        child: Text('Hi, $displayName 👋', style: const TextStyle(fontSize: 11, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(25), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]),
        child: TextField(
          controller: _searchCtrl,
          textInputAction: TextInputAction.search,
          onChanged: _doLocalSearch,
          decoration: InputDecoration(
            hintText: '搜尋活動、住宿、美食...',
            hintStyle: const TextStyle(color: Color(0xFF9E9182), fontSize: 14),
            prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
            suffixIcon: _searchCtrl.text.isNotEmpty ? GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                _doLocalSearch('');
              },
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.close_rounded, color: Color(0xFF9E9182), size: 18)),
            ) : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    final colors = {'活動': const Color(0xFF8BAA88), '住宿': const Color(0xFF7D6E5D), '美食': const Color(0xFFE8A020)};
    if (_searchResults.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('找不到相關結果 🌱', style: TextStyle(color: Color(0xFF9E9182), fontSize: 14))));
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 12, offset: const Offset(0, 4))]),
      child: Column(
        children: _searchResults.map((r) {
          final c = colors[r.tag] ?? const Color(0xFF8BAA88);
          return ListTile(
            leading: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
              child: Text(r.tag, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            title: Text(r.name, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 14, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(r.subtitle, style: const TextStyle(color: Color(0xFF9E9182), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _navigateToDetail(r.tag, r.originalModel),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTicker() {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFFFFF9F0), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF9E9182).withOpacity(0.15))),
      child: Row(
        children: [
          const Icon(Icons.campaign_rounded, color: Color(0xFF8BAA88), size: 20),
          const SizedBox(width: 12),
          Expanded(child: _MarqueeText(text: _tickerText, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 12))),
        ],
      ),
    );
  }

  Widget _buildBanner() {
    if (!_dataLoaded) {
      return Container(height: 180, margin: const EdgeInsets.symmetric(horizontal: 24), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.15), borderRadius: BorderRadius.circular(24)), child: const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2)));
    }
    if (_banners.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 180,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: (i) => setState(() => _bannerIndex = i),
            itemCount: _banners.length,
            itemBuilder: (_, i) {
              final b = _banners[i];
              final actModel = b['model'] as ActivityItem;
              return GestureDetector(
                onTap: () => _navigateToDetail('活動', actModel),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      buildSmartImage( // ✨ 支援 Base64
                        imageUrl: b['image'] as String?,
                        imageBase64: b['imageBase64'] as String?,
                        fit: BoxFit.cover,
                      ),
                      Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.6)]))),
                      Positioned(
                        bottom: 20, left: 20, right: 60,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(b['title'] as String, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(b['desc'] as String, style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Positioned(
            bottom: 12, right: 20,
            child: Row(
              children: List.generate(_banners.length, (i) => AnimatedContainer(duration: const Duration(milliseconds: 300), margin: const EdgeInsets.only(left: 4), width: i == _bannerIndex ? 18 : 6, height: 6, decoration: BoxDecoration(color: i == _bannerIndex ? Colors.white : Colors.white.withOpacity(0.5), borderRadius: BorderRadius.circular(3)))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickEntries(BuildContext context) {
    final List<Widget> pages = [ const NewsScreen(), const AttractionsScreen(), const TrafficScreen(), const FoodScreen(), const AccommodationScreen(), const CalendarScreen() ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: _buildSectionTitle('快速入口'),
        ),
        GridView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.2),
          itemCount: _quickEntries.length,
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => pages[i])),
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.01), blurRadius: 10)]),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_quickEntries[i].$1, color: _quickEntries[i].$3, size: 28),
                    const SizedBox(height: 6),
                    Text(_quickEntries[i].$2, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                  ]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHotSpots() {
    final tagColors = {'活動': const Color(0xFF8BAA88), '住宿': const Color(0xFF7D6E5D), '美食': const Color(0xFFE8A020), '景點': const Color(0xFFA5CBD4)};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          child: _buildSectionTitle('本週熱門'),
        ),
        if (!_dataLoaded)
          const SizedBox(height: 220, child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2)))
        else
          SizedBox(
            height: 250,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: _hotItems.length,
              itemBuilder: (_, i) {
                final item = _hotItems[i];
                final tagColor = tagColors[item.tag] ?? const Color(0xFF8BAA88);
                return GestureDetector(
                  onTap: () => _navigateToDetail(item.tag, item.originalModel),
                  child: Container(
                    width: 180, margin: const EdgeInsets.only(right: 16),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))]),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          buildSmartImage( // ✨ 支援 Base64
                            imageUrl: item.imageUrl,
                            imageBase64: item.imageBase64,
                            fit: BoxFit.cover,
                          ),
                          const Positioned(top: 12, right: 12, child: _FrostedHeart()),
                          Positioned(top: 12, left: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: tagColor, borderRadius: BorderRadius.circular(10)), child: Text('TOP ${i + 1}', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)))),
                          Positioned(
                            bottom: 0, left: 0, right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              color: const Color(0xFFF9F8F4).withOpacity(0.95),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.name, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 13, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 5),
                                  Row(children: [
                                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: tagColor.withOpacity(0.1), borderRadius: BorderRadius.circular(6)), child: Text(item.tag, style: TextStyle(color: tagColor, fontSize: 9, fontWeight: FontWeight.bold))),
                                    const SizedBox(width: 4),
                                    Expanded(child: Text(item.subtitle, style: const TextStyle(color: Color(0xFF9E9182), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  ]),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Stack(
      children: [
        Positioned(bottom: 3, left: 0, right: 0, child: Container(height: 10, decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.5), borderRadius: BorderRadius.circular(2)))),
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), letterSpacing: 1.2)),
      ],
    );
  }
}

// 修改前：
// onTap: () {},

// 修改後：
class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  const _DrawerItem({required this.icon, required this.title, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF7D6E5D)),
      title: Text(title, style: const TextStyle(color: Color(0xFF7D6E5D), fontWeight: FontWeight.w500, fontFamily: 'MyCustomFont')),
      onTap: onTap ?? () => Navigator.pop(context),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HeaderBtn({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.1))),
          child: Center(child: child)
      ),
    );
  }
}

class _FrostedHeart extends StatelessWidget {
  const _FrostedHeart();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: Container(width: 32, height: 32, color: Colors.white.withOpacity(0.25), child: const Center(child: Icon(Icons.favorite_border_rounded, color: Colors.white, size: 18)))),
    );
  }
}

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});
  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scroll());
  }

  void _scroll() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(seconds: 12), curve: Curves.linear);
        await Future.delayed(const Duration(milliseconds: 1500));
        if (_scrollController.hasClients) _scrollController.jumpTo(0.0);
      }
    }
  }

  @override
  void dispose() { _scrollController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(controller: _scrollController, scrollDirection: Axis.horizontal, physics: const NeverScrollableScrollPhysics(), child: Text(widget.text, style: widget.style));
  }
}

// ═══════════════════════════════════════════════════════════════
//  App 通知中心（從 Firestore app_notifications 讀取）
// ═══════════════════════════════════════════════════════════════
class AppNotificationScreen extends StatelessWidget {
  const AppNotificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: StreamBuilder<List<AppNotification>>(
        stream: CalendarEventService.instance.watchMyNotifications(),
        builder: (ctx, snap) {
          final notifs = snap.data ?? [];
          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── 雜誌風標題 Header ──
              SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 60, 20, 16),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                            ),
                            child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Color(0xFF7D6E5D)),
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('MY ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
                              Text('INBOX', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8BAA88).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3), width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.notifications_rounded, size: 14, color: Color(0xFF8BAA88)),
                                const SizedBox(width: 6),
                                Text('共 ${notifs.length} 則通知', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // 全部已讀按鈕
                      Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () async {
                            final uid = FirebaseAuth.instance.currentUser?.uid;
                            if (uid == null) return;
                            final s = await FirebaseFirestore.instance
                                .collection('users').doc(uid).collection('app_notifications')
                                .where('isRead', isEqualTo: false).get();
                            for (final doc in s.docs) await doc.reference.update({'isRead': true});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8BAA88).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                            ),
                            child: const Text('全已讀', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── 通知清單 ──
              if (snap.connectionState == ConnectionState.waiting)
                const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.symmetric(vertical: 60),
                      child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2))),
                )
              else if (notifs.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.notifications_none_rounded, size: 64, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        const Text('目前沒有通知 🌱', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 16)),
                      ]),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 80),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                          (ctx, i) {
                        final n = notifs[i];
                        final isReminder = n.type == 'event_reminder' || n.type == 'itinerary_calendar';
                        final isShare = n.type == 'event_share';
                        final isRainAlert = n.type == 'rain_alert'; // ★
                        final color = isRainAlert
                            ? const Color(0xFF7FA3B0)
                            : isShare
                            ? const Color(0xFFA5CBD4)
                            : isReminder ? const Color(0xFF8BAA88) : const Color(0xFF7D6E5D);
                        final icon = isRainAlert
                            ? Icons.umbrella_rounded
                            : isShare
                            ? Icons.card_giftcard_rounded
                            : isReminder ? Icons.notifications_active_rounded : Icons.campaign_rounded;

                        return Dismissible(
                          key: Key(n.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(color: const Color(0xFF9E9182).withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
                            child: const Icon(Icons.delete_outline_rounded, color: Color(0xFF9E9182)),
                          ),
                          onDismissed: (_) => CalendarEventService.instance.deleteNotification(n.id),
                          child: GestureDetector(
                            onTap: () async {
                              if (!n.isRead) CalendarEventService.instance.markRead(n.id);
                              if (isRainAlert) {
                                // ★ rain_alert：直接顯示備案說明 dialog，不跳 EventDetailScreen
                                showDialog(
                                  context: ctx,
                                  builder: (_) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    backgroundColor: const Color(0xFFFDFCF5),
                                    title: const Row(children: [
                                      Text('☂️', style: TextStyle(fontSize: 20)),
                                      SizedBox(width: 8),
                                      Text('雨天備案提醒', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                                    ]),
                                    content: Text(n.body, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF9E9182), height: 1.5)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('關閉', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7FA3B0), fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              final event = n.toEventModel();
                              Navigator.push(ctx, MaterialPageRoute(
                                builder: (_) => EventDetailScreen(event: event, isAdded: isReminder),
                              ));
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: n.isRead ? Colors.white : color.withOpacity(0.04),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: n.isRead ? color.withOpacity(0.12) : color.withOpacity(0.35)),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                                    child: Icon(icon, color: color, size: 20),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Expanded(child: Text(n.title,
                                              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14,
                                                  fontWeight: n.isRead ? FontWeight.w600 : FontWeight.w900, color: const Color(0xFF7D6E5D)))),
                                          if (!n.isRead)
                                            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                                        ]),
                                        const SizedBox(height: 4),
                                        Text(n.body, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF9E9182), height: 1.4)),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(_formatTime(n.createdAt), style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                                            Row(children: [
                                              // 分享通知 → 加入月曆
                                              if (isShare)
                                                GestureDetector(
                                                  onTap: () async {
                                                    final ok = await CalendarEventService.instance.addFromNotification(n);
                                                    if (ctx.mounted) {
                                                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                                        content: Text(ok ? '✅ 已加入月曆！' : '⚠️ 已在月曆中', style: const TextStyle(fontFamily: 'MyCustomFont')),
                                                        backgroundColor: ok ? const Color(0xFF8BAA88) : const Color(0xFFBCAAA4),
                                                        behavior: SnackBarBehavior.floating,
                                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                      ));
                                                    }
                                                  },
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFF8BAA88).withOpacity(0.1),
                                                      borderRadius: BorderRadius.circular(10),
                                                      border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                                                    ),
                                                    child: const Text('加入月曆', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontSize: 11, fontWeight: FontWeight.bold)),
                                                  ),
                                                ),
                                              if (isShare) const SizedBox(width: 6),
                                              // 所有通知 → 查看詳情
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: color.withOpacity(0.08),
                                                  borderRadius: BorderRadius.circular(10),
                                                ),
                                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                  Text('查看介紹', style: TextStyle(fontFamily: 'MyCustomFont', color: color, fontSize: 11, fontWeight: FontWeight.bold)),
                                                  const SizedBox(width: 2),
                                                  Icon(Icons.arrow_forward_ios_rounded, size: 9, color: color),
                                                ]),
                                              ),
                                            ]),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: notifs.length,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
            ],
          );
        },
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '剛剛';
    if (diff.inHours < 1) return '${diff.inMinutes} 分鐘前';
    if (diff.inDays < 1) return '${diff.inHours} 小時前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}';
  }
}

class NotificationScreen extends StatelessWidget {
  final ActivityItem? newestActivity;
  final FoodModel? featuredFood;
  final HotelModel? featuredHotel;

  const NotificationScreen({
    super.key,
    this.newestActivity,
    this.featuredFood,
    this.featuredHotel,
  });

  @override
  Widget build(BuildContext context) {
    final notifications = [
      {
        'title': '系統公告',
        'desc': '歡迎使用嘉義旅遊導覽 App！探索最新景點與慢活美食。',
        'icon': Icons.campaign_rounded,
        'color': const Color(0xFF7D6E5D),
        'time': '剛剛',
        'tag': '',
        'model': null
      },
      {
        'title': '活動提醒',
        'desc': newestActivity != null ? '最新活動：[${newestActivity!.name}] 熱烈進行中，點擊查看活動詳情！' : '阿里山花季即將在下週開始，趕快安排行程吧！',
        'icon': Icons.event_available_rounded,
        'color': const Color(0xFF8BAA88),
        'time': '2 小時前',
        'tag': '活動',
        'model': newestActivity
      },
      {
        'title': '優惠快訊',
        'desc': featuredFood != null ? '慢活美食推薦：來品嚐在地老字號 [${featuredFood!.name}]，看懂饕客怎麼吃！' : '林聰明沙鍋魚頭今日出示 App 享專屬優惠！',
        'icon': Icons.restaurant_rounded,
        'color': const Color(0xFFE8A020),
        'time': '1 天前',
        'tag': '美食',
        'model': featuredFood
      },
      {
        'title': '住宿推薦',
        'desc': featuredHotel != null ? '優質住宿推薦：漫步嘉義精選 [${featuredHotel!.name}] 舒適套房，立刻點擊預約！' : '週末天氣晴朗，為您精選嘉義靠近市區優質文青旅宿。',
        'icon': Icons.hotel_rounded,
        'color': const Color(0xFFA5CBD4),
        'time': '2 天前',
        'tag': '住宿',
        'model': featuredHotel
      },
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Color(0xFF7D6E5D)),
        title: const Text('消息中心', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(20),
        physics: const BouncingScrollPhysics(),
        itemCount: notifications.length,
        separatorBuilder: (_, __) => const SizedBox(height: 16),
        itemBuilder: (ctx, i) {
          final n = notifications[i];
          final color = n['color'] as Color;
          final model = n['model'];
          final tag = n['tag'] as String;

          return GestureDetector(
            onTap: () {
              if (tag.isNotEmpty && model != null) {
                if (tag == '活動' && model is ActivityItem) {
                  Navigator.push(ctx, MaterialPageRoute(builder: (_) => NewsDetailScreen(activity: model)));
                } else if (tag == '美食' && model is FoodModel) {
                  Navigator.push(ctx, MaterialPageRoute(builder: (_) => FoodDetailScreen(foodData: model)));
                } else if (tag == '住宿' && model is HotelModel) {
                  Navigator.push(ctx, MaterialPageRoute(builder: (_) => HotelDetailScreen(hotel: model)));
                }
              }
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.3)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
                    child: Icon(n['icon'] as IconData, color: color, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(n['title'] as String, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                            Text(n['time'] as String, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(n['desc'] as String, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF555555), height: 1.5)),
                        if (tag.isNotEmpty && model != null) ...[
                          const SizedBox(height: 10),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('查看詳情', style: TextStyle(color: Color(0xFF8BAA88), fontSize: 12, fontWeight: FontWeight.bold)),
                              SizedBox(width: 2),
                              Icon(Icons.arrow_forward_ios_rounded, size: 10, color: Color(0xFF8BAA88))
                            ],
                          )
                        ]
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class QRScanScreen extends StatefulWidget {
  const QRScanScreen({super.key});

  @override
  State<QRScanScreen> createState() => _QRScanScreenState();
}

class _QRScanScreenState extends State<QRScanScreen> {
  MobileScannerController cameraController = MobileScannerController();
  bool _isScanned = false;

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('掃描 QR Code', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.flashlight_on_rounded),
            iconSize: 28.0,
            onPressed: () => cameraController.toggleTorch(),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.cameraswitch_rounded),
            iconSize: 28.0,
            onPressed: () => cameraController.switchCamera(),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MobileScanner(
            controller: cameraController,
            onDetect: (capture) {
              if (_isScanned) return;
              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                _isScanned = true;
                final String code = barcodes.first.rawValue!;
                Navigator.pop(context, code);
              }
            },
          ),
          Center(
            child: Container(
              width: 250, height: 250,
              decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF8BAA88), width: 4),
                  borderRadius: BorderRadius.circular(24)
              ),
              child: Stack(
                children: [
                  Center(
                    child: Container(
                      width: double.infinity, height: 2,
                      color: const Color(0xFF8BAA88).withOpacity(0.5),
                    ),
                  )
                ],
              ),
            ),
          ),
          const Positioned(
            bottom: 50, left: 0, right: 0,
            child: Text('將 QR Code 對準框內即可自動掃描', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 14)),
          )
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  AI 雨備方案 Bottom Sheet
// ═══════════════════════════════════════════════════════════════
// ── 天氣數據小格子 ──────────────────────────────────────────────
class _WeatherStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _WeatherStatChip({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 13, color: color)),
            Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey[500])),
          ],
        ),
      ),
    );
  }
}

class _RainAlternativeSheet extends StatefulWidget {
  final WeatherData weather;
  final String itineraryTitle;
  final String itineraryId;           // ★ 用於套用備案時更新行程
  const _RainAlternativeSheet({required this.weather, required this.itineraryTitle, this.itineraryId = ''});

  @override
  State<_RainAlternativeSheet> createState() => _RainAlternativeSheetState();
}

class _RainAlternativeSheetState extends State<_RainAlternativeSheet> {
  static const String _apiKey = 'YOUR_GEMINI_API_KEY';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  bool _isLoading = true;
  String _aiResponse = '';
  String? _error;
  bool _isApplying = false;           // ★ 套用中狀態

  static const Color _blue = Color(0xFF7FA3B0);
  static const Color _brown = Color(0xFF7D6E5D);
  static const Color _bg = Color(0xFFFDFCF5);

  @override
  void initState() {
    super.initState();
    _fetchAlternatives();
  }

  Future<void> _fetchAlternatives() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final prompt =
          '今天嘉義天氣：${widget.weather.displayDesc}，'
          '降雨機率 ${widget.weather.precipitation}%，'
          '氣溫 ${widget.weather.displayTemp}，'
          '濕度 ${widget.weather.humidity ?? "--"}%。\n'
          '原本計畫的行程：「${widget.itineraryTitle}」可能受到雨天影響。\n'
          '請以嘉義在地人的角度，提供 3 個適合雨天或室內的備案景點/活動，'
          '格式要求：\n'
          '1. 【景點名稱】\n說明（50字以內，包含地址、特色或門票資訊）\n\n'
          '2. 【景點名稱】\n說明\n\n'
          '3. 【景點名稱】\n說明\n\n'
          '最後加一行小貼士：雨天出門注意事項（30字以內）。'
          '只回答繁體中文，不加多餘的開頭語。';

      final body = jsonEncode({
        'contents': [{'role': 'user', 'parts': [{'text': prompt}]}],
      });

      final resp = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 20));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final text = (data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '').trim();
        setState(() { _aiResponse = text; _isLoading = false; });
      } else {
        setState(() { _error = '取得備案失敗（${resp.statusCode}）'; _isLoading = false; });
      }
    } catch (e) {
      setState(() { _error = '網路連線問題：$e'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            // ── 拖曳把手 ──
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            // ── 標題 ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: _blue.withOpacity(0.12), borderRadius: BorderRadius.circular(14)),
                    child: Text(widget.weather.weatherEmoji, style: const TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('AI 雨天備案建議', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: _brown)),
                        Text(
                          '今日 ${widget.weather.displayDesc} ${widget.weather.displayTemp} · 降雨 ${widget.weather.precipitation}%',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: _blue),
                    onPressed: _isLoading ? null : _fetchAlternatives,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // ── 行程名稱橫幅 ──
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _blue.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.route_rounded, size: 16, color: _blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '原行程：${widget.itineraryTitle}',
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: _brown, fontWeight: FontWeight.bold),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            // ── AI 回應 ──
            Expanded(
              child: _isLoading
                  ? const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: _blue, strokeWidth: 2),
                  SizedBox(height: 16),
                  Text('AI 正在為你規劃雨天備案…', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13)),
                ]),
              )
                  : _error != null
                  ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _fetchAlternatives,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重試', style: TextStyle(fontFamily: 'MyCustomFont')),
                      style: ElevatedButton.styleFrom(backgroundColor: _blue),
                    ),
                  ]),
                ),
              )
                  : ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                children: [
                  ..._parseAiResponse(_aiResponse),
                  const SizedBox(height: 16),
                  // ★ 套用備案到今日行程按鈕
                  if (widget.itineraryId.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isApplying ? null : () => _applyRainPlan(),
                        icon: _isApplying
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.check_circle_rounded, size: 18),
                        label: Text(
                          _isApplying ? '套用中…' : '✅ 套用備案到今日行程',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8BAA88),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                        ),
                      ),
                    ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 套用 AI 備案到今日行程 ─────────────────────────────────
  Future<void> _applyRainPlan() async {
    if (_aiResponse.isEmpty || widget.itineraryId.isEmpty) return;
    setState(() => _isApplying = true);

    try {
      // 請 AI 把文字備案轉成結構化 JSON
      const apiKey = 'YOUR_GEMINI_API_KEY';
      const baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

      final jsonPrompt =
          '請將以下嘉義雨天備案景點建議轉換成行程 JSON 格式。\n'
          '原文：\n$_aiResponse\n\n'
          '輸出格式（只輸出 JSON 陣列，不要加任何說明或 markdown）：\n'
          '[{"dayLabel":"Day 1","items":['
          '{"time":"09:00","title":"景點名稱","location":"嘉義市","duration":"2小時","lat":23.4799,"lon":120.4488,'
          '"tips":"說明","ticket":"免費","transportTimes":{"car":"10min","transit":"15min","bike":"10min","walk":"20min"},'
          '"selectedTransport":"car"}]}]';

      final body = jsonEncode({
        'contents': [{'role': 'user', 'parts': [{'text': jsonPrompt}]}],
      });

      final resp = await http.post(
        Uri.parse('\$baseUrl?key=\$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 20));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        String jsonText = (data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '').trim();
        // 清除 markdown code block
        jsonText = jsonText.replaceAll(RegExp(r'```json|```'), '').trim();

        // 讀取原行程資料
        final existing = await local_db_service.LocalDbService.instance.getItinerary(widget.itineraryId);
        if (existing == null) throw Exception('找不到原行程');

        await ItinerarySaveService.instance.updateItinerary(
          id: widget.itineraryId,
          title: '\${widget.itineraryTitle}（雨天備案）',
          estimatedBudget: existing.estimatedBudget,
          startDate: existing.startDate,
          endDate: existing.endDate,
          plans: (jsonDecode(jsonText) as List).cast<Map<String, dynamic>>(),
        );

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('✅ 已套用雨天備案到行程！', style: TextStyle(fontFamily: 'MyCustomFont')),
              backgroundColor: const Color(0xFF8BAA88),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      } else {
        throw Exception('API 錯誤 \${resp.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isApplying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('套用失敗：\$e', style: const TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }


  // ── 解析 AI 回應成卡片列表 ─────────────────────────────────
  List<Widget> _parseAiResponse(String text) {
    if (text.isEmpty) return [const SizedBox.shrink()];

    final widgets = <Widget>[];
    // 按數字開頭拆分（1. 2. 3.）
    final parts = text.split(RegExp(r'\n(?=[1-9]\.)'));
    int cardIdx = 0;

    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;

      // 判斷是否是「小貼士」
      if (trimmed.startsWith('小貼士') || trimmed.contains('注意事項')) {
        widgets.add(
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _blue.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _blue.withOpacity(0.25)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('☂️', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                trimmed.replaceAll(RegExp(r'^小貼士[：:]?\s*'), ''),
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: _blue, height: 1.5),
              )),
            ]),
          ),
        );
        continue;
      }

      // 景點卡片
      final titleMatch = RegExp(r'【(.+?)】').firstMatch(trimmed);
      final title = titleMatch?.group(1) ?? '';
      final desc = trimmed
          .replaceAll(RegExp(r'^[0-9]+\.\s*'), '')
          .replaceAll(RegExp(r'【.+?】'), '')
          .trim();

      final colors = [const Color(0xFF8BAA88), const Color(0xFF7FA3B0), const Color(0xFFBCAAA4)];
      final color = colors[cardIdx % colors.length];
      cardIdx++;

      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(0.3)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
              child: Text('$cardIdx', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: color)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (title.isNotEmpty)
                  Text(title, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: _brown)),
                if (title.isNotEmpty) const SizedBox(height: 6),
                Text(desc, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.55)),
              ]),
            ),
          ]),
        ),
      );
    }

    if (widgets.isEmpty) {
      // fallback：整段顯示
      widgets.add(Text(_aiResponse, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: _brown, height: 1.6)));
    }
    return widgets;
  }
}

class _HomeTxtStyleDrawer extends StatefulWidget {
  const _HomeTxtStyleDrawer();

  @override
  State<_HomeTxtStyleDrawer> createState() => _HomeTxtStyleDrawerState();
}

class _HomeTxtStyleDrawerState extends State<_HomeTxtStyleDrawer> {
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
  }

  Future<void> _checkAdminStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        if (data['isAdmin'] == true && mounted) {
          setState(() => _isAdmin = true);
        }
      }
    } catch (e) {
      debugPrint('檢查管理員權限失敗: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isGuest = user == null;
    final displayName = user?.displayName ?? '訪客';
    final email = user?.email ?? '';

    return Drawer(
      backgroundColor: const Color(0xFFF9F8F4),
      elevation: 0,
      child: Column(
        children: [
          // ── 抹茶綠 Header + 白字 ──────────────────────────────
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 28, 24, 24),
            color: const Color(0xFF8BAA88),
            child: Row(children: [
              // 頭像
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.85), width: 2.5),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 10)],
                ),
                child: ClipOval(child: UserAvatar(user: user, radius: 32)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    displayName,
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 20,
                        fontWeight: FontWeight.w900, color: Colors.white),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  if (!isGuest)
                    Text(
                      email,
                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                          color: Colors.white.withOpacity(0.82)),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 8),
                  if (!isGuest)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.22),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.45)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle_rounded, size: 11, color: Colors.white),
                        SizedBox(width: 4),
                        Text('已登入', style: TextStyle(fontFamily: 'MyCustomFont',
                            fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                      ]),
                    )
                  else
                    GestureDetector(
                      onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())); },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.login_rounded, size: 13, color: Color(0xFF8BAA88)),
                          SizedBox(width: 5),
                          Text('點此登入', style: TextStyle(fontFamily: 'MyCustomFont',
                              fontSize: 12, color: Color(0xFF8BAA88), fontWeight: FontWeight.w900)),
                        ]),
                      ),
                    ),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 8),

          // ── 選單項目 ─────────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 8, 24, 6),
                  child: Text('帳號', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFFB0A898), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                _DItem(icon: Icons.person_rounded, label: '個人資料', color: const Color(0xFF8BAA88),
                    onTap: () { Navigator.pop(context); AppStateManager.currentTabNotifier.value = 6; }),
                _DItem(icon: Icons.favorite_rounded, label: '我的收藏', color: const Color(0xFFE8A0A0),
                    onTap: () { Navigator.pop(context); AppStateManager.currentTabNotifier.value = 3; }),
                _DItem(icon: Icons.auto_stories_rounded, label: '我的發布紀錄', color: const Color(0xFF7FA3B0),
                    onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => UserLogsPage(posts: const [], onRefresh: () async {}))); }),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 16, 24, 6),
                  child: Text('設定', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFFB0A898), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                _DItem(icon: Icons.settings_rounded, label: '系統設定', color: const Color(0xFF9E9182),
                    onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const SystemSettingsScreen())); }),
                _DItem(icon: Icons.help_rounded, label: '幫助與支援', color: const Color(0xFFB09070),
                    onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpSupportScreen())); }),
                // ✨ 管理員後台入口
                if (_isAdmin) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 16, 24, 6),
                    child: Text('管理員', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                        color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  ),
                  _DItem(icon: Icons.admin_panel_settings_rounded, label: '系統管理員後台', color: const Color(0xFF8BAA88),
                      onTap: () {
                        Navigator.pop(context); // 關閉側邊欄
                        // 🚀 這裡把原本的 AdminDashboardScreen 改成 AdminMainScreen！
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminMainScreen()));
                      }),
                ],
              ],
            ),
          ),

          // ── 底部按鈕 ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: isGuest
                ? GestureDetector(
              onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())); },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF8BAA88),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4))],
                ),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.login_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('登入 / 註冊帳號', style: TextStyle(fontFamily: 'MyCustomFont',
                      color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
                ]),
              ),
            )
                : GestureDetector(
              onTap: () => _confirmLogout(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0EDE8),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF9E9182).withOpacity(0.25)),
                ),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.logout_rounded, color: Color(0xFF9E9182), size: 18),
                  SizedBox(width: 8),
                  Text('安全登出', style: TextStyle(fontFamily: 'MyCustomFont',
                      color: Color(0xFF9E9182), fontWeight: FontWeight.w900, fontSize: 15)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF9F8F4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(children: [
          Container(padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF9E9182).withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.logout_rounded, color: Color(0xFF9E9182), size: 20)),
          const SizedBox(width: 10),
          const Text('確認登出', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
        ]),
        content: const Text('確定要登出帳號嗎？', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx); Navigator.pop(context);
              await FirebaseAuth.instance.signOut();
              if (context.mounted) Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
            },
            child: const Text('確定登出', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }
}

// ✨ 萬用圖片元件：優先顯示 Base64，備用 URL，都沒有則顯示預設圖
Widget buildSmartImage({String? imageUrl, String? imageBase64, double? width, double? height, BoxFit fit = BoxFit.cover}) {
  if (imageBase64 != null && imageBase64.isNotEmpty) {
    try {
      final cleanBase64 = imageBase64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
      return Image.memory(
        base64Decode(cleanBase64),
        width: width, height: height, fit: fit, gaplessPlayback: true,
      );
    } catch (e) {
      debugPrint('Base64 圖片解碼失敗: $e');
    }
  }

  if (imageUrl != null && imageUrl.isNotEmpty && imageUrl.startsWith('http')) {
    return Image.network(
      imageUrl, width: width, height: height, fit: fit,
      errorBuilder: (ctx, err, stack) => _buildErrorPlaceholder(width, height),
    );
  }

  return _buildErrorPlaceholder(width, height);
}

Widget _buildErrorPlaceholder(double? width, double? height) {
  return Container(
    width: width, height: height, color: const Color(0xFFE2E8F0),
    child: const Icon(Icons.image_not_supported, color: Colors.grey),
  );
}

class _DItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _DItem({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: const TextStyle(
                  fontFamily: 'MyCustomFont', fontSize: 15,
                  fontWeight: FontWeight.w700, color: Color(0xFF4A3728)))),
              Icon(Icons.chevron_right_rounded, color: const Color(0xFFCFC8C0), size: 18),
            ]),
          ),
        ),
      ),
    );
  }
}