import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

// ═══════════════════════════════════════════════════════════════
//  美食推薦頁面 ─ 主畫面餐期雙翻牌 + 雷達波紋即時營業 AI 篩選終極版
// ═══════════════════════════════════════════════════════════════

class FavoriteManager {
  static Set<String> savedNames = {};

  static CollectionReference? _getUserFavorites() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(user.uid).collection('Favorites');
  }

  static Future<void> loadFavorites() async {
    try {
      final favRef = _getUserFavorites();
      if (favRef == null) { savedNames.clear(); return; }
      var snap = await favRef.get();
      savedNames = snap.docs.map((d) => d.id).toSet();
    } catch (e) { debugPrint('讀取收藏失敗: $e'); }
  }

  static Future<void> toggleFavorite(String name, String type) async {
    try {
      final favRef = _getUserFavorites();
      if (favRef == null) { debugPrint('未登入，無法收藏'); return; }
      if (savedNames.contains(name)) {
        savedNames.remove(name);
        await favRef.doc(name).delete();
      } else {
        savedNames.add(name);
        await favRef.doc(name).set({'name': name, 'type': type, 'savedAt': FieldValue.serverTimestamp()});
      }
    } catch (e) { debugPrint('儲存收藏失敗: $e'); }
  }
}

class FoodComment {
  final String userName;
  final String text;
  final String date;
  final double stars;
  final bool isMe;
  const FoodComment({required this.userName, required this.text, required this.date, required this.stars, required this.isMe});
}

class FoodModel {
  final String name;
  final String shortDesc;
  final String location;
  final String price;
  final int parsedPrice;
  final String distance;
  final String phone;
  final String category;
  final String serviceTime;
  final String websiteUrl;
  final List<String> images;
  final List<String> tags;
  final List<(String, String)> recommendedDishes;
  final String fullDesc;
  final List<FoodComment> othersComments;
  final bool hasImage;
  final String? imageBase64;
  String aiReason;

  FoodModel({
    required this.name, required this.shortDesc, required this.location,
    required this.price, required this.parsedPrice, required this.distance,
    required this.phone, required this.category, required this.serviceTime,
    required this.websiteUrl, required this.images, required this.tags,
    required this.recommendedDishes, required this.fullDesc,
    required this.othersComments, required this.hasImage,
    this.aiReason = '', this.imageBase64,
  });
}

class FoodScreen extends StatefulWidget {
  const FoodScreen({super.key});
  @override
  State<FoodScreen> createState() => _FoodScreenState();
}

class _FoodScreenState extends State<FoodScreen> {
  int _catIndex = 0;
  String _mealFilter = '';
  final TextEditingController _searchCtrl = TextEditingController();

  List<FoodModel> _allFoods = [];
  bool _isLoading = true;
  String _errorMsg = '';

  final List<(IconData, String)> _cats = [
    (Icons.apps_rounded, '全部'),
    (Icons.rice_bowl_rounded, '火雞肉飯'),
    (Icons.local_cafe_rounded, '文青咖啡'),
    (Icons.storefront_rounded, '夜市小吃'),
    (Icons.restaurant_rounded, '特色餐館'),
    (Icons.card_giftcard_rounded, '伴手禮'),
  ];

