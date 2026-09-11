// ═══════════════════════════════════════════════════════════════
//  favorites_screen.dart  (我的收藏頁面 ─ 終極復原版)
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

import 'ai_screen.dart';
import 'cover_screen.dart';
import 'community_screen.dart';
import 'profile_screen.dart';
import 'home_screen.dart';
import 'app_state.dart';
import 'calendar_screen.dart' show CalendarEvent, CalendarEventType, EventDetailScreen;
import 'weather_service.dart';
import 'login_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  int _tabIndex = 0;
  final List<String> _tabs = ['全部', '景點', '美食', '住宿', '活動'];
  final TextEditingController _searchController = TextEditingController();

  final Set<String> _selectedTitles = {};

  late AnimationController _floatController;
  late Animation<Offset> _floatAnimation;

  bool _isLoading = true;
  List<Map<String, String>> _favorites = [];

  // ★ 天氣狀態
  WeatherData? _weatherData;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _floatAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, -0.05),
    ).animate(CurvedAnimation(
      parent: _floatController,
      curve: Curves.easeInOut,
    ));

    _loadFavoritesFromFirebase();
    _loadActivityFavorites();
    // ★ 載入天氣
    WeatherService.instance.getChiayiWeather().then((data) {
      if (mounted && data != null) setState(() => _weatherData = data);
    });
  }

  // ── 活動收藏（從 users/{uid}/favorites 小寫，type=='活動'）──────────
  List<Map<String, String>> _activityFavorites = [];

  Future<void> _loadActivityFavorites() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('favorites')
          .where('type', isEqualTo: '活動')
          .get();
      if (mounted) {
        setState(() {
          _activityFavorites = snap.docs.map((d) {
            final m = d.data();
            return {
              'type': '活動',
              'title': m['title']?.toString() ?? '',
              'sub': m['sub']?.toString() ?? '嘉義活動',
              'score': m['score']?.toString() ?? '5.0',
              'date': m['date']?.toString() ?? '',
              'img': m['image']?.toString() ?? '',
              'desc': m['desc']?.toString() ?? '',
              'tags': (m['tags'] as List? ?? []).join(','),
              'favId': d.id,
            };
          }).where((m) => m['title']!.isNotEmpty).toList();
        });
      }
    } catch (e) {
      debugPrint('載入活動收藏失敗: $e');
    }
  }

  @override
  void dispose() {
    _floatController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFavoritesFromFirebase() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      // ★ 讀小寫 'favorites'（map_screen 存的路徑）
      final favSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('favorites')
          .get();

      final List<Map<String, String>> loadedList = [];

      for (final doc in favSnap.docs) {
        final d = doc.data();
        // 跳過活動（由 _loadActivityFavorites 處理）
        final type = d['type']?.toString() ?? '';
        if (type == '活動') continue;

        final title = d['title']?.toString() ?? '';
        if (title.isEmpty) continue;

        final img = d['image']?.toString() ?? '';
        final sub  = d['sub']?.toString()  ?? type;
        String score = d['score']?.toString() ?? '5.0';
        if (score == '0' || score == '0.0') score = '5.0';

        final createdAt = d['createdAt']?.toString() ?? '';
        String date = '近期收藏';
        if (createdAt.isNotEmpty) {
          try {
            final dt = DateTime.parse(createdAt);
            date = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          } catch (_) {}
        }

        loadedList.add({
          'type':   type.isNotEmpty ? type : '景點',
          'title':  title,
          'sub':    sub,
          'score':  score,
          'date':   date,
          'img':    img.isNotEmpty ? img : 'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=400',
          'favId':  doc.id,
        });
      }

      // 按收藏時間降冪
      loadedList.sort((a, b) => b['date']!.compareTo(a['date']!));

      if (mounted) {
        setState(() {
          _favorites = loadedList;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('載入收藏失敗: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _removeFavorite(String title) async {
    final user = FirebaseAuth.instance.currentUser;
    // 找到對應的 favId（即 Firestore doc id，如 'poi_xxx'）
    final item = _favorites.firstWhere(
          (f) => f['title'] == title,
      orElse: () => {},
    );
    final favId = item['favId'] ?? title;

    if (user != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('favorites')   // ★ 小寫，與 map_screen 一致
          .doc(favId)
          .delete();
    }

    setState(() {
      _favorites.removeWhere((item) => item['title'] == title);
      _selectedTitles.remove(title);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已將項目移出收藏清單 🗑️', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF9E9182),
        ),
      );
    }
  }

  void _sendToAiAssistant() {
    if (_selectedTitles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('請先勾選至少一個想去的景點或美食喔！', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF7D6E5D),
        ),
      );
      return;
    }

    AppStateManager.aiFavoritesNotifier.value = _selectedTitles.toList();
    AppStateManager.currentTabNotifier.value = 2;
  }

  List<Map<String, String>> get filteredFavorites {
    final search = _searchController.text.toLowerCase();
    // tab 4 = 活動：only activity favorites
    if (_tabIndex == 4) {
      return _activityFavorites.where((fav) =>
      search.isEmpty || fav['title']!.toLowerCase().contains(search)).toList();
    }
    // tab 0 = 全部：merge regular + activity
    final regular = _favorites.where((fav) {
      bool matchTab = _tabIndex == 0 || fav['type'] == _tabs[_tabIndex];
      bool matchSearch = search.isEmpty || fav['title']!.toLowerCase().contains(search);
      return matchTab && matchSearch;
    }).toList();
    if (_tabIndex == 0) {
      final activities = _activityFavorites.where((fav) =>
      search.isEmpty || fav['title']!.toLowerCase().contains(search)).toList();
      return [...regular, ...activities];
    }
    return regular;
  }

  @override
  Widget build(BuildContext context) {
    final currentList = filteredFavorites;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      //drawer: const _HomeTxtStyleDrawer(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _buildInlineSpecialHeader(context),
          ),
          SliverToBoxAdapter(
            child: _buildSearchBarSection(),
          ),
          SliverToBoxAdapter(
            child: _buildFilterTabsSection(),
          ),
          // ★ 雨天提示 banner（降雨機率 ≥ 30% 時顯示）
          if (_weatherData != null && _weatherData!.isPrepareRainy)
            SliverToBoxAdapter(child: _buildRainWarningBanner()),
          SliverToBoxAdapter(
            child: _buildAiBannerSection(),
          ),

          if (_isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40.0),
                child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88))),
              ),
            )
          else if (currentList.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 60.0),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.favorite_border_rounded, size: 48, color: Colors.grey.withOpacity(0.3)),
                      const SizedBox(height: 16),
                      const Text('這裡空空的，快去探索並收藏喜歡的景點吧！', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 100),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                      (context, index) => _buildMagazineStyleCard(currentList[index]),
                  childCount: currentList.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInlineSpecialHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 52, 24, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            // 💡 關鍵在這裡：這行會打開你在 home_screen.dart 綁定的 Drawer！
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu_rounded, size: 32, color: Color(0xFF7D6E5D)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            alignment: Alignment.centerLeft,
          ),
          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: const TextSpan(
                    style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                    children: [
                      TextSpan(text: 'MY ', style: TextStyle(color: Color(0xFF7D6E5D))),
                      TextSpan(text: 'FAVORITES', style: TextStyle(color: Color(0xFF8BAA88))),
                    ],
                  ),
                ),
                const SizedBox(height: 6),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8BAA88).withOpacity(0.06),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF8BAA88).withOpacity(0.35),
                      width: 1.2,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.favorite_rounded, size: 13, color: Color(0xFF8BAA88)),
                      SizedBox(width: 6),
                      Text('我的收藏', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ★ 動態天氣顯示
          GestureDetector(
            onTap: () {
              WeatherService.instance.getChiayiWeather(forceRefresh: true).then((data) {
                if (mounted && data != null) setState(() => _weatherData = data);
              });
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _weatherData?.weatherIcon ?? Icons.wb_sunny_rounded,
                      color: _weatherData?.weatherColor ?? Colors.orange,
                      size: 18,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _weatherData?.displayTemp ?? '--°C',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF7D6E5D)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: (_weatherData?.weatherColor ?? const Color(0xFF8BAA88)).withOpacity(0.13),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_weatherData?.isRainy == true) ...[
                        const Text('☂️', style: TextStyle(fontSize: 11)),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        _weatherData?.displayDesc ?? '晴時多雲',
                        style: TextStyle(
                          fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold,
                          color: _weatherData?.weatherColor ?? const Color(0xFF8BAA88),
                        ),
                      ),
                      if (_weatherData != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          '${_weatherData!.precipitation}%',
                          style: TextStyle(
                            fontFamily: 'MyCustomFont', fontSize: 10,
                            color: _weatherData!.weatherColor.withOpacity(0.7),
                          ),
                        ),
                      ],
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

  Widget _buildSearchBarSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (v) => setState(() {}),
          style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
          decoration: InputDecoration(
            hintText: '搜尋您的收藏項目...',
            hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 13),
            prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
            suffixIcon: Padding(
              padding: const EdgeInsets.all(6.0),
              child: Container(
                decoration: const BoxDecoration(color: Color(0xFF8BAA88), shape: BoxShape.circle),
                child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
              ),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTabsSection() {
    return SizedBox(
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _tabs.length,
        itemBuilder: (context, i) {
          final isSel = i == _tabIndex;
          return GestureDetector(
            onTap: () => setState(() => _tabIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 12, bottom: 8, top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: isSel ? const Color(0xFF8BAA88) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isSel ? Colors.transparent : const Color(0xFF8BAA88).withOpacity(0.2)),
                  boxShadow: [
                    if (isSel) BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 3))
                    else BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4, offset: const Offset(0, 2)),
                  ]
              ),
              child: Text(
                _tabs[i],
                style: TextStyle(fontFamily: 'MyCustomFont', color: isSel ? Colors.white : const Color(0xFF7D6E5D), fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          );
        },
      ),
    );
  }

  // ★ 雨天警示 banner
  Widget _buildRainWarningBanner() {
    final w = _weatherData!;
    return GestureDetector(
      onTap: () {
        // 點擊後跳到 AI 頁面請求雨備方案
        AppStateManager.aiFavoritesNotifier.value = _selectedTitles.toList();
        AppStateManager.currentTabNotifier.value = 2; // AI tab
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 8, 24, 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF7FA3B0).withOpacity(0.1),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.4), width: 1.5),
        ),
        child: Row(children: [
          Text(w.weatherEmoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '今日 ${w.displayDesc}，降雨機率 ${w.precipitation}%',
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF7FA3B0)),
              ),
              const Text(
                '出遊前記得帶傘！點此讓 AI 推薦雨天景點 ☂️',
                style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey),
              ),
            ]),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, size: 13, color: Color(0xFF7FA3B0)),
        ]),
      ),
    );
  }

  Widget _buildAiBannerSection() {
    bool hasSelection = _selectedTitles.isNotEmpty;

    return SlideTransition(
      position: _floatAnimation,
      child: GestureDetector(
        onTap: _sendToAiAssistant,
        child: Container(
          margin: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: hasSelection ? const Color(0xFF8BAA88) : const Color(0xFFF9F8F4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF8BAA88).withOpacity(hasSelection ? 1.0 : 0.3), width: 1.5),
            boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(hasSelection ? 0.3 : 0.05), blurRadius: 15, offset: const Offset(0, 8))],
          ),
          child: Row(children: [
            Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: hasSelection ? Colors.white.withOpacity(0.2) : const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle), child: Icon(Icons.auto_awesome_rounded, color: hasSelection ? Colors.white : const Color(0xFF8BAA88), size: 24)),
            const SizedBox(width: 15),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(hasSelection ? '為您規劃 ${_selectedTitles.length} 個地點 ↗' : 'AI 智慧行程生成', style: TextStyle(fontFamily: 'MyCustomFont', color: hasSelection ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 17)), const SizedBox(height: 4), Text(hasSelection ? '點擊立即攜帶景點，出發與 AI 規劃對話！' : '請勾選下方項目，再讓 AI 幫您排行程', style: TextStyle(fontFamily: 'MyCustomFont', color: hasSelection ? Colors.white.withOpacity(0.9) : Colors.grey, fontSize: 12, fontWeight: FontWeight.bold))])),
            Icon(Icons.arrow_forward_ios_rounded, color: hasSelection ? Colors.white : const Color(0xFF8BAA88), size: 14)
          ]),
        ),
      ),
    );
  }

  Widget _buildMagazineStyleCard(Map<String, String> item) {
    final isChecked = _selectedTitles.contains(item['title']);
    final isActivity = item['type'] == '活動';

    Color typeColor = const Color(0xFF8BAA88);
    if (item['type'] == '美食') typeColor = const Color(0xFFD6895A);
    else if (item['type'] == '住宿') typeColor = const Color(0xFF7FA3B0);
    else if (isActivity) typeColor = const Color(0xFF8BAA88);

    return GestureDetector(
      onTap: () {
        if (isActivity) {
          // 活動收藏：跳到 EventDetailScreen
          final tags = (item['tags'] ?? '').isNotEmpty
              ? (item['tags']!).split(',').where((t) => t.isNotEmpty).toList()
              : <String>[];
          final event = CalendarEvent(
            id: item['favId'] ?? '',
            type: CalendarEventType.officialEvent,
            title: item['title'] ?? '',
            date: item['date'] ?? '',
            time: '',
            location: item['sub'] ?? '',
            desc: item['desc'] ?? '',
            image: item['img'] ?? '',
            tags: tags,
            createdAt: DateTime.now(),
          );
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => EventDetailScreen(event: event, isAdded: true),
          )).then((_) => _loadActivityFavorites());
        } else {
          setState(() {
            if (isChecked) _selectedTitles.remove(item['title']);
            else _selectedTitles.add(item['title']!);
          });
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isChecked ? const Color(0xFF8BAA88).withOpacity(0.04) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: isChecked ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.12), width: isChecked ? 2 : 1),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            Container(
              margin: const EdgeInsets.only(right: 12),
              child: Icon(isChecked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: isChecked ? const Color(0xFF8BAA88) : Colors.grey.withOpacity(0.4), size: 24),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                item['img']!,
                width: 76, height: 76, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(width: 76, height: 76, color: Colors.grey[200]),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: typeColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                        child: Text(item['type']!, style: TextStyle(fontFamily: 'MyCustomFont', color: typeColor, fontSize: 10, fontWeight: FontWeight.w900)),
                      ),
                      GestureDetector(
                        onTap: () => _removeFavorite(item['title']!),
                        child: const Icon(Icons.delete_outline_rounded, color: Color(0xFF7FA3B0), size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(item['title']!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 14),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          ' ${item['score']}  •  ${item['sub']}',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 🌟 純淨 Base64 大頭貼讀取版
class _UserAvatar extends StatefulWidget {
  final User? user;
  final double radius;
  const _UserAvatar({required this.user, this.radius = 20});

  @override
  State<_UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<_UserAvatar> {
  bool _isLoading = true;
  Uint8List? _cloudAvatarBytes;

  @override
  void initState() {
    super.initState();
    _loadAvatarWithCache();
  }

  Future<void> _loadAvatarWithCache() async {
    if (widget.user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'avatar_cache_${widget.user!.uid}';
      final cachedBase64 = prefs.getString(cacheKey);

      if (cachedBase64 != null && cachedBase64.isNotEmpty) {
        if (mounted) {
          setState(() {
            final cleanBase64 = cachedBase64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
            _cloudAvatarBytes = base64Decode(cleanBase64);
          });
        }
      }

      Map<String, dynamic>? data;
      final docSnap = await FirebaseFirestore.instance.collection('users').doc(widget.user!.uid).get();
      if (docSnap.exists && docSnap.data() != null) {
        data = docSnap.data();
      } else {
        final querySnap = await FirebaseFirestore.instance
            .collection('users')
            .where('uid', isEqualTo: widget.user!.uid)
            .limit(1)
            .get();
        if (querySnap.docs.isNotEmpty) {
          data = querySnap.docs.first.data();
        }
      }

      if (data != null) {
        if (data.containsKey('avatarBase64') && data['avatarBase64'] != null) {
          final cloudBase64 = data['avatarBase64'].toString();
          if (cloudBase64.length > 100) {
            if (cloudBase64 != cachedBase64) {
              await prefs.setString(cacheKey, cloudBase64);
              if (mounted) {
                setState(() {
                  final cleanBase64 = cloudBase64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
                  _cloudAvatarBytes = base64Decode(cleanBase64);
                });
              }
            }
          } else {
            await prefs.remove(cacheKey);
          }
        }
      }
    } catch (e) {
      debugPrint('讀取頭像失敗: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.user?.displayName ?? widget.user?.email ?? '旅';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '旅';

    if (_isLoading) {
      return CircleAvatar(radius: widget.radius, backgroundColor: const Color(0xFF8BAA88), child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)));
    }

    if (_cloudAvatarBytes != null) {
      return CircleAvatar(radius: widget.radius, backgroundColor: const Color(0xFF8BAA88), backgroundImage: MemoryImage(_cloudAvatarBytes!));
    }

    if (widget.user?.photoURL != null && widget.user!.photoURL!.isNotEmpty) {
      return CircleAvatar(radius: widget.radius, backgroundColor: const Color(0xFF8BAA88), backgroundImage: NetworkImage(widget.user!.photoURL!));
    }

    return CircleAvatar(radius: widget.radius, backgroundColor: const Color(0xFF8BAA88), child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)));
  }
}

// 🌟 全域共用的側邊欄 (終極正確版：完美區分 Tab 切換與獨立頁面)
class _HomeTxtStyleDrawer extends StatelessWidget {
  const _HomeTxtStyleDrawer();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isGuest = user == null;

    return Drawer(
      backgroundColor: const Color(0xFFF9F8F4),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
// ★ 精美旋轉頭像 Header（與首頁統一）
          _SharedDrawerHeader(user: user, displayName: user?.displayName ?? '訪客', email: user?.email ?? ''),

          // ── 1. 個人資料 (主分頁 Index 6) ──
          _buildItem(
              context,
              Icons.person_outline_rounded,
              '個人資料',
              onTap: () {
                Navigator.pop(context); // 先收起側邊欄
                if (isGuest) {
                  _showLoginRequired(context);
                  return;
                }
                // 🚀 切換到底部「我的」，保留 Bottom Bar！
                AppStateManager.currentTabNotifier.value = 6;
              }
          ),

          // ── 2. 我的收藏 (主分頁 Index 3) ──
          _buildItem(
              context,
              Icons.bookmark_outline_rounded,
              '我的收藏',
              onTap: () {
                Navigator.pop(context);
                if (isGuest) {
                  _showLoginRequired(context);
                  return;
                }
                // 🚀 切換到底部「收藏」，保留 Bottom Bar！
                AppStateManager.currentTabNotifier.value = 3;
              }
          ),

          // ── 3. 我的發布紀錄 (這不是底部 Tab，必須用 Push！) ──
          _buildItem(
            context,
            Icons.history_rounded,
            '我的發布紀錄',
            onTap: () {
              Navigator.pop(context);
              if (isGuest) {
                _showLoginRequired(context);
                return;
              }
              // 🚀 獨立子頁面，用 Navigator.push 疊上去
              Navigator.push(context, MaterialPageRoute(builder: (_) => const MyPostsScreen()));
            },
          ),

          const Divider(indent: 20, endIndent: 20),

          // ── 4. 系統設定 ──
          _buildItem(
              context,
              Icons.settings_outlined,
              '系統設定',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚙️ 系統設定功能建置中...', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)), backgroundColor: Color(0xFF8BAA88)));
              }
          ),

          // ── 5. 安全登出 ──
          if (!isGuest)
            _buildItem(
                context,
                Icons.logout_rounded,
                '安全登出',
                isLogout: true,
                onTap: () {
                  Navigator.pop(context);
                  _showLogoutConfirmationDialog(context);
                }
            ),

          if (isGuest) ...[
            const Divider(indent: 20, endIndent: 20),
            ListTile(
                leading: const Icon(Icons.login_rounded, color: Color(0xFF8BAA88)),
                title: const Text('登入 / 註冊帳號', style: TextStyle(color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontFamily: 'MyCustomFont')),
                onTap: () {
                  Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const CoverScreen()), (route) => false);
                }
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, IconData icon, String title, {VoidCallback? onTap, bool isLogout = false}) {
    final color = isLogout ? const Color(0xFFA68A6D) : const Color(0xFF7D6E5D);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontFamily: 'MyCustomFont')),
      onTap: onTap ?? () => Navigator.pop(context),
    );
  }

  void _showLoginRequired(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('請先登入才能使用此功能喔！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
            backgroundColor: Color(0xFF7D6E5D)
        )
    );
  }

  void _showLogoutConfirmationDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('確認登出安全系統嗎？', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
        content: const Text('登出後將切換為遊客限制瀏覽模式，您依然可以隨時重新登入同步數據。', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold))
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await FirebaseAuth.instance.signOut();
                await GoogleSignIn().signOut();
                await FacebookAuth.instance.logOut();
              } catch (e) {
                debugPrint('登出錯誤: $e');
              }
              if (!context.mounted) return;

              Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const CoverScreen()), (route) => false);

              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('🔒 已安全登出，目前為訪客瀏覽狀態！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                      backgroundColor: Color(0xFF7D6E5D)
                  )
              );
            },
            child: const Text('確認登出', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFA68A6D), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }
}

