import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'app_state.dart' show AppStateManager;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;
import 'home_screen.dart' show buildSmartImage; // ✨ 引入萬用圖片解析器

// ═══════════════════════════════════════════════════════════════
//  景點導覽頁面 ─ 支援 Base64 圖片版
// ═══════════════════════════════════════════════════════════════

class FavoriteManager {
  static Set<String> savedSpotNames = {};

  static Future<void> loadFavorites() async {
    try {
      var snap = await FirebaseFirestore.instance.collection('Favorites').get();
      savedSpotNames = snap.docs.map((d) => d.id).toSet();
    } catch (e) {
      debugPrint('讀取收藏失敗: $e');
    }
  }

  static Future<void> toggleFavorite(String name) async {
    try {
      if (savedSpotNames.contains(name)) {
        savedSpotNames.remove(name);
        await FirebaseFirestore.instance.collection('Favorites').doc(name).delete();
      } else {
        savedSpotNames.add(name);
        await FirebaseFirestore.instance.collection('Favorites').doc(name).set({
          'name': name,
          'savedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('儲存收藏失敗: $e');
    }
  }
}

class AttractionReview {
  final String userName;
  final String text;
  final String date;
  final bool isMe;
  const AttractionReview({required this.userName, required this.text, required this.date, required this.isMe});
}

class QuizQuestion {
  final String q;
  final List<String> options;
  final int correctIndex;
  const QuizQuestion({required this.q, required this.options, required this.correctIndex});
}

class AttractionModel {
  final String name;
  final String shortDesc;
  final String rating;
  final bool hasAI;
  final List<String> tags;
  final List<String> images;
  final String imageBase64;
  final String fullDesc;
  final String infoTime;
  final String infoLoc;
  final String infoTrans;
  final List<AttractionReview> comments;
  final List<QuizQuestion> quizzes;
  final double? lat;
  final double? lon;

  const AttractionModel({
    required this.name,
    required this.shortDesc,
    required this.rating,
    required this.hasAI,
    required this.tags,
    required this.images,
    required this.imageBase64,
    required this.fullDesc,
    required this.infoTime,
    required this.infoLoc,
    required this.infoTrans,
    required this.comments,
    required this.quizzes,
    this.lat,
    this.lon,
  });
}

class AttractionsScreen extends StatefulWidget {
  const AttractionsScreen({super.key});
  @override
  State<AttractionsScreen> createState() => _AttractionsScreenState();
}

class _AttractionsScreenState extends State<AttractionsScreen> {
  int _catIndex = 0;
  final TextEditingController _searchCtrl = TextEditingController();
  late PageController _bannerCtrl;
  Timer? _bannerTimer;
  int _currentBanner = 0;

  Future<List<AttractionModel>>? _spotsFuture;

  final List<(IconData, String)> _cats = [
    (Icons.apps_rounded, '全部'),
    (Icons.account_balance_rounded, '人文景觀'),
    (Icons.forest_rounded, '自然景觀'),
    (Icons.attractions_rounded, '主題景觀'),
    (Icons.child_care_rounded, '親子友善'),
  ];

  List<(String, String, AttractionModel)> _banners = [];

  @override
  void initState() {
    super.initState();
    FavoriteManager.loadFavorites().then((_) {
      if (mounted) setState(() {});
    });

    _spotsFuture = _fetchAttractionsFromFirebase().then((spots) { _loadDynamicBanners(spots); return spots; });

    _bannerCtrl = PageController(initialPage: 0);
    _bannerTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (_bannerCtrl.hasClients && _banners.isNotEmpty) {
        int nextPage = (_currentBanner + 1) % _banners.length;
        _bannerCtrl.animateToPage(nextPage, duration: const Duration(milliseconds: 800), curve: Curves.easeInOutCubic);
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _bannerTimer?.cancel();
    _bannerCtrl.dispose();
    super.dispose();
  }

  void _loadDynamicBanners(List<AttractionModel> spots) {
    if (spots.isEmpty) return;
    final withImages = spots.where((s) => s.images.isNotEmpty || s.imageBase64.isNotEmpty).toList()..shuffle();
    final selected = withImages.take(5).toList();
    if (mounted) setState(() {
      _banners = selected.map((s) => (
      s.name,
      s.shortDesc.isNotEmpty ? s.shortDesc : '探索嘉義之美',
      s,
      )).toList();
    });
  }

  static double? _extractLat(Map<String, dynamic> data) {
    for (final key in ['PositionLat', 'Lat', 'lat', 'latitude', 'Latitude']) {
      final v = data[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return double.tryParse(v.toString());
      }
    }
    final pos = data['Position'];
    if (pos is Map) {
      for (final key in ['PositionLat', 'Lat', 'lat', 'latitude']) {
        final v = pos[key];
        if (v != null && v.toString().trim().isNotEmpty) {
          return double.tryParse(v.toString());
        }
      }
    }
    return null;
  }

  static double? _extractLon(Map<String, dynamic> data) {
    for (final key in ['PositionLon', 'Lon', 'lon', 'longitude', 'Longitude']) {
      final v = data[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return double.tryParse(v.toString());
      }
    }
    final pos = data['Position'];
    if (pos is Map) {
      for (final key in ['PositionLon', 'Lon', 'lon', 'longitude']) {
        final v = pos[key];
        if (v != null && v.toString().trim().isNotEmpty) {
          return double.tryParse(v.toString());
        }
      }
    }
    return null;
  }

  Future<List<AttractionModel>> _fetchAttractionsFromFirebase() async {
    try {
      QuerySnapshot snapshot;
      try {
        snapshot = await FirebaseFirestore.instance.collection('Atrractions').get();
        if (snapshot.docs.isEmpty) {
          snapshot = await FirebaseFirestore.instance.collection('Attractions').get();
        }
      } catch (e) {
        throw Exception("Firebase 連線錯誤: $e");
      }

      List<AttractionModel> parsedSpots = [];
      Set<String> seenNames = {};

      for (var doc in snapshot.docs) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        String name = data['AttractionName'] ?? '未命名景點';

        if (seenNames.contains(name)) continue;

        String base64 = data['ImageBase64']?.toString() ?? '';

        List<String> imageUrls = [];
        if (data['Images'] is List) {
          for (var img in data['Images']) {
            if (img is Map && img['url'] != null) {
              String url = img['url'].toString();
              if (url.startsWith('http')) {
                imageUrls.add(url);
              }
            }
          }
        }

        if (imageUrls.isEmpty && base64.isEmpty) continue;

        seenNames.add(name);

        List<String> tags = [];
        if (data['Tags'] is List) {
          for (var t in data['Tags']) {
            if (t.toString().trim().isNotEmpty && t.toString() != '沒有') {
              tags.add(t.toString().startsWith('#') ? t.toString() : '#${t.toString()}');
              if (tags.length >= 3) break;
            }
          }
        }
        if (tags.isEmpty && data['AttractionClasses'] is List) {
          for (var c in data['AttractionClasses']) {
            tags.add('#$c');
            if (tags.length >= 3) break;
          }
        }

        List<AttractionReview> comments = [];
        String commentStr = data['Comment'] ?? '';
        if (commentStr.isNotEmpty && commentStr != '沒有') {
          List<String> splits = commentStr.split('\n---\n');
          for (var s in splits) {
            if (s.trim().isNotEmpty) comments.add(AttractionReview(userName: 'Google 網友', text: s.trim(), date: '近期', isMe: false));
          }
        }

        String desc = data['Description'] ?? '';
        if (desc == '沒有') desc = '';
        String shortDesc = desc.length > 40 ? '${desc.substring(0, 40)}...' : desc;
        String ratingStr = data['Star_rating']?.toString() ?? '';
        if (ratingStr == '0' || ratingStr == '0.0' || ratingStr == '0.00' || ratingStr.trim().isEmpty) ratingStr = '';
        final ratingNum = double.tryParse(ratingStr);
        if (ratingNum != null && ratingNum <= 0) ratingStr = '';
        String address = data['Address'] ?? '';
        if (address == '沒有') address = '';
        String timeInfo = data['ServiceTimeInfo'] ?? '';
        if (timeInfo == '沒有' || timeInfo.isEmpty) timeInfo = '依現場公告為主';
        String transInfo = data['TrafficInfo'] ?? '';
        if (transInfo == '沒有' || transInfo.isEmpty) transInfo = '建議自行開車或搭乘大眾運輸工具';

        parsedSpots.add(AttractionModel(
          name: name,
          shortDesc: shortDesc,
          rating: ratingStr,
          hasAI: desc.length > 50,
          tags: tags,
          images: imageUrls,
          imageBase64: base64,
          fullDesc: desc,
          infoTime: timeInfo,
          infoLoc: address,
          infoTrans: transInfo,
          comments: comments,
          lat: _extractLat(data),
          lon: _extractLon(data),
          quizzes: const [],
        ));
      }
      return parsedSpots;
    } catch (e) {
      return Future.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 280.0,
              pinned: true,
              backgroundColor: const Color(0xFFF9F8F4),
              leading: IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF7D6E5D)),
                ),
                onPressed: () => Navigator.pop(context),
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    PageView.builder(
                      controller: _bannerCtrl,
                      onPageChanged: (i) => setState(() => _currentBanner = i),
                      itemCount: _banners.isEmpty ? 1 : _banners.length,
                      itemBuilder: (context, index) {
                        if (_banners.isEmpty) return Container(color: const Color(0xFF8BAA88).withOpacity(0.15), child: const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2)));
                        final spot = _banners[index].$3;
                        return GestureDetector(
                          onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => AttractionDetailScreen(spotData: spot))); },
                          child: buildSmartImage(
                            imageUrl: spot.images.isNotEmpty ? spot.images.first : null,
                            imageBase64: spot.imageBase64,
                            fit: BoxFit.cover,
                          ),
                        );
                      },
                    ),
                    Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black45, Color(0xFFF9F8F4)],
                          stops: [0.0, 0.75, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 30, left: 24, right: 80,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(6)),
                            child: const Text('本月主打', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 8),
                          Text(_banners.isEmpty ? '' : _banners[_currentBanner].$1, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.0, height: 1.3), maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text(_banners.isEmpty ? '' : _banners[_currentBanner].$2, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 16, right: 24,
                      child: Row(
                        children: List.generate(_banners.isEmpty ? 0 : _banners.length, (i) => AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          margin: const EdgeInsets.only(left: 4),
                          width: _currentBanner == i ? 18 : 6, height: 6,
                          decoration: BoxDecoration(color: _currentBanner == i ? const Color(0xFF8BAA88) : Colors.white.withOpacity(0.5), borderRadius: BorderRadius.circular(3)),
                        )),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
                            Text('SPOTS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(25),
                            border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 3))],
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 16),
                              const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _searchCtrl,
                                  onChanged: (value) => setState(() {}),
                                  decoration: const InputDecoration(
                                    hintText: '搜尋你想去的景點...',
                                    border: InputBorder.none,
                                    hintStyle: TextStyle(color: Color(0xFF9E9182), fontSize: 14),
                                  ),
                                ),
                              ),
                              if (_searchCtrl.text.isNotEmpty)
                                IconButton(
                                  icon: const Icon(Icons.cancel_rounded, color: Colors.grey, size: 18),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() {});
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  _buildCategoryIcons(),
                  _buildSpotList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryIcons() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: List.generate(_cats.length, (i) {
            final sel = i == _catIndex;
            return GestureDetector(
              onTap: () => setState(() => _catIndex = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 58, height: 58,
                      decoration: BoxDecoration(
                        color: sel ? const Color(0xFF8BAA88) : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: sel ? Colors.transparent : const Color(0xFF8BAA88).withOpacity(0.2)),
                        boxShadow: [if (sel) BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
                      ),
                      child: Icon(_cats[i].$1, color: sel ? Colors.white : const Color(0xFF8BAA88), size: 26),
                    ),
                    const SizedBox(height: 8),
                    Text(_cats[i].$2, style: TextStyle(fontSize: 12, fontWeight: sel ? FontWeight.bold : FontWeight.w600, color: sel ? const Color(0xFF7D6E5D) : const Color(0xFF9E9182))),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildSpotList() {
    return FutureBuilder<List<AttractionModel>>(
      future: _spotsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88))));
        }
        if (snapshot.hasError) {
          return Center(child: Text(snapshot.error.toString(), style: const TextStyle(color: Colors.red)));
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('目前沒有景點資料', style: TextStyle(color: Colors.grey)));
        }

        List<AttractionModel> allSpots = snapshot.data!;
        String query = _searchCtrl.text.trim().toLowerCase();
        String selectedCategory = _cats[_catIndex].$2;

        List<AttractionModel> filteredSpots = allSpots.where((spot) {
          bool matchSearch = query.isEmpty ||
              spot.name.toLowerCase().contains(query) ||
              spot.shortDesc.toLowerCase().contains(query);
          bool matchCategory = _catIndex == 0 || spot.tags.any((tag) => tag.contains(selectedCategory));
          return matchSearch && matchCategory;
        }).toList();

        if (filteredSpots.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: Text('找不到符合條件的景點 😢', style: TextStyle(color: Colors.grey, fontSize: 16))),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Column(
            children: filteredSpots.asMap().entries.map((entry) {
              return _AttractionCard(
                spot: entry.value,
                index: entry.key,
                onReturn: () => setState((){}),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

class NavTarget {
  static String? pendingName;
  static double? pendingLat;
  static double? pendingLon;

  static void navigate(BuildContext context, String spotName, double lat, double lon) {
    pendingName = spotName;
    pendingLat = lat;
    pendingLon = lon;
    AppStateManager.currentTabNotifier.value = 1;
  }
}

class _AttractionCard extends StatefulWidget {
  final AttractionModel spot;
  final int index;
  final VoidCallback onReturn;

  const _AttractionCard({required this.spot, required this.index, required this.onReturn});

  @override
  State<_AttractionCard> createState() => _AttractionCardState();
}

class _AttractionCardState extends State<_AttractionCard> {
  final Map<String, Color> tagColors = {
    '#HOT': const Color(0xFFE57373), '#奇聞軼事': const Color(0xFFFBC02D), '#自然生態': const Color(0xFF8BC34A),
    '#藝文青': const Color(0xFF03A9F4), '#室內景點': const Color(0xFFFF9800), '#歷史古蹟': const Color(0xFF7D6E5D), '#在地信仰': const Color(0xFF9C27B0),
  };
  Color _getTagColor(String tag) => tagColors[tag] ?? const Color(0xFF8BAA88);

  void _toggleFavorite() async {
    await FavoriteManager.toggleFavorite(widget.spot.name);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedSpotNames.contains(widget.spot.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isFav ? '❤️ 已將 ${widget.spot.name} 儲存至雲端！' : '🗑️ 已從雲端移除 ${widget.spot.name} 的收藏'),
        backgroundColor: isFav ? const Color(0xFFE57373) : const Color(0xFF9E9182),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isFavorite = FavoriteManager.savedSpotNames.contains(widget.spot.name);

    return RepaintBoundary(child: GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (context) => AttractionDetailScreen(spotData: widget.spot))).then((_) => widget.onReturn());
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 15, offset: const Offset(0, 5))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Stack(
                children: [
                  buildSmartImage(
                    imageUrl: widget.spot.images.isNotEmpty ? widget.spot.images[0] : null,
                    imageBase64: widget.spot.imageBase64,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                  Positioned(
                    top: 0, left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: widget.index == 0 ? const Color(0xFFE57373) : const Color(0xFF8BAA88),
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(2, 2))],
                      ),
                      child: Text('TOP ${widget.index + 1}', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(widget.spot.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      GestureDetector(
                        onTap: _toggleFavorite,
                        child: Icon(
                          isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: isFavorite ? const Color(0xFFE57373) : const Color(0xFF8BAA88),
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                  if (widget.spot.shortDesc.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(widget.spot.shortDesc, style: TextStyle(fontSize: 13, color: const Color(0xFF7D6E5D).withOpacity(0.8)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.spot.hasAI) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: const Color(0xFFA5CBD4).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_on_rounded, size: 10, color: Color(0xFF6B9EA8)),
                              SizedBox(width: 3),
                              Text('#AI導覽', style: TextStyle(color: Color(0xFF6B9EA8), fontSize: 10, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                      ...widget.spot.tags.map((tag) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: _getTagColor(tag).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                        child: Text(tag, style: TextStyle(color: _getTagColor(tag), fontSize: 10, fontWeight: FontWeight.bold)),
                      )).toList(),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }
}

// ═══════════════════════════════════════════════════════════════
//  景點詳情頁面
// ═══════════════════════════════════════════════════════════════
class AttractionDetailScreen extends StatefulWidget {
  final AttractionModel spotData;
  const AttractionDetailScreen({super.key, required this.spotData});

  @override
  State<AttractionDetailScreen> createState() => _AttractionDetailScreenState();
}

class _AttractionDetailScreenState extends State<AttractionDetailScreen> {
  int _currentImageIdx = 0;
  final TextEditingController _commentCtrl = TextEditingController();
  bool _hasPassedQuiz = false;
  bool _isPosting = false;
  double? _distanceMeters;
  bool get _isNearby => _distanceMeters != null && _distanceMeters! <= 100;
  bool _ttsPlaying = false;
  bool _ttsPaused = false;
  double _ttsSpeed = 1.0;
  static final _ttsChannel = const MethodChannel('com.alibuda/tts');

  // ★ Firestore 路徑：Attractions/{docId}/comments
  CollectionReference get _commentsRef => FirebaseFirestore.instance
      .collection('Attractions')
      .doc(widget.spotData.name.hashCode.abs().toString())
      .collection('comments');

  final Map<String, Color> tagColors = {
    '#HOT': const Color(0xFFE57373), '#奇聞軼事': const Color(0xFFFBC02D), '#自然生態': const Color(0xFF8BC34A),
    '#藝文青': const Color(0xFF03A9F4), '#室內景點': const Color(0xFFFF9800), '#歷史古蹟': const Color(0xFF7D6E5D), '#在地信仰': const Color(0xFF9C27B0),
  };

  Color _getTagColor(String tag) => tagColors[tag] ?? const Color(0xFF8BAA88);

  @override
  void initState() {
    super.initState();
    _checkQuizPassed();
    _checkDistance();
  }

  @override
  void dispose() {
    _stopTts();
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkQuizPassed() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('stamps').doc(widget.spotData.name).get();
      if (doc.exists && mounted) setState(() => _hasPassedQuiz = true);
    } catch (_) {}
  }

  Future<void> _checkDistance() async {
    if (widget.spotData.lat == null || widget.spotData.lon == null) return;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      final dist = Geolocator.distanceBetween(pos.latitude, pos.longitude, widget.spotData.lat!, widget.spotData.lon!);
      if (mounted) setState(() => _distanceMeters = dist);
    } catch (_) {}
  }

  // ── 取得登入使用者頭像 Base64 ──────────────────────────────
  Future<String?> _getMyAvatarBase64() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return doc.data()?['avatarBase64']?.toString();
    } catch (_) { return null; }
  }

  // ── 發送留言 ─────────────────────────────────────────────────
  Future<void> _postComment() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('請先登入才能留言 😊', style: TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: Color(0xFF9E9182),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _isPosting) return;

    setState(() => _isPosting = true);
    FocusScope.of(context).unfocus();

    try {
      final avatarBase64 = await _getMyAvatarBase64();
      await _commentsRef.add({
        'uid':          user.uid,
        'userName':     user.displayName ?? '匿名旅人',
        'text':         text,
        'avatarBase64': avatarBase64 ?? '',
        'createdAt':    FieldValue.serverTimestamp(),
      });
      _commentCtrl.clear();
      if (mounted) setState(() => _isPosting = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isPosting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('留言失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: const Color(0xFFB07070),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  // ── 刪除留言 ─────────────────────────────────────────────────
  Future<void> _deleteComment(String docId) async {
    try {
      await _commentsRef.doc(docId).delete();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('刪除失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: const Color(0xFFB07070),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _startTts() async {
    final text = '${widget.spotData.name}。${widget.spotData.fullDesc}';
    try {
      await _ttsChannel.invokeMethod('speak', {'text': text, 'rate': _ttsSpeed});
      if (mounted) setState(() { _ttsPlaying = true; _ttsPaused = false; });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('請確保裝置已安裝 Google 語音合成引擎', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF9E7B6B), behavior: SnackBarBehavior.floating));
    }
  }
  Future<void> _pauseTts() async { try { await _ttsChannel.invokeMethod('stop'); } catch (_) {} if (mounted) setState(() => _ttsPaused = true); }
  Future<void> _resumeTts() async { if (mounted) setState(() => _ttsPaused = false); await _startTts(); }
  Future<void> _stopTts() async { try { await _ttsChannel.invokeMethod('stop'); } catch (_) {} if (mounted) setState(() { _ttsPlaying = false; _ttsPaused = false; }); }

  void _startQuizChallenge() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
        content: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF8BAA88)),
              SizedBox(height: 16),
              Text('AI 正在為您生成專屬題目...', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );

    try {
      final quizzes = await _generateAiQuizzes();
      if (!mounted) return;
      Navigator.pop(context);
      if (quizzes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('題目生成失敗，請稍後再試 🙏', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF9E7B6B), behavior: SnackBarBehavior.floating));
        return;
      }
      showDialog(context: context, barrierDismissible: false, builder: (context) => _QuizGameWizard(spotName: widget.spotData.name, quizzes: quizzes)).then((_) => _checkQuizPassed());
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('題目生成失敗，請確認網路連線 🙏', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF9E7B6B), behavior: SnackBarBehavior.floating));
    }
  }

  Future<List<QuizQuestion>> _generateAiQuizzes() async {
    const apiKey = 'YOUR_GEMINI_API_KEY';
    const baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent';
    final spotName = widget.spotData.name;
    final spotDesc = widget.spotData.fullDesc.isNotEmpty ? widget.spotData.fullDesc : '這是嘉義著名景點 $spotName。';
    final prompt = '''
你是嘉義旅遊知識出題機器人。請根據以下景點資訊，出 3 道選擇題測驗。
景點名稱：$spotName
景點介紹：${spotDesc.length > 400 ? spotDesc.substring(0, 400) : spotDesc}
要求：
- 每題 1 個題幹 (q)，2 個選項 (options)，1 個正確答案索引 (correctIndex，0 或 1)
- 題目要跟景點特色、歷史、文化或地理位置有關，有教育意義
- 選項清楚易懂，1 個正確 1 個明顯錯誤
- 題幹前面不要加題號
- 使用繁體中文
請只回傳以下格式的 JSON，不要加任何說明文字：
[
  {"q":"題幹1","options":["選項A","選項B"],"correctIndex":0},
  {"q":"題幹2","options":["選項A","選項B"],"correctIndex":1},
  {"q":"題幹3","options":["選項A","選項B"],"correctIndex":0}
]
''';
    final body = jsonEncode({'contents': [{'role': 'user', 'parts': [{'text': prompt}]}], 'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 800}});
    final response = await http.post(Uri.parse('$baseUrl?key=$apiKey'), headers: {'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return [];
    final data = jsonDecode(response.body);
    String text = data['candidates'][0]['content']['parts'][0]['text'] as String;
    final jsonStart = text.indexOf('[');
    final jsonEnd = text.lastIndexOf(']');
    if (jsonStart < 0 || jsonEnd < 0) return [];
    text = text.substring(jsonStart, jsonEnd + 1);
    final List<dynamic> parsed = jsonDecode(text);
    return parsed.map((item) {
      final map = item as Map<String, dynamic>;
      final options = (map['options'] as List<dynamic>).map((o) => o.toString()).toList();
      return QuizQuestion(q: map['q'].toString(), options: options, correctIndex: (map['correctIndex'] as num).toInt());
    }).toList();
  }

  void _toggleFavorite() async {
    await FavoriteManager.toggleFavorite(widget.spotData.name);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedSpotNames.contains(widget.spotData.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isFav ? '❤️ 已將 ${widget.spotData.name} 儲存至雲端收藏！' : '已取消收藏'),
        backgroundColor: isFav ? const Color(0xFFE57373) : Colors.grey,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  void _launchNavigation() {
    final lat = widget.spotData.lat;
    final lon = widget.spotData.lon;
    if (lat == null || lon == null) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    NavTarget.navigate(context, widget.spotData.name, lat, lon);
  }

  Widget _buildVoiceSection() {
    if (_ttsPlaying) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.08), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.graphic_eq_rounded, color: Color(0xFF8BAA88), size: 14),
            const SizedBox(width: 6),
            Text(_ttsPaused ? '已暫停' : '播放中…', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('速度：', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
            ...[0.5, 1.0, 1.5].map((s) => GestureDetector(
              onTap: () async { setState(() => _ttsSpeed = s); await _stopTts(); _startTts(); },
              child: Container(margin: const EdgeInsets.symmetric(horizontal: 3), padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: _ttsSpeed == s ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                  child: Text('${s}x', style: TextStyle(fontFamily: 'MyCustomFont', color: _ttsSpeed == s ? Colors.white : const Color(0xFF8BAA88), fontSize: 10, fontWeight: FontWeight.bold))),
            )),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _ttsBtnSmall(_ttsPaused ? '繼續' : '暫停', _ttsPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, _ttsPaused ? _resumeTts : _pauseTts, const Color(0xFF8BAA88)),
            _ttsBtnSmall('取消', Icons.stop_rounded, _stopTts, const Color(0xFF9E7B6B)),
          ]),
        ]),
      );
    }

    final canUse = _isNearby || _distanceMeters == null;
    String distLabel = _distanceMeters == null ? '定位中…'
        : _isNearby ? '您已在景點附近 ✓'
        : _distanceMeters!.isInfinite ? '無法取得座標'
        : _distanceMeters! > 1000 ? '距離 ${(_distanceMeters! / 1000).toStringAsFixed(1)} 公里' : '距離 ${_distanceMeters!.round()} 公尺';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_distanceMeters != null)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.location_on_rounded, size: 12, color: _isNearby ? const Color(0xFF8BAA88) : const Color(0xFF9E9182)),
          const SizedBox(width: 3),
          Text(distLabel, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _isNearby ? const Color(0xFF8BAA88) : const Color(0xFF9E9182), fontWeight: FontWeight.bold)),
        ])),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: canUse ? () => _showSpeedSelector() : null,
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), backgroundColor: canUse ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.4), elevation: canUse ? 4 : 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(canUse ? Icons.record_voice_over_rounded : Icons.headphones_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(canUse ? 'AI 語音導覽' : '尚未抵達景點', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        ]),
      )),
    ]);
  }

  Widget _ttsBtnSmall(String label, IconData icon, VoidCallback onTap, Color color) =>
      GestureDetector(onTap: onTap, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: color), const SizedBox(width: 4), Text(label, style: TextStyle(fontFamily: 'MyCustomFont', color: color, fontWeight: FontWeight.bold, fontSize: 12))]),
      ));

  void _showSpeedSelector() {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          const Text('語音解說速度', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          const SizedBox(height: 4),
          const Text('選擇適合你的聆聽速度', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            ...[
              (0.5, '慢速', '0.5x', Icons.snooze_rounded),
              (1.0, '正常', '1.0x', Icons.speed_rounded),
              (1.5, '快速', '1.5x', Icons.fast_forward_rounded),
            ].map((s) => GestureDetector(
              onTap: () { setState(() => _ttsSpeed = s.$1); Navigator.pop(ctx); _startTts(); },
              child: Container(width: 85, padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(color: _ttsSpeed == s.$1 ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.08), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
                  child: Column(children: [
                    Icon(s.$4, color: _ttsSpeed == s.$1 ? Colors.white : const Color(0xFF8BAA88), size: 24),
                    const SizedBox(height: 6),
                    Text(s.$2, style: TextStyle(fontFamily: 'MyCustomFont', color: _ttsSpeed == s.$1 ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 13)),
                    Text(s.$3, style: TextStyle(fontFamily: 'MyCustomFont', color: _ttsSpeed == s.$1 ? Colors.white70 : Colors.grey, fontSize: 11)),
                  ])),
            )),
          ]),
          const SizedBox(height: 16),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
        ]),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: const Color(0xFF8BAA88), size: 20),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, height: 1.5, fontWeight: FontWeight.bold))),
    ]);
  }

  // ── 輸入框頭像（讀 Firestore avatarBase64） ──────────────────
  Widget _buildMyAvatar(User user) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final avatarB64 = (data is Map) ? (data as Map<String, dynamic>)['avatarBase64']?.toString() ?? '' : '';
        if (avatarB64.isNotEmpty) {
          try {
            final bytes = base64Decode(avatarB64);
            return CircleAvatar(radius: 16, backgroundImage: MemoryImage(bytes));
          } catch (_) {}
        }
        final initial = (user.displayName?.isNotEmpty == true)
            ? user.displayName![0].toUpperCase()
            : (user.email?.isNotEmpty == true ? user.email![0].toUpperCase() : '?');
        return CircleAvatar(radius: 16, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
            child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 12)));
      },
    );
  }

  // ── 留言列表頭像（從 Firestore doc avatarBase64 讀取） ────────
  Widget _buildCommentAvatar(String avatarB64, String userName) {
    if (avatarB64.isNotEmpty) {
      try {
        final bytes = base64Decode(avatarB64);
        return CircleAvatar(radius: 18, backgroundImage: MemoryImage(bytes));
      } catch (_) {}
    }
    final initial = userName.isNotEmpty ? userName[0].toUpperCase() : '?';
    return CircleAvatar(radius: 18, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
        child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 13)));
  }

  @override
  Widget build(BuildContext context) {
    bool isFavorite = FavoriteManager.savedSpotNames.contains(widget.spotData.name);
    int imgCount = widget.spotData.images.isNotEmpty ? widget.spotData.images.length : 1;
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                expandedHeight: 400.0,
                pinned: true,
                backgroundColor: const Color(0xFFF9F8F4),
                leading: IconButton(
                  icon: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), shape: BoxShape.circle), child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF7D6E5D))),
                  onPressed: () => Navigator.pop(context),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(color: isFavorite ? Colors.white : Colors.white.withOpacity(0.15), shape: BoxShape.circle, border: Border.all(color: isFavorite ? const Color(0xFFE57373) : Colors.white.withOpacity(0.4), width: 1.5)),
                      child: IconButton(padding: EdgeInsets.zero, icon: Icon(isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 24, color: isFavorite ? const Color(0xFFE57373) : Colors.white), onPressed: _toggleFavorite),
                    )),
                  ),
                  const SizedBox(width: 8),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(fit: StackFit.expand, children: [
                    PageView.builder(
                      onPageChanged: (i) => setState(() => _currentImageIdx = i),
                      itemCount: imgCount,
                      itemBuilder: (context, index) => buildSmartImage(
                        imageUrl: widget.spotData.images.isNotEmpty ? widget.spotData.images[index] : null,
                        imageBase64: widget.spotData.imageBase64,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.transparent, Color(0xCCF9F8F4), Color(0xFFF9F8F4)], stops: [0.0, 0.5, 0.85, 1.0]))),
                    if (imgCount > 1)
                      Positioned(bottom: 30, left: 0, right: 0, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(imgCount, (i) => AnimatedContainer(duration: const Duration(milliseconds: 300), margin: const EdgeInsets.symmetric(horizontal: 4), width: _currentImageIdx == i ? 18 : 6, height: 6, decoration: BoxDecoration(color: _currentImageIdx == i ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.3), borderRadius: BorderRadius.circular(3)))))),
                  ]),
                ),
              ),

              SliverToBoxAdapter(
                child: Container(
                  color: const Color(0xFFF9F8F4),
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Text(widget.spotData.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 2, overflow: TextOverflow.ellipsis)),
                        if (widget.spotData.rating.isNotEmpty) ...[
                          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                            child: Row(children: [const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 18), const SizedBox(width: 4), Text(widget.spotData.rating, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF7D6E5D)))]),
                          ),
                        ],
                      ]),

                      if (widget.spotData.shortDesc.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(widget.spotData.shortDesc, style: const TextStyle(fontSize: 14, color: Color(0xFF9E9182), height: 1.5), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: 16),

                      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        if (widget.spotData.hasAI)
                          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(8)),
                              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.location_on_rounded, size: 12, color: Colors.white), SizedBox(width: 4), Text('# AI 導覽', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))])),
                        ...widget.spotData.tags.map((tag) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: _getTagColor(tag).withOpacity(0.15), borderRadius: BorderRadius.circular(8)), child: Text(tag, style: TextStyle(fontFamily: 'MyCustomFont', color: _getTagColor(tag), fontSize: 11, fontWeight: FontWeight.bold)))).toList(),
                      ]),

                      const SizedBox(height: 24),
                      // 知識打卡
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3), width: 1.5), boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))]),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle), child: const Icon(Icons.workspace_premium_rounded, color: Color(0xFF8BAA88), size: 28)),
                          const SizedBox(width: 14),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('景點知識打卡集章 🏆', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                            const SizedBox(height: 4),
                            Text(_hasPassedQuiz ? '已完成打卡 ✓' : (_isNearby ? '回答3題問答解鎖專屬電子印章！' : '抵達景點後才可挑戰'), style: TextStyle(fontSize: 11, color: const Color(0xFF7D6E5D).withOpacity(0.7), fontWeight: FontWeight.bold)),
                          ])),
                          ElevatedButton(
                            onPressed: (_hasPassedQuiz || (!_isNearby && _distanceMeters != null)) ? null : _startQuizChallenge,
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                            child: const Text('開始挑戰', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          )
                        ]),
                      ),

                      const SizedBox(height: 24),
                      Container(height: 1.5, width: double.infinity, color: const Color(0xFF8BAA88).withOpacity(0.2)),
                      const SizedBox(height: 24),

                      if (widget.spotData.fullDesc.isNotEmpty) ...[
                        const Text('關於這裡', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                        const SizedBox(height: 12),
                        Text(widget.spotData.fullDesc, style: const TextStyle(fontSize: 15, color: Color(0xFF4A4036), height: 1.8)),
                        const SizedBox(height: 32),
                      ],

                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]),
                        child: Column(children: [
                          if (widget.spotData.infoLoc.isNotEmpty) ...[_buildInfoRow(Icons.location_on_rounded, widget.spotData.infoLoc), const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1, color: Color(0xFFF1F4EE)))],
                          _buildInfoRow(Icons.access_time_rounded, widget.spotData.infoTime),
                          const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1, color: Color(0xFFF1F4EE))),
                          _buildInfoRow(Icons.directions_car_rounded, widget.spotData.infoTrans),
                        ]),
                      ),

                      const SizedBox(height: 40),

                      // ── 網友留言 ──────────────────────────────────────────
                      const Text('網友留言', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 16),

                      // 輸入框
                      if (user == null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.06), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2))),
                          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(Icons.lock_outline_rounded, color: Color(0xFF8BAA88), size: 18),
                            SizedBox(width: 8),
                            Text('請先登入才能留言', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 14)),
                          ]),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
                          child: Row(children: [
                            _buildMyAvatar(user),
                            const SizedBox(width: 12),
                            Expanded(child: TextField(controller: _commentCtrl, decoration: const InputDecoration(hintText: '說點什麼吧...', border: InputBorder.none, hintStyle: TextStyle(color: Color(0xFF9E9182), fontSize: 14)))),
                            _isPosting
                                ? const SizedBox(width: 32, height: 32, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8BAA88))))
                                : GestureDetector(onTap: _postComment, child: Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Color(0xFF8BAA88), shape: BoxShape.circle), child: const Icon(Icons.send_rounded, color: Colors.white, size: 14))),
                          ]),
                        ),

                      const SizedBox(height: 24),

                      // ★ StreamBuilder 留言列表
                      StreamBuilder<QuerySnapshot>(
                        stream: _commentsRef.orderBy('createdAt', descending: true).snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 20), child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2)));
                          }
                          if (snapshot.hasError) {
                            return Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Center(child: Text('載入留言失敗', style: TextStyle(color: Colors.grey[400], fontFamily: 'MyCustomFont'))));
                          }
                          final docs = snapshot.data?.docs ?? [];
                          if (docs.isEmpty) {
                            return const Center(child: Text('還沒有人留言喔，來搶頭香吧！', style: TextStyle(color: Color(0xFF9E9182), fontSize: 14)));
                          }
                          return Column(children: docs.map((doc) {
                            final data = doc.data() as Map<String, dynamic>;
                            final uid       = data['uid']?.toString() ?? '';
                            final userName  = data['userName']?.toString() ?? '匿名旅人';
                            final text      = data['text']?.toString() ?? '';
                            final avatarB64 = data['avatarBase64']?.toString() ?? '';
                            final isMe      = uid.isNotEmpty && uid == myUid;

                            String dateLabel = '';
                            final ts = data['createdAt'];
                            if (ts is Timestamp) {
                              final dt = ts.toDate();
                              final diff = DateTime.now().difference(dt);
                              if (diff.inMinutes < 1) dateLabel = '剛剛';
                              else if (diff.inHours < 1) dateLabel = '${diff.inMinutes} 分鐘前';
                              else if (diff.inDays < 1) dateLabel = '${diff.inHours} 小時前';
                              else dateLabel = '${dt.year}/${dt.month}/${dt.day}';
                            }

                            return Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                _buildCommentAvatar(avatarB64, userName),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(userName, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), fontSize: 13)),
                                    const Spacer(),
                                    Text(dateLabel, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 11)),
                                    if (isMe) ...[
                                      const SizedBox(width: 8),
                                      GestureDetector(onTap: () => _deleteComment(doc.id), child: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE57373), size: 16)),
                                    ],
                                  ]),
                                  const SizedBox(height: 4),
                                  Text(text, style: const TextStyle(color: Color(0xFF4A4036), fontSize: 14, height: 1.4)),
                                  const SizedBox(height: 12),
                                  Container(height: 1, color: const Color(0xFF8BAA88).withOpacity(0.1)),
                                ])),
                              ]),
                            );
                          }).toList());
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.98), borderRadius: const BorderRadius.vertical(top: Radius.circular(32)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, -5))]),
              child: Row(children: [
                if (widget.spotData.lat != null && widget.spotData.lon != null) ...[
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88), width: 1.5), boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))]),
                    child: IconButton(icon: const Icon(Icons.navigation_rounded, color: Color(0xFF8BAA88), size: 24), tooltip: '導航前往', onPressed: _launchNavigation),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(child: _buildVoiceSection()),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuizGameWizard extends StatefulWidget {
  final String spotName;
  final List<QuizQuestion> quizzes;
  const _QuizGameWizard({required this.spotName, required this.quizzes});

  @override
  State<_QuizGameWizard> createState() => _QuizGameWizardState();
}