  @override
  void initState() {
    super.initState();
    FavoriteManager.loadFavorites().then((_) { if (mounted) setState(() {}); });
    _fetchRestaurants();
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  Future<void> _fetchRestaurants() async {
    try {
      var snapshot = await FirebaseFirestore.instance.collection('Restaurants').get();
      List<FoodModel> parsedList = [];

      for (var doc in snapshot.docs) {
        try {
          Map<String, dynamic> data = doc.data();
          String name = data['RestaurantName']?.toString() ?? '未命名餐廳';
          String address = data['StreetAddress']?.toString() ?? '嘉義市';
          if (address == '沒有' || address.trim().isEmpty) address = '嘉義市';

          String desc = data['Description']?.toString() ?? '';
          if (desc == '沒有') desc = '';
          String fullDesc = desc.isEmpty ? '暫無詳細介紹，建議直接前往探索在地風味！' : desc;
          String shortDesc = desc.length > 40 ? '${desc.substring(0, 40)}...' : desc;
          if (shortDesc.isEmpty) shortDesc = '嘉義在地推薦好味道，歡迎來品嚐！';

          String priceStr = data['Price']?.toString() ?? '';
          int parsedPrice = 0;
          if (priceStr != '沒有' && priceStr.isNotEmpty && priceStr != '0' && priceStr != '0.0') {
            parsedPrice = int.tryParse(priceStr.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
          }
          if (priceStr == '沒有' || priceStr == '0' || priceStr == '0.0' || priceStr.trim().isEmpty) priceStr = '';

          String timeStr = data['ServiceTimeInfo']?.toString() ?? '';
          if (timeStr == '沒有' || timeStr.isEmpty) {
            timeStr = '依現場公告';
          } else {
            timeStr = timeStr.split(RegExp(r'[;；]')).map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
          }

          String phoneStr = '沒有提供';
          var tels = data['Telephones'];
          if (tels is List && tels.isNotEmpty) {
            var firstTel = tels[0];
            if (firstTel is Map) phoneStr = firstTel['phoneNumber']?.toString() ?? '沒有提供';
          }

          String webUrl = data['WebsiteUrl']?.toString() ?? '';
          if (webUrl == '沒有') webUrl = '';

          List<String> imageUrls = [];
          bool hasRealImage = false;
          var imgs = data['Images'];
          if (imgs is List) {
            for (var img in imgs) {
              if (img is Map && img['url'] != null) {
                String u = img['url'].toString();
                if (u.startsWith('http')) { imageUrls.add(u); hasRealImage = true; }
              }
            }
          }
          if (imageUrls.isEmpty) imageUrls.add('https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=800');

          String? base64String;
          if (data['ImageBase64'] != null && data['ImageBase64'].toString().isNotEmpty) {
            base64String = data['ImageBase64'].toString();
            hasRealImage = true;
          }

          String cat = '特色餐館';
          if (name.contains('火雞') || name.contains('雞肉飯')) cat = '火雞肉飯';
          else if (name.contains('咖啡') || name.contains('甜點') || name.contains('烘焙') || name.contains('Cafe') || name.contains('冰')) cat = '文青咖啡';
          else if (name.contains('蛋捲') || name.contains('餅') || name.contains('酥') || name.contains('伴手禮')) cat = '伴手禮';
          else if (name.contains('夜市') || name.contains('小吃') || name.contains('魯熟肉') || name.contains('麵線')) cat = '夜市小吃';
          else {
            if (desc.contains('手作甜點') || desc.contains('單品咖啡')) cat = '文青咖啡';
            else if (desc.contains('伴手禮名店')) cat = '伴手禮';
          }

          List<String> tags = [];
          if (cat == '火雞肉飯') tags.addAll(['嘉義必吃', '老字號']);
          else if (cat == '文青咖啡') tags.addAll(['網美打卡', '手沖咖啡']);
          else if (cat == '伴手禮') tags.addAll(['特色伴手禮', '排隊名店']);
          else tags.addAll(['在地美食', '特色餐館']);

          List<(String, String)> dishes = [];
          if (desc.contains('推薦餐點：')) {
            String recText = data['Description'].toString().split('推薦餐點：').last;
            List<String> items = recText.split('、');
            for (var item in items) {
              String cleanItem = item.replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]'), '').trim();
              if (cleanItem.isNotEmpty && cleanItem.length < 15) dishes.add(('https://images.unsplash.com/photo-1493770348161-369560ae357d?w=300', cleanItem));
            }
          }
          if (dishes.isEmpty) dishes.add(('https://images.unsplash.com/photo-1493770348161-369560ae357d?w=300', '主廚推薦料理'));

          List<FoodComment> comments = [];

          FoodModel newModel = FoodModel(
            name: name, shortDesc: shortDesc, location: address,
            price: priceStr, parsedPrice: parsedPrice, distance: '探索中',
            phone: phoneStr, category: cat, serviceTime: timeStr,
            websiteUrl: webUrl, images: imageUrls, tags: tags,
            recommendedDishes: dishes, fullDesc: fullDesc,
            othersComments: comments, hasImage: hasRealImage, imageBase64: base64String,
          );

          String baseName = name.replaceAll(RegExp(r'[\(（].*?[\)）]'), '').replaceAll(RegExp(r'\s+'), '');
          String baseAddr = address.replaceAll(RegExp(r'\s+|嘉義市|東區|西區'), '');

          bool isDuplicate = false;
          for (int i = 0; i < parsedList.length; i++) {
            FoodModel existing = parsedList[i];
            String existingBaseName = existing.name.replaceAll(RegExp(r'[\(（].*?[\)）]'), '').replaceAll(RegExp(r'\s+'), '');
            String existingBaseAddr = existing.location.replaceAll(RegExp(r'\s+|嘉義市|東區|西區'), '');
            bool nameMatch = (baseName == existingBaseName && baseName.isNotEmpty);
            bool addrMatch = (baseAddr == existingBaseAddr && baseAddr.length > 5);
            if (nameMatch || addrMatch) {
              isDuplicate = true;
              if (newModel.fullDesc.length > existing.fullDesc.length) parsedList[i] = newModel;
              break;
            }
          }
          if (!isDuplicate) parsedList.add(newModel);
        } catch (e) { debugPrint('解析資料錯誤: $e'); }
      }

      parsedList.sort((a, b) {
        if (a.hasImage && !b.hasImage) return -1;
        if (!a.hasImage && b.hasImage) return 1;
        return 0;
      });

      setState(() { _allFoods = parsedList; _isLoading = false; });
    } catch (e) { setState(() { _errorMsg = e.toString(); _isLoading = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(backgroundColor: Color(0xFFF9F8F4), body: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88))));
    if (_errorMsg.isNotEmpty) return Scaffold(backgroundColor: const Color(0xFFF9F8F4), body: Center(child: Text('載入失敗: $_errorMsg', style: const TextStyle(color: Colors.red))));

    String query = _searchCtrl.text.trim().toLowerCase();
    final displayFoods = _allFoods.where((f) {
      bool matchCat = _catIndex == 0 || f.category == _cats[_catIndex].$2;
      bool matchSearch = query.isEmpty || f.name.toLowerCase().contains(query);
      bool matchMeal = true;
      if (_mealFilter == '早餐') matchMeal = f.serviceTime.contains('06:') || f.serviceTime.contains('07:') || f.serviceTime.contains('08:') || f.serviceTime.contains('09:') || f.serviceTime.contains('24 小時');
      else if (_mealFilter == '午餐') matchMeal = f.serviceTime.contains('11:') || f.serviceTime.contains('12:') || f.serviceTime.contains('13:') || f.serviceTime.contains('24 小時');
      else if (_mealFilter == '晚餐') matchMeal = f.serviceTime.contains('17:') || f.serviceTime.contains('18:') || f.serviceTime.contains('19:') || f.serviceTime.contains('24 小時');
      return matchCat && matchSearch && matchMeal;
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverToBoxAdapter(child: _buildSearchBar()),
            SliverToBoxAdapter(child: _buildMealSection()),
            SliverToBoxAdapter(child: _FloatingWrapper(child: _buildGachaButton())),
            SliverToBoxAdapter(child: _buildCategoryIcons()),
            if (_allFoods.length >= 2) SliverToBoxAdapter(child: _buildFeaturedHotSection()),
            if (displayFoods.isEmpty)
              const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('找不到符合條件的餐廳 😢', style: TextStyle(color: Colors.grey, fontSize: 16)))))
            else
              SliverList(delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _FoodCard(food: displayFoods[i], index: i, onReturn: () => setState((){})),
                childCount: displayFoods.length,
              )),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 16),
      child: Stack(alignment: Alignment.center, children: [
        Align(alignment: Alignment.centerLeft, child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))]), child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Color(0xFF7D6E5D))),
        )),
        Column(mainAxisSize: MainAxisSize.min, children: [
          const Row(mainAxisSize: MainAxisSize.min, children: [
            Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
            Text('FOODS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
          ]),
          const SizedBox(height: 6),
          Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.08), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3), width: 1)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.restaurant_rounded, size: 14, color: Color(0xFF8BAA88)), SizedBox(width: 6), Text('美食推薦', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))])),
        ]),
      ]),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Container(
        height: 52,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)]),
        child: Row(children: [
          const SizedBox(width: 18),
          const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _searchCtrl, onChanged: (v) => setState(() {}), onSubmitted: (v) { FocusScope.of(context).unfocus(); setState((){}); }, decoration: const InputDecoration(hintText: '搜尋店名...', hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 14), border: InputBorder.none))),
          if (_searchCtrl.text.isNotEmpty) IconButton(icon: const Icon(Icons.cancel_rounded, color: Colors.grey, size: 18), onPressed: () { _searchCtrl.clear(); setState(() {}); }),
          GestureDetector(onTap: () { FocusScope.of(context).unfocus(); setState(() {}); }, child: Padding(padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6), child: Container(padding: const EdgeInsets.symmetric(horizontal: 18), decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(20)), child: const Center(child: Text('搜尋', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)))))),
        ]),
      ),
    );
  }

  Widget _buildMealSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 25),
      child: Row(children: [
        _MainMealFlipCard(title: '早餐', emoji: '🍳', sub: '營養必備', color: const Color(0xFFE8DFC8), isSelected: _mealFilter == '早餐', onTap: () => setState(() => _mealFilter = _mealFilter == '早餐' ? '' : '早餐')),
        const SizedBox(width: 12),
        _MainMealFlipCard(title: '午餐', emoji: '🍛', sub: '美味吃飽', color: const Color(0xFFA5CBD4).withOpacity(0.25), isSelected: _mealFilter == '午餐', onTap: () => setState(() => _mealFilter = _mealFilter == '午餐' ? '' : '午餐')),
        const SizedBox(width: 12),
        _MainMealFlipCard(title: '晚餐', emoji: '🍜', sub: '晚餐精選', color: const Color(0xFF8BAA88).withOpacity(0.15), isSelected: _mealFilter == '晚餐', onTap: () => setState(() => _mealFilter = _mealFilter == '晚餐' ? '' : '晚餐')),
      ]),
    );
  }

  Widget _buildGachaButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: GestureDetector(
        onTap: () => showDialog(context: context, builder: (ctx) => _GachaOverlay(allFoods: _allFoods)),
        child: Container(
          height: 65, padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.12), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88), width: 1.5), boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 5))]),
          child: Row(children: [
            const Icon(Icons.auto_fix_high_rounded, color: Color(0xFF8BAA88), size: 26),
            const SizedBox(width: 12),
            const Text('AI 智慧扭蛋：破殼推薦', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
            const Spacer(),
            Container(padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: Color(0xFF8BAA88), shape: BoxShape.circle), child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16)),
          ]),
        ),
      ),
    );
  }

  Widget _buildCategoryIcons() {
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _cats.length,
        itemBuilder: (ctx, i) {
          final sel = i == _catIndex;
          return GestureDetector(
            onTap: () => setState(() => _catIndex = i),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(children: [
              AnimatedContainer(duration: const Duration(milliseconds: 250), width: 56, height: 56, decoration: BoxDecoration(color: sel ? const Color(0xFF8BAA88) : Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)), boxShadow: sel ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))] : null), child: Icon(_cats[i].$1, color: sel ? Colors.white : const Color(0xFF8BAA88), size: 24)),
              const SizedBox(height: 8),
              Text(_cats[i].$2, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
            ])),
          );
        },
      ),
    );
  }

  Widget _buildFeaturedHotSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.fromLTRB(24, 20, 24, 16), child: Text('精選熱門', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 19, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: math.min(_allFoods.length, 5),
            itemBuilder: (ctx, i) => GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (ctx) => FoodDetailScreen(foodData: _allFoods[i]))).then((_) => setState((){})),
              child: Container(
                width: 300, margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), image: DecorationImage(image: _allFoods[i].imageBase64 != null ? MemoryImage(base64Decode(_allFoods[i].imageBase64!)) as ImageProvider : NetworkImage(_allFoods[i].images[0]), fit: BoxFit.cover)),
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_allFoods[i].name, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(_allFoods[i].shortDesc, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white70, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}