// ── 跨頁共用精美 Drawer Header ─────────────────────────────────
class _SharedDrawerHeader extends StatefulWidget {
  final User? user;
  final String displayName;
  final String email;
  const _SharedDrawerHeader({required this.user, required this.displayName, required this.email});
  @override
  State<_SharedDrawerHeader> createState() => _SharedDrawerHeaderState();
}

class _SharedDrawerHeaderState extends State<_SharedDrawerHeader> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _anim = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final isGuest = widget.user == null;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 24, 24, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF8BAA88), Color(0xFF7D9E7B)]),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () { if (!_ctrl.isAnimating) _ctrl.forward(from: 0); },
          child: RotationTransition(turns: _anim,
              child: Container(width: 66, height: 66,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8)]),
                  child: ClipOval(child: UserAvatar(user: widget.user, radius: 33)))),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.displayName, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 20,
              fontWeight: FontWeight.w900, color: Color(0xFF2C1F0E)), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          if (!isGuest) Text(widget.email, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
              color: const Color(0xFF2C1F0E).withOpacity(0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          if (!isGuest)
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.28), borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF2C1F0E)),
                  SizedBox(width: 4),
                  Text('已登入', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFF2C1F0E), fontWeight: FontWeight.bold)),
                ]))
          else
            GestureDetector(
              onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())); },
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(20)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.login_rounded, size: 13, color: Color(0xFF8BAA88)),
                    SizedBox(width: 5),
                    Text('點此登入', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                        color: Color(0xFF8BAA88), fontWeight: FontWeight.w900)),
                  ])),
            ),
        ])),
      ]),
    );
  }
}