class _QuizGameWizardState extends State<_QuizGameWizard> with TickerProviderStateMixin {
  int _currentIndex = 0;
  bool _showSuccessStamp = false;
  bool _showFailureOverlay = false;

  late AnimationController _stampController;
  late Animation<double> _stampScaleAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _stampController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _stampScaleAnimation = Tween<double>(begin: 3.5, end: 1.0).animate(CurvedAnimation(parent: _stampController, curve: Curves.bounceOut));
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _shakeAnimation = Tween<double>(begin: 0.0, end: 15.0).animate(CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn));
  }

  @override
  void dispose() {
    _stampController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _handleAnswer(int selectedIdx) {
    if (selectedIdx == widget.quizzes[_currentIndex].correctIndex) {
      if (_currentIndex < widget.quizzes.length - 1) {
        setState(() { _currentIndex++; });
      } else {
        setState(() { _showSuccessStamp = true; });
        _stampController.forward();
      }
    } else {
      setState(() { _showFailureOverlay = true; });
      _shakeController.forward().then((_) => _shakeController.reverse());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showSuccessStamp) return _buildSuccessStampUI();
    if (_showFailureOverlay) return _buildFailureUI();

    if (widget.quizzes.isEmpty) {
      return AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('暫無題目', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
        content: const Text('此景點目前尚未設置題目，請稍後再試。', style: TextStyle(fontFamily: 'MyCustomFont')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('關閉', style: TextStyle(color: Color(0xFF8BAA88))))],
      );
    }
    final q = widget.quizzes[_currentIndex];
    return AlertDialog(
      backgroundColor: const Color(0xFFFDFCF5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('知識打卡問答', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), fontSize: 16)),
          Text('${_currentIndex + 1}/3', style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), fontSize: 14)),
        ]),
        const SizedBox(height: 6),
        Text(widget.spotName, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Container(height: 1.5, width: double.infinity, color: const Color(0xFF8BAA88).withOpacity(0.15)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(q.q, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), height: 1.5)),
        const SizedBox(height: 20),
        ...q.options.asMap().entries.map((opt) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _handleAnswer(opt.key),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16), side: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), backgroundColor: Colors.white),
            child: Align(alignment: Alignment.centerLeft, child: Text(opt.value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold))),
          ),
        )).toList(),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('放棄挑戰', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold)))],
    );
  }

  Widget _buildSuccessStampUI() {
    return ScaleTransition(
      scale: _stampScaleAnimation,
      child: AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32), side: const BorderSide(color: Color(0xFF8BAA88), width: 2)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle), child: const Icon(Icons.verified_rounded, color: Color(0xFF8BAA88), size: 64)),
          const SizedBox(height: 24),
          const Text('恭喜完成知識打卡！🎉', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          const SizedBox(height: 8),
          Text('您已成功點亮 [${widget.spotName}] 專屬足跡電子印章！進度已同步至個人中心。', style: TextStyle(fontSize: 12, color: const Color(0xFF7D6E5D).withOpacity(0.8), height: 1.4), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: () async {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) {
                try {
                  await FirebaseFirestore.instance.collection('users').doc(uid).collection('stamps').doc(widget.spotName).set({'unlockedAt': FieldValue.serverTimestamp(), 'spotName': widget.spotName}, SetOptions(merge: true));
                } catch (e) { debugPrint('印章儲存失敗: $e'); }
              }
              if (context.mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), padding: const EdgeInsets.symmetric(vertical: 12)),
            child: const Text('收下印章', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
          ))
        ]),
      ),
    );
  }

  Widget _buildFailureUI() {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) => Transform.translate(offset: Offset(math.sin(_shakeController.value * math.pi * 4) * 8, 0), child: child),
      child: AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF7D6E5D).withOpacity(0.08), shape: BoxShape.circle), child: const Icon(Icons.heart_broken_rounded, color: Color(0xFF7D6E5D), size: 54)),
          const SizedBox(height: 20),
          const Text('挑戰失敗 😢', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          const SizedBox(height: 8),
          const Text('可惜答錯囉！別氣餒，再仔細閱讀一次景點詳情描述，隨時可以重新開始挑戰！', style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.4), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: OutlinedButton(
            onPressed: () { Navigator.pop(context); },
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF7D6E5D), width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), padding: const EdgeInsets.symmetric(vertical: 12)),
            child: const Text('返回景點介紹', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
          ))
        ]),
      ),
    );
  }
}