// ── 主畫面翻牌卡片 ────────────────────────────────────────────
class _MainMealFlipCard extends StatelessWidget {
  final String title, emoji, sub;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  const _MainMealFlipCard({required this.title, required this.emoji, required this.sub, required this.color, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: GestureDetector(onTap: onTap, child: TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: isSelected ? math.pi : 0),
      duration: const Duration(milliseconds: 550), curve: Curves.easeOutBack,
      builder: (context, angle, child) {
        final isBack = angle >= math.pi / 2;
        final sinAngle = (math.sin(angle)).abs();
        final scaleFactor = 1.0 + (sinAngle * 0.12);
        final shadowBlur = 4.0 + (sinAngle * 14.0);
        final shadowOffset = 2.0 + (sinAngle * 7.0);
        return Transform(alignment: Alignment.center, transform: Matrix4.identity()..setEntry(3, 2, 0.0022)..scale(scaleFactor, scaleFactor)..rotateY(angle),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(color: isBack ? const Color(0xFF8BAA88) : color, borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: isBack ? const Color(0xFF8BAA88).withOpacity(0.4) : Colors.black.withOpacity(0.04 + (sinAngle * 0.06)), blurRadius: shadowBlur, spreadRadius: sinAngle * 1.2, offset: Offset(0, shadowOffset))],
                border: Border.all(color: isBack ? const Color(0xFF8BAA88) : Colors.white, width: 2)),
            child: Stack(fit: StackFit.loose, alignment: Alignment.center, children: [
              Transform(alignment: Alignment.center, transform: isBack ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
                child: isBack
                    ? Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.check_circle_rounded, color: Color(0xFFFBC02D), size: 28), const SizedBox(height: 8), Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)), const SizedBox(height: 2), const Text('已鎖定餐期', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white70))])
                    : Column(mainAxisSize: MainAxisSize.min, children: [Text(emoji, style: const TextStyle(fontSize: 26)), const SizedBox(height: 8), Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))), const SizedBox(height: 2), Text(sub, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)))]),
              ),
              if (sinAngle > 0.08) IgnorePointer(child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white.withOpacity(0.0), Colors.white.withOpacity(sinAngle * 0.28), Colors.white.withOpacity(0.0)], stops: const [0.25, 0.5, 0.75])))),
            ]),
          ),
        );
      },
    )));
  }
}

class _FoodCard extends StatefulWidget {
  final FoodModel food;
  final int index;
  final VoidCallback onReturn;
  const _FoodCard({required this.food, required this.index, required this.onReturn});
  @override
  State<_FoodCard> createState() => _FoodCardState();
}

class _FoodCardState extends State<_FoodCard> {
  final Map<String, Color> _tagColors = {
    '老字號': const Color(0xFF7D6E5D), '排隊名店': const Color(0xFFFBC02D), '嘉義必吃': const Color(0xFFE57373),
    '網美打卡': const Color(0xFF03A9F4), '手沖咖啡': const Color(0xFF8BAA88), '文創聚落': const Color(0xFF9C27B0),
    '在地美食': const Color(0xFF8BAA88), '特色伴手禮': const Color(0xFF9C27B0),
  };
  Color _getTagColor(String tag) => _tagColors[tag] ?? const Color(0xFF8BAA88);

  void _toggleFav() async {
    await FavoriteManager.toggleFavorite(widget.food.name, '美食推薦');
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedNames.contains(widget.food.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isFav ? '❤️ 已將 ${widget.food.name} 儲存至雲端收藏！' : '🗑️ 已取消收藏'), backgroundColor: isFav ? const Color(0xFFE57373) : const Color(0xFF9E9182), duration: const Duration(seconds: 2)));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isFav = FavoriteManager.savedNames.contains(widget.food.name);
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (ctx) => FoodDetailScreen(foodData: widget.food))).then((_) => widget.onReturn()),
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 16), padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)]),
        child: Row(children: [
          Stack(children: [
            ClipRRect(borderRadius: BorderRadius.circular(15), child: widget.food.imageBase64 != null
                ? Image.memory(base64Decode(widget.food.imageBase64!), width: 100, height: 100, fit: BoxFit.cover)
                : Image.network(widget.food.images[0], width: 100, height: 100, fit: BoxFit.cover, cacheHeight: 300)),
            Positioned(top: 0, left: 0, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: widget.index == 0 ? const Color(0xFFE57373) : const Color(0xFF8BAA88), borderRadius: const BorderRadius.only(topLeft: Radius.circular(15), bottomRight: Radius.circular(10))), child: Text(widget.index == 0 ? 'TOP 1' : 'HOT', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(widget.food.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)),
              GestureDetector(onTap: _toggleFav, child: Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: isFav ? const Color(0xFFE57373).withOpacity(0.1) : const Color(0xFF8BAA88).withOpacity(0.15), shape: BoxShape.circle), child: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? const Color(0xFFE57373) : const Color(0xFF8BAA88), size: 16))),
            ]),
            const SizedBox(height: 4),
            Text(widget.food.shortDesc, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: const Color(0xFF7D6E5D).withOpacity(0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: widget.food.tags.map((t) => Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: _getTagColor(t).withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: _getTagColor(t), fontSize: 9, fontWeight: FontWeight.bold)))).toList()),
            const SizedBox(height: 10),
            Row(children: [
              _infoBox(widget.food.distance, const Color(0xFF8BAA88)),
              if (widget.food.price.isNotEmpty) ...[const SizedBox(width: 6), _infoBox('NT\$ ${widget.food.price}', const Color(0xFF7D6E5D))],
            ]),
          ])),
        ]),
      ),
    );
  }

  Widget _infoBox(String text, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.3), width: 1.5)), child: Text(text, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: color)));
}

class _FloatingWrapper extends StatefulWidget {
  final Widget child;
  const _FloatingWrapper({required this.child});
  @override
  State<_FloatingWrapper> createState() => _FloatingWrapperState();
}

class _FloatingWrapperState extends State<_FloatingWrapper> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _animation;
  @override
  void initState() { super.initState(); _controller = AnimationController(duration: const Duration(milliseconds: 1500), vsync: this)..repeat(reverse: true); _animation = Tween<Offset>(begin: Offset.zero, end: const Offset(0.0, -0.05)).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)); }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => SlideTransition(position: _animation, child: widget.child);
}

class _GachaFlipCard extends StatelessWidget {
  final String title, emoji;
  final bool isSelected;
  final VoidCallback onTap;
  const _GachaFlipCard({required this.title, required this.emoji, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: isSelected ? math.pi : 0),
      duration: const Duration(milliseconds: 500), curve: Curves.easeOutBack,
      builder: (context, angle, child) {
        final isBack = angle >= math.pi / 2;
        final sinAngle = (math.sin(angle)).abs();
        final scaleFactor = 1.0 + (sinAngle * 0.15);
        final shadowBlur = 4.0 + (sinAngle * 12.0);
        final shadowOffset = 2.0 + (sinAngle * 6.0);
        return Transform(alignment: Alignment.center, transform: Matrix4.identity()..setEntry(3, 2, 0.0025)..scale(scaleFactor, scaleFactor)..rotateY(angle),
          child: Container(width: 82, height: 88,
            decoration: BoxDecoration(color: isBack ? const Color(0xFF8BAA88) : Colors.white, borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: isBack ? const Color(0xFF8BAA88).withOpacity(0.35) : Colors.black.withOpacity(0.06 + (sinAngle * 0.05)), blurRadius: shadowBlur, spreadRadius: sinAngle * 1.5, offset: Offset(0, shadowOffset))],
                border: Border.all(color: isBack ? const Color(0xFF8BAA88) : const Color(0xFF7D6E5D).withOpacity(0.25), width: 1.8)),
            child: Stack(fit: StackFit.expand, children: [
              Transform(alignment: Alignment.center, transform: isBack ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
                  child: isBack
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.check_circle_rounded, color: Color(0xFFFBC02D), size: 20), const SizedBox(height: 5), Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900))])
                      : Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(emoji, style: const TextStyle(fontSize: 22)), const SizedBox(height: 5), Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 13, fontWeight: FontWeight.bold))])),
              if (sinAngle > 0.1) IgnorePointer(child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white.withOpacity(0.0), Colors.white.withOpacity(sinAngle * 0.25), Colors.white.withOpacity(0.0)], stops: const [0.3, 0.5, 0.7])))),
            ]),
          ),
        );
      },
    ));
  }
}

class _GachaOverlay extends StatefulWidget {
  final List<FoodModel> allFoods;
  const _GachaOverlay({required this.allFoods});
  @override
  State<_GachaOverlay> createState() => _GachaOverlayState();
}

class _GachaOverlayState extends State<_GachaOverlay> with SingleTickerProviderStateMixin {
  int _step = 0;
  String _selectedMeal = '午餐';
  String _selectedCategory = '全部';
  final TextEditingController _budgetCtrl = TextEditingController();
  late AnimationController _glowCtrl;
  FoodModel? _result;
  bool _isFallback = false;
  final List<String> _gachaCategories = ['全部', '米飯', '麵食', '火鍋', '點心甜甜', '夜市小吃'];
  static const String _apiKey = 'YOUR_GEMINI_API_KEY';
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent';

  @override
  void initState() { super.initState(); _glowCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500)); }
  @override
  void dispose() { _glowCtrl.dispose(); _budgetCtrl.dispose(); super.dispose(); }

  Future<void> _startGachaWithAI() async {
    if (_budgetCtrl.text.isEmpty) return;
    setState(() => _step = 1);
    _glowCtrl.repeat();
    int userBudget = int.tryParse(_budgetCtrl.text.trim()) ?? 0;
    final now = DateTime.now();
    final currentTimeString = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

    List<FoodModel> candidates = widget.allFoods.where((f) {
      bool matchBudget = f.parsedPrice <= userBudget || f.parsedPrice == 0;
      bool matchCat = true;
      if (_selectedCategory == '米飯') matchCat = f.name.contains('飯') || f.category.contains('米飯') || f.name.contains('火雞');
      else if (_selectedCategory == '麵食') matchCat = f.name.contains('麵') || f.name.contains('粉');
      else if (_selectedCategory == '火鍋') matchCat = f.name.contains('鍋') || f.fullDesc.contains('麻辣');
      else if (_selectedCategory == '點心甜甜') matchCat = f.name.contains('咖啡') || f.name.contains('甜點') || f.name.contains('冰') || f.category.contains('文青咖啡');
      else if (_selectedCategory == '夜市小吃') matchCat = f.category.contains('夜市小吃') || f.name.contains('小吃');
      bool matchMeal = true;
      if (_selectedMeal == '早餐') matchMeal = f.serviceTime.contains('06:') || f.serviceTime.contains('07:') || f.serviceTime.contains('08:') || f.serviceTime.contains('24 小時');
      else if (_selectedMeal == '午餐') matchMeal = f.serviceTime.contains('11:') || f.serviceTime.contains('12:') || f.serviceTime.contains('24 小時');
      else if (_selectedMeal == '晚餐') matchMeal = f.serviceTime.contains('17:') || f.serviceTime.contains('18:') || f.serviceTime.contains('24 小時');
      return matchCat && matchBudget && matchMeal;
    }).toList();

    if (candidates.isEmpty) { _isFallback = true; candidates = List.from(widget.allFoods); } else { _isFallback = false; }
    if (candidates.isEmpty) { setState(() { _step = 2; _result = null; }); _glowCtrl.stop(); return; }

    candidates.shuffle();
    final candidateListForAI = candidates.take(15).map((e) => {'name': e.name, 'category': e.category, 'shortDesc': e.shortDesc, 'price': e.price, 'serviceTime': e.serviceTime}).toList();

    final body = jsonEncode({
      'system_instruction': {'parts': [{'text': '你是嘉義在地美食探店雷達「阿布」。請挑選出此時此刻正在營業的店，並寫下35字內的推薦原因。請直接以JSON格式回傳：{"selectedName": "名稱", "reason": "原因"}'}]},
      'contents': [{'role': 'user', 'parts': [{'text': '餐期：$_selectedMeal，預算：$userBudget，口味：$_selectedCategory，現在時間：$currentTimeString。候選：${jsonEncode(candidateListForAI)}'}]}],
      'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 300, 'responseMimeType': 'application/json'},
    });

    try {
      await Future.delayed(const Duration(milliseconds: 2000));
      final response = await http.post(Uri.parse('$_baseUrl?key=$_apiKey'), headers: {'Content-Type': 'application/json'}, body: body);
      _glowCtrl.stop();
      if (response.statusCode == 200) {
        final resData = jsonDecode(response.body);
        final String rawReply = resData['candidates'][0]['content']['parts'][0]['text'] as String;
        final parsedReply = jsonDecode(rawReply.trim());
        String aiSelectedName = parsedReply['selectedName']?.toString() ?? '';
        String aiReason = parsedReply['reason']?.toString() ?? '在地老饕激推！這間風味非常迷人，不吃可惜！';
        FoodModel matchModel = candidates.firstWhere((f) => f.name == aiSelectedName, orElse: () => candidates[math.Random().nextInt(candidates.length)]);
        setState(() { _step = 2; _result = matchModel; _result!.aiReason = aiReason; });
      } else { _fallbackToLocalRandom(candidates); }
    } catch (e) { _glowCtrl.stop(); _fallbackToLocalRandom(candidates); }
  }

  void _fallbackToLocalRandom(List<FoodModel> candidates) {
    setState(() { _step = 2; _result = candidates[math.Random().nextInt(candidates.length)]; _result!.aiReason = '精選在地推薦，探索最經典的嘉義好味道！'; });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _step == 2 ? Colors.transparent : const Color(0xFFF9F8F4),
      elevation: _step == 2 ? 0 : 8,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: AnimatedContainer(duration: const Duration(milliseconds: 300), padding: _step == 2 ? EdgeInsets.zero : const EdgeInsets.all(24.0), child: AnimatedSwitcher(duration: const Duration(milliseconds: 400), child: _buildContent())),
    );
  }

  Widget _buildContent() {
    if (_step == 0) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.explore_rounded, color: Color(0xFF8BAA88), size: 24), SizedBox(width: 8), Text('設定智慧扭蛋', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _GachaFlipCard(title: '早餐', emoji: '🍳', isSelected: _selectedMeal == '早餐', onTap: () => setState(() => _selectedMeal = '早餐')),
          _GachaFlipCard(title: '午餐', emoji: '🍛', isSelected: _selectedMeal == '午餐', onTap: () => setState(() => _selectedMeal = '午餐')),
          _GachaFlipCard(title: '晚餐', emoji: '🍜', isSelected: _selectedMeal == '晚餐', onTap: () => setState(() => _selectedMeal = '晚餐')),
        ]),
        const SizedBox(height: 24),
        TextField(controller: _budgetCtrl, keyboardType: TextInputType.number, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold),
            decoration: InputDecoration(labelText: '預算上限 (元)', labelStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182)), prefixIcon: const Icon(Icons.currency_yen_rounded, color: Color(0xFF8BAA88), size: 20), filled: true, fillColor: Colors.white, enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: const Color(0xFF8BAA88).withOpacity(0.2))), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF8BAA88))))),
        const SizedBox(height: 20),
        const Padding(padding: EdgeInsets.only(left: 4, bottom: 10), child: Text('想吃什麼類別？', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))),
        Wrap(spacing: 8, runSpacing: 8, children: _gachaCategories.map((cat) {
          final isSel = _selectedCategory == cat;
          return GestureDetector(onTap: () => setState(() => _selectedCategory = cat), child: AnimatedContainer(duration: const Duration(milliseconds: 180), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: isSel ? const Color(0xFF7D6E5D) : Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: isSel ? const Color(0xFF7D6E5D) : const Color(0xFF8BAA88).withOpacity(0.25))), child: Text(cat, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12.5, color: isSel ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.bold))));
        }).toList()),
        const SizedBox(height: 28),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))), onPressed: _startGachaWithAI, child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.radar_rounded, color: Colors.white, size: 18), SizedBox(width: 8), Text('開啟老饕雷達，即刻搜尋', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white))]))),
      ]);
    } else if (_step == 1) {
      return Container(height: 260, alignment: Alignment.center, child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(animation: _glowCtrl, builder: (ctx, child) {
          final value = _glowCtrl.value;
          return Stack(alignment: Alignment.center, children: [
            Container(width: 80 + (value * 70), height: 80 + (value * 70), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity((1.0 - value).clamp(0.0, 1.0)), width: 2.0))),
            Container(width: 80 + (((value + 0.5) % 1.0) * 70), height: 80 + (((value + 0.5) % 1.0) * 70), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF7D6E5D).withOpacity((1.0 - ((value + 0.5) % 1.0)).clamp(0.0, 1.0)), width: 1.5))),
            Container(width: 76, height: 76, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.15), blurRadius: 12)]), child: const Icon(Icons.explore_rounded, color: Color(0xFF8BAA88), size: 42)),
          ]);
        }),
        const SizedBox(height: 45),
        const Text('老饕雷達掃描中，正在比對此時此刻營業店家...', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 13, fontWeight: FontWeight.w900)),
      ]));
    } else {
      if (_result == null) return const Center(child: Text('目前還沒有符合條件的餐點喔！'));
      return Center(child: Container(
        width: double.infinity,
        decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(26), border: Border.all(color: const Color(0xFF8BAA88), width: 2), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 25, offset: const Offset(0, 10))]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(height: 12, decoration: const BoxDecoration(color: Color(0xFF8BAA88), borderRadius: BorderRadius.vertical(top: Radius.circular(24)))),
          const SizedBox(height: 16),
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Text('📍 雷達精準鎖定 ‧ 探店卡片 📍', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), letterSpacing: 1))]),
          const SizedBox(height: 14),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF7D6E5D).withOpacity(0.15)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 3))]),
            child: Column(children: [
              Stack(children: [
                ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(17)), child: Image.network(_result!.images[0], height: 160, width: double.infinity, fit: BoxFit.cover)),
                Positioned(top: 12, right: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(20)), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.restaurant_rounded, color: Colors.white, size: 12), const SizedBox(width: 4), Text(_result!.category, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))]))),
              ]),
              Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), child: Text(_result!.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 19, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), textAlign: TextAlign.center)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_result!.shortDesc, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(height: 14),
              Container(width: double.infinity, margin: const EdgeInsets.fromLTRB(14, 0, 14, 16), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.07), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.18), width: 1.2)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.comment_bank_rounded, size: 15, color: Color(0xFF8BAA88)), const SizedBox(width: 8), Expanded(child: Text(_result!.aiReason, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12.5, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, height: 1.4)))])),
            ]),
          )),
          Padding(padding: const EdgeInsets.all(20.0), child: Row(children: [
            Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF8BAA88), width: 1.5), padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: () => Navigator.pop(context), child: const Text('放回機台', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)))),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), padding: const EdgeInsets.symmetric(vertical: 13), elevation: 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => FoodDetailScreen(foodData: _result!))); }, child: const Text('撕開卡片', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.w900)))),
          ])),
        ]),
      ));
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  美食詳情頁面 ─ Firestore 留言版
// ═══════════════════════════════════════════════════════════════
class FoodDetailScreen extends StatefulWidget {
  final FoodModel foodData;
  const FoodDetailScreen({super.key, required this.foodData});
  @override
  State<FoodDetailScreen> createState() => _FoodDetailScreenState();
}

class _FoodDetailScreenState extends State<FoodDetailScreen> {
  int _currImg = 0;
  final TextEditingController _commentCtrl = TextEditingController();
  bool _isPosting = false;

  // ★ Firestore 路徑：Restaurants/{docId}/comments
  CollectionReference get _commentsRef => FirebaseFirestore.instance
      .collection('Restaurants')
      .doc(widget.foodData.name.hashCode.abs().toString())
      .collection('comments');

  @override
  void initState() { super.initState(); }

  @override
  void dispose() { _commentCtrl.dispose(); super.dispose(); }

  // ── 取得登入使用者頭像 Base64 ──────────────────────────────
  Future<String?> _getMyAvatarBase64() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return doc.data()?['avatarBase64']?.toString();
    } catch (_) { return null; }
  }

  // ── 我的頭像 widget ───────────────────────────────────────
  Widget _buildMyAvatar(User user) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final avatarB64 = (data is Map) ? (data as Map<String, dynamic>)['avatarBase64']?.toString() ?? '' : '';
        if (avatarB64.isNotEmpty) {
          try {
            final bytes = base64Decode(avatarB64);
            return CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes));
          } catch (_) {}
        }
        final initial = (user.displayName?.isNotEmpty == true)
            ? user.displayName![0].toUpperCase()
            : (user.email?.isNotEmpty == true ? user.email![0].toUpperCase() : '?');
        return CircleAvatar(radius: 20, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
            child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 14)));
      },
    );
  }

  // ── 留言列表頭像 ─────────────────────────────────────────
  Widget _buildCommentAvatar(String avatarB64, String userName) {
    if (avatarB64.isNotEmpty) {
      try {
        final bytes = base64Decode(avatarB64);
        return CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes));
      } catch (_) {}
    }
    final initial = userName.isNotEmpty ? userName[0].toUpperCase() : '?';
    return CircleAvatar(radius: 20, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.15),
        child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 13)));
  }

  // ── 發送留言 ─────────────────────────────────────────────
  Future<void> _postComment() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('請先登入才能留言 😊', style: TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: Color(0xFF9E9182), behavior: SnackBarBehavior.floating,
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
        'uid': user.uid, 'userName': user.displayName ?? '匿名旅人',
        'text': text, 'avatarBase64': avatarBase64 ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
      _commentCtrl.clear();
      if (mounted) setState(() => _isPosting = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isPosting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('留言失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFB07070), behavior: SnackBarBehavior.floating));
      }
    }
  }

  // ── 刪除留言 ─────────────────────────────────────────────
  Future<void> _deleteComment(String docId) async {
    try {
      await _commentsRef.doc(docId).delete();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刪除失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFB07070), behavior: SnackBarBehavior.floating));
    }
  }

  void _toggleFav() async {
    await FavoriteManager.toggleFavorite(widget.foodData.name, '美食推薦');
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedNames.contains(widget.foodData.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isFav ? '❤️ 已將 ${widget.foodData.name} 儲存至雲端收藏！' : '🗑️ 已取消收藏'), backgroundColor: isFav ? const Color(0xFFE57373) : const Color(0xFF9E9182), duration: const Duration(seconds: 2)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Color> tagColors = {
      '老字號': const Color(0xFF7D6E5D), '排隊名店': const Color(0xFFFBC02D), '嘉義必吃': const Color(0xFFE57373),
      '網美打卡': const Color(0xFF03A9F4), '手沖咖啡': const Color(0xFF8BAA88), '文創聚落': const Color(0xFF9C27B0),
      '在地美食': const Color(0xFF8BAA88), '特色伴手禮': const Color(0xFF9C27B0), '特色餐館': const Color(0xFF7D6E5D),
    };
    bool isFav = FavoriteManager.savedNames.contains(widget.foodData.name);

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 350.0,
          pinned: true,
          backgroundColor: const Color(0xFFF9F8F4),
          leading: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.25),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(0.4)),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: GestureDetector(
                      onTap: _toggleFav,
                      child: Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: isFav ? Colors.white : Colors.white.withOpacity(0.25),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isFav ? const Color(0xFFE57373) : Colors.white.withOpacity(0.4),
                          ),
                        ),
                        child: Icon(
                          isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: isFav ? const Color(0xFFE57373) : Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),   // ← 這兩個是你原本缺的
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  onPageChanged: (v) => setState(() => _currImg = v),
                  itemCount: widget.foodData.imageBase64 != null ? 1 : widget.foodData.images.length,
                  itemBuilder: (ctx, i) {
                    if (widget.foodData.imageBase64 != null) {
                      return Image.memory(base64Decode(widget.foodData.imageBase64!), fit: BoxFit.cover);
                    }
                    return Image.network(widget.foodData.images[i], fit: BoxFit.cover);
                  },
                ),
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xFFF9F8F4)],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 50, left: 0, right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      widget.foodData.images.length,
                          (i) => Container(
                        margin: const EdgeInsets.all(3),
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _currImg == i ? const Color(0xFF8BAA88) : Colors.white60,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(
          child: Transform.translate(
            offset: const Offset(0, -30),
            child: Container(
              decoration: const BoxDecoration(color: Color(0xFFF9F8F4), borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 100),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.foodData.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: widget.foodData.tags.map((t) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: (tagColors[t] ?? const Color(0xFF8BAA88)).withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: tagColors[t] ?? const Color(0xFF8BAA88), fontSize: 10, fontWeight: FontWeight.bold)))).toList()),
                const SizedBox(height: 20),
                if (widget.foodData.price.isNotEmpty) ...[Row(children: [const Icon(Icons.monetization_on_rounded, color: Color(0xFF8BAA88), size: 18), const SizedBox(width: 8), Text('NT\$ ${widget.foodData.price}', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, fontWeight: FontWeight.w900))]), const SizedBox(height: 8)],
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.location_on_rounded, color: Color(0xFF8BAA88), size: 18), const SizedBox(width: 8), Expanded(child: Text(widget.foodData.location, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, height: 1.5, fontWeight: FontWeight.w900)))]),
                const SizedBox(height: 8),
                Row(children: [const Icon(Icons.phone_rounded, color: Color(0xFF8BAA88), size: 18), const SizedBox(width: 8), Text(widget.foodData.phone, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, fontWeight: FontWeight.w900))]),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.access_time_rounded, color: Color(0xFF8BAA88), size: 18), const SizedBox(width: 8), Expanded(child: Text(widget.foodData.serviceTime, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, height: 1.5, fontWeight: FontWeight.w900)))]),
                const SizedBox(height: 24),
                Row(children: [
                  _btn(Icons.navigation_rounded, '導航', onTap: () { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('導航功能即將推出'))); }),
                  const SizedBox(width: 10),
                  _btn(Icons.phone_rounded, '電話', onTap: () async {
                    String phone = widget.foodData.phone;
                    if (phone == '沒有提供' || phone.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('沒有店家電話'))); return; }
                    final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
                    if (cleanPhone.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無效的電話號碼'))); return; }
                    try { await launchUrl(Uri.parse('tel:$cleanPhone')); } catch (e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無法跳轉撥號畫面'))); }
                  }),
                  const SizedBox(width: 10),
                  _btn(Icons.language_rounded, '網站', onTap: () async {
                    String web = widget.foodData.websiteUrl;
                    if (web.isEmpty || web == '沒有') { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('沒有店家網址'))); return; }
                    if (!web.startsWith('http')) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無效的網址格式'))); return; }
                    try { await launchUrl(Uri.parse(web), mode: LaunchMode.externalApplication); } catch (e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('網頁跳轉失敗'))); }
                  }),
                ]),
                const SizedBox(height: 32),
                const Text('關於餐廳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 12),
                Text(widget.foodData.fullDesc, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14, height: 1.8)),
                const SizedBox(height: 40),
                const Text('網友留言', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 16),
                _buildCommentSection(),
              ]),
            ),
          ),
        ),
        ]),
    );
  }

  Widget _buildCommentSection() {
    final user = FirebaseAuth.instance.currentUser;
    final myUid = user?.uid;

    return Column(children: [
      // ── 輸入框 ───────────────────────────────────────────────
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
          child: Row(children: [
            _buildMyAvatar(user),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _commentCtrl, decoration: const InputDecoration(hintText: '說點什麼吧...', hintStyle: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, color: Colors.grey), border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero))),
            _isPosting
                ? const SizedBox(width: 38, height: 38, child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8BAA88))))
                : GestureDetector(onTap: _postComment, child: Container(padding: const EdgeInsets.all(10), decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF8BAA88)), child: const Icon(Icons.send_rounded, color: Colors.white, size: 18))),
          ]),
        ),

      const SizedBox(height: 24),

      // ── StreamBuilder 留言列表 ────────────────────────────────
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
            return const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('還沒有人留言喔，來搶頭香吧！', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 14))));
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

            return Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildCommentAvatar(avatarB64, userName),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(userName, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF7D6E5D)))),
                    Text(dateLabel, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
                    if (isMe) ...[const SizedBox(width: 6), GestureDetector(onTap: () => _deleteComment(doc.id), child: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFB07070)))],
                  ]),
                  const SizedBox(height: 8),
                  Text(text, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, color: Color(0xFF555555), height: 1.4)),
                ])),
              ]),
              const Divider(height: 32, color: Color(0xFFEBEBEB)),
            ]);
          }).toList());
        },
      ),
    ]);
  }

  Widget _btn(IconData icon, String label, {VoidCallback? onTap}) {
    return Expanded(child: GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2))), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: const Color(0xFF8BAA88), size: 18), const SizedBox(width: 6), Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)]))));
  }
}