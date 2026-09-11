import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'home_screen.dart' show buildSmartImage; // ✨ 引入我們做好的萬用圖片元件

// ═══════════════════════════════════════════════════════════════
//  住宿資訊頁面 ─ 嚴格字數排序版 (支援 Base64 圖片)
// ═══════════════════════════════════════════════════════════════

class FavoriteManager {
  static Set<String> savedNames = {};

  // 🌟 核心：動態取得當前登入使用者的專屬收藏路徑
  static CollectionReference? _getUserFavorites() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null; // 沒登入不能收藏
    // 將路徑改為：users -> {uid} -> Favorites
    return FirebaseFirestore.instance.collection('users').doc(user.uid).collection('Favorites');
  }

  static Future<void> loadFavorites() async {
    try {
      final favRef = _getUserFavorites();
      if (favRef == null) {
        savedNames.clear(); // 未登入則清空畫面上的愛心
        return;
      }
      var snap = await favRef.get();
      savedNames = snap.docs.map((d) => d.id).toSet();
    } catch (e) {
      debugPrint('讀取收藏失敗: $e');
    }
  }

  static Future<void> toggleFavorite(String name, String type) async {
    try {
      final favRef = _getUserFavorites();
      if (favRef == null) {
        debugPrint('未登入，無法收藏');
        return;
      }

      if (savedNames.contains(name)) {
        savedNames.remove(name);
        await favRef.doc(name).delete();
      } else {
        savedNames.add(name);
        await favRef.doc(name).set({
          'name': name,
          'type': type,
          'savedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('儲存收藏失敗: $e');
    }
  }
}

class HotelComment {
  final String userName;
  final String text;
  final String date;
  final double stars;
  final bool isMe;
  HotelComment({required this.userName, required this.text, required this.date, required this.stars, required this.isMe});
}

class RoomType {
  final String name;
  final String price;
  final String image;
  const RoomType({required this.name, required this.price, required this.image});
}

class HotelModel {
  final String name;
  final String desc;
  final String address;
  final String phone;
  final int price;
  final String rating;
  final List<String> tags;
  final List<String> images;
  final String imageBase64; // ✨ 支援 Base64 圖片
  final List<(IconData, String)> facilities;
  final List<RoomType> rooms;
  final List<HotelComment> comments;
  final String category;
  final String checkTimeInfo;
  final String websiteUrl;

  HotelModel({
    required this.name,
    required this.desc,
    required this.address,
    required this.phone,
    required this.price,
    required this.rating,
    required this.tags,
    required this.images,
    required this.imageBase64,
    required this.facilities,
    required this.rooms,
    required this.comments,
    required this.category,
    required this.checkTimeInfo,
    required this.websiteUrl,
  });
}

class AccommodationScreen extends StatefulWidget {
  const AccommodationScreen({super.key});
  @override
  State<AccommodationScreen> createState() => _AccommodationScreenState();
}

class _AccommodationScreenState extends State<AccommodationScreen> {
  int _catIndex = 0;
  final TextEditingController _searchCtrl = TextEditingController();

  final List<(IconData, String)> _cats = [
    (Icons.apps_rounded, '全部'),
    (Icons.business_rounded, '合法飯店'),
    (Icons.cottage_rounded, '特色民宿'),
    (Icons.backpack_rounded, '背包客棧'),
    (Icons.pets_rounded, '寵物友善'),
  ];

  Future<List<HotelModel>>? _hotelsFuture;

  @override
  void initState() {
    super.initState();
    FavoriteManager.loadFavorites().then((_) {
      if (mounted) setState(() {});
    });
    _hotelsFuture = _fetchHotelsFromFirebase();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<HotelModel>> _fetchHotelsFromFirebase() async {
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance.collection('Hotels').get();
      Map<String, HotelModel> addressToHotelMap = {};

      for (var doc in snapshot.docs) {
        try {
          Map<String, dynamic> data = doc.data() as Map<String, dynamic>;

          String name = data['HotelName']?.toString() ?? '未命名旅宿';
          String address = data['StreetAddress']?.toString() ?? '嘉義';
          if (address == '沒有' || address.trim().isEmpty) address = '嘉義';

          String desc = data['Description']?.toString().trim() ?? '';
          if (desc == '沒有') desc = '';

          // 去重：同一地址保留描述最長的
          if (addressToHotelMap.containsKey(address)) {
            if (addressToHotelMap[address]!.desc.length >= desc.length) {
              continue;
            }
          }

          int parsedPrice = 0;
          if (data['LowestPrice'] != null) {
            parsedPrice = int.tryParse(data['LowestPrice'].toString()) ?? 0;
          }

          double starVal = 0.0;
          if (data['HotelStars'] != null) {
            starVal = double.tryParse(data['HotelStars'].toString()) ?? 0.0;
          }
          String ratingStr = starVal > 0 ? starVal.toStringAsFixed(1) : '';

          String inTime = data['CheckInTime']?.toString() ?? '';
          String outTime = data['CheckOutTime']?.toString() ?? '';
          String timeInfo = '';
          if (inTime.isNotEmpty && inTime != '沒有') timeInfo += '入住: $inTime';
          if (outTime.isNotEmpty && outTime != '沒有') {
            timeInfo += timeInfo.isNotEmpty ? ' / 退房: $outTime' : '退房: $outTime';
          }
          if (timeInfo.isEmpty) timeInfo = '依現場規定';

          String webUrl = data['WebsiteUrl']?.toString() ?? '';
          if (webUrl == '沒有') webUrl = '';

          String phone = '';
          if (data['Telephones'] is List && (data['Telephones'] as List).isNotEmpty) {
            var firstTel = (data['Telephones'] as List)[0];
            if (firstTel is Map) {
              phone = firstTel['phoneNumber']?.toString() ?? '';
            }
          }
          if (phone == '沒有') phone = '';

          // ✨ 擷取 Base64 欄位
          String base64 = data['ImageBase64']?.toString() ?? '';

          List<String> imageUrls = [];
          if (data['Images'] is List) {
            for (var img in data['Images']) {
              if (img is Map && img['url'] != null) {
                String u = img['url'].toString();
                if (u.startsWith('http')) imageUrls.add(u);
              }
            }
          }

          // ✨ 只有在「沒有網址」且「沒有 Base64」的狀況下，才塞預設圖片！
          if (imageUrls.isEmpty && base64.isEmpty) {
            imageUrls.add('https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=800');
          }

          String category = '合法飯店';
          if (name.contains('民宿') || desc.contains('民宿')) {
            category = '特色民宿';
          } else if (name.contains('客棧') || name.contains('青旅') || name.contains('背包客')) {
            category = '背包客棧';
          }
          if (name.contains('寵物') || desc.contains('寵物')) {
            category = '寵物友善';
          }

          List<String> tags = [];
          String parking = data['ParkingInfo']?.toString() ?? '';
          if (parking.contains('小客車') && !parking.contains('小客車0輛')) {
            tags.add('附停車場');
          }
          if (starVal >= 4.5) tags.add('高評價');
          if (category == '合法飯店') tags.add('商務出差');
          if (tags.length > 3) tags = tags.sublist(0, 3);

          List<HotelComment> comments = [];
          String commentStr = data['Comments']?.toString().trim() ?? '';
          if (commentStr.isNotEmpty && commentStr != '沒有') {
            for (var s in commentStr.split('\n---\n')) {
              if (s.trim().isNotEmpty) {
                comments.add(HotelComment(userName: 'Google 網友', text: s.trim(), date: '近期', stars: starVal > 0 ? starVal : 5.0, isMe: false));
              }
            }
          }

          addressToHotelMap[address] = HotelModel(
            name: name,
            desc: desc,
            address: address,
            phone: phone,
            price: parsedPrice,
            rating: ratingStr,
            tags: tags,
            images: imageUrls,
            imageBase64: base64, // ✨ 塞入 Model 中
            facilities: const [],
            rooms: const [],
            comments: comments,
            category: category,
            checkTimeInfo: timeInfo,
            websiteUrl: webUrl,
          );

        } catch (e) {
          debugPrint('解析單筆資料失敗: $e');
        }
      }

      List<HotelModel> parsedList = addressToHotelMap.values.toList();

      // ✨ 修改排序規則，把 imageBase64 也考慮進去
      parsedList.sort((a, b) {
        bool aHasImg = a.images.isNotEmpty || a.imageBase64.isNotEmpty;
        bool bHasImg = b.images.isNotEmpty || b.imageBase64.isNotEmpty;

        if (aHasImg && !bHasImg) return -1;
        if (!aHasImg && bHasImg) return 1;

        // 字數越多的排越前面
        return b.desc.length.compareTo(a.desc.length);
      });

      return parsedList;
    } catch (e) {
      debugPrint('資料抓取失敗: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: FutureBuilder<List<HotelModel>>(
            future: _hotelsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Column(
                  children: [
                    _buildHeader(context),
                    const Expanded(child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)))),
                  ],
                );
              }

              if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
                return Column(
                  children: [
                    _buildHeader(context),
                    const Expanded(child: Center(child: Text("目前沒有任何住宿資料", style: TextStyle(color: Colors.grey)))),
                  ],
                );
              }

              List<HotelModel> allHotels = snapshot.data!;
              String query = _searchCtrl.text.trim().toLowerCase();
              String targetCat = _cats[_catIndex].$2;

              List<HotelModel> filteredHotels = allHotels.where((h) {
                bool matchCat = _catIndex == 0 || h.category == targetCat;
                bool matchSearch = query.isEmpty || h.name.toLowerCase().contains(query) || h.address.toLowerCase().contains(query);
                return matchCat && matchSearch;
              }).toList();

              // 取排序後的前 5 名作為熱門精選 (因為已經嚴格字數排序，這裡保證是最豐富的資料)
              List<HotelModel> featuredHotels = allHotels.take(5).toList();

              return CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader(context)),
                  SliverToBoxAdapter(child: _buildSearchBar()),
                  SliverToBoxAdapter(child: _buildCategoryIcons()),

                  if (_searchCtrl.text.isEmpty && _catIndex == 0) ...[
                    SliverToBoxAdapter(child: _buildSectionTitle('熱門精選')),
                    SliverToBoxAdapter(child: _buildFeaturedSection(featuredHotels)),
                  ],

                  SliverToBoxAdapter(child: _buildSectionTitle('靠近您的優質住宿')),

                  if (filteredHotels.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: Text('找不到符合條件的住宿 😢', style: TextStyle(color: Colors.grey, fontSize: 16))),
                      ),
                    )
                  else
                    SliverList(
                        delegate: SliverChildBuilderDelegate(
                                (ctx, i) => _HotelCard(
                              hotel: filteredHotels[i],
                              onReturn: () => setState((){}),
                            ),
                            childCount: filteredHotels.length
                        )
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              );
            }
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
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
                  Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
                  Text('STAYS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
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
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bed_rounded, size: 14, color: Color(0xFF8BAA88)),
                    SizedBox(width: 6),
                    Text('住宿資訊', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
        child: Container(
            height: 52,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)]),
            child: Row(
                children: [
                  const SizedBox(width: 18),
                  const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() {}),
                          onSubmitted: (v) { FocusScope.of(context).unfocus(); setState(() {}); },
                          decoration: const InputDecoration(hintText: '搜尋飯店名稱或地址...', border: InputBorder.none, hintStyle: TextStyle(color: Color(0xFF9E9182), fontSize: 14))
                      )
                  ),
                  if (_searchCtrl.text.isNotEmpty)
                    IconButton(icon: const Icon(Icons.cancel_rounded, color: Colors.grey, size: 18), onPressed: () { _searchCtrl.clear(); setState(() {}); }),
                  GestureDetector(
                    onTap: () { FocusScope.of(context).unfocus(); setState(() {}); },
                    child: const Padding(padding: EdgeInsets.all(6), child: CircleAvatar(backgroundColor: Color(0xFF8BAA88), radius: 20, child: Icon(Icons.search, color: Colors.white, size: 18))),
                  )
                ]
            )
        )
    );
  }

  Widget _buildCategoryIcons() {
    return SizedBox(height: 100, child: ListView.builder(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20), itemCount: _cats.length, itemBuilder: (ctx, i) {
      final sel = i == _catIndex;
      return GestureDetector(onTap: () => setState(() => _catIndex = i), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(children: [
        AnimatedContainer(duration: const Duration(milliseconds: 250), width: 56, height: 56, decoration: BoxDecoration(color: sel ? const Color(0xFF8BAA88) : Colors.white, shape: BoxShape.circle, boxShadow: sel ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))] : null), child: Icon(_cats[i].$1, color: sel ? Colors.white : const Color(0xFF8BAA88), size: 24)),
        const SizedBox(height: 8),
        Text(_cats[i].$2, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
      ])));
    }));
  }

  Widget _buildFeaturedSection(List<HotelModel> hotels) {
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: hotels.length,
        itemBuilder: (ctx, i) => GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (ctx) => HotelDetailScreen(hotel: hotels[i]))).then((_) => setState((){})),
          child: Container(
            width: 300,
            margin: const EdgeInsets.only(right: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ✨ 使用 buildSmartImage 支援 Base64 + URL
                  buildSmartImage(
                    imageUrl: hotels[i].images.isNotEmpty ? hotels[i].images[0] : null,
                    imageBase64: hotels[i].imageBase64,
                    fit: BoxFit.cover,
                  ),
                  Container(
                    decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.6)])
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(hotels[i].name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            const Icon(Icons.location_on_rounded, color: Colors.white70, size: 12),
                            const SizedBox(width: 4),
                            Expanded(child: Text(hotels[i].address, style: const TextStyle(color: Colors.white70, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis))
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HotelCard extends StatefulWidget {
  final HotelModel hotel;
  final VoidCallback onReturn;
  const _HotelCard({required this.hotel, required this.onReturn});
  @override
  State<_HotelCard> createState() => _HotelCardState();
}

class _HotelCardState extends State<_HotelCard> {
  final Map<String, Color> _tagColors = {
    '五星級': const Color(0xFFE57373), '高評價': const Color(0xFFFBC02D), '附停車場': const Color(0xFF8BAA88),
    '設計感': const Color(0xFF03A9F4), '商務出差': const Color(0xFF7D6E5D), '老屋改建': const Color(0xFF9C27B0),
  };
  Color _getTagColor(String tag) => _tagColors[tag] ?? const Color(0xFF8BAA88);

  void _toggleFav() async {
    await FavoriteManager.toggleFavorite(widget.hotel.name, '住宿資訊');
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedNames.contains(widget.hotel.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isFav ? '❤️ 已將 ${widget.hotel.name} 儲存至雲端收藏！' : '🗑️ 已取消收藏'),
        backgroundColor: isFav ? const Color(0xFFE57373) : const Color(0xFF9E9182),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isFav = FavoriteManager.savedNames.contains(widget.hotel.name);

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (ctx) => HotelDetailScreen(hotel: widget.hotel))).then((_) => widget.onReturn()),
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.1)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)]),
        child: Row(
          children: [
            ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
                // ✨ 使用 buildSmartImage 支援 Base64 + URL
                child: buildSmartImage(
                  imageUrl: widget.hotel.images.isNotEmpty ? widget.hotel.images[0] : null,
                  imageBase64: widget.hotel.imageBase64,
                  width: 110, height: 130, fit: BoxFit.cover,
                )
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(widget.hotel.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        GestureDetector(
                          onTap: _toggleFav,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(color: isFav ? const Color(0xFFE57373).withOpacity(0.1) : const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle),
                            child: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? const Color(0xFFE57373) : const Color(0xFF8BAA88), size: 16),
                          ),
                        ),
                      ],
                    ),
                    if (widget.hotel.desc.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(widget.hotel.desc, style: TextStyle(fontSize: 11, color: const Color(0xFF7D6E5D).withOpacity(0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                    if (widget.hotel.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: widget.hotel.tags.map((t) {
                          Color tagC = _getTagColor(t);
                          return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: tagC.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                              child: Text(t, style: TextStyle(color: tagC, fontSize: 9, fontWeight: FontWeight.bold))
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (widget.hotel.rating.isNotEmpty) ...[
                          const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 14),
                          Text(widget.hotel.rating, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF7D6E5D))),
                        ],
                        const Spacer(),
                        if (widget.hotel.price > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xFF7D6E5D).withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF7D6E5D).withOpacity(0.2), width: 1.5)),
                            child: Text('NT\$ ${widget.hotel.price}起', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), fontFamily: 'MyCustomFont')),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HotelDetailScreen extends StatefulWidget {
  final HotelModel hotel;
  const HotelDetailScreen({super.key, required this.hotel});
  @override
  State<HotelDetailScreen> createState() => _HotelDetailScreenState();
}

class _HotelDetailScreenState extends State<HotelDetailScreen> {
  int _currImg = 0;
  final TextEditingController _commentCtrl = TextEditingController();
  double _userRating = 5.0;
  bool _isPosting = false;

  // ★ Firestore 路徑：Hotels/{hotelDocId}/comments
  CollectionReference get _commentsRef => FirebaseFirestore.instance
      .collection('Hotels')
      .doc(_hotelDocId)
      .collection('comments');

  // 用 hotelName hashCode 當穩定 doc id
  String get _hotelDocId => widget.hotel.name.hashCode.abs().toString();

  final Map<String, Color> _tagColors = {
    '五星級': const Color(0xFFE57373), '高評價': const Color(0xFFFBC02D), '附停車場': const Color(0xFF8BAA88),
    '設計感': const Color(0xFF03A9F4), '商務出差': const Color(0xFF7D6E5D), '老屋改建': const Color(0xFF9C27B0),
  };

  @override
  void initState() { super.initState(); }

  @override
  void dispose() { _commentCtrl.dispose(); super.dispose(); }

  // ── 取得登入使用者頭像 Base64 ─────────────────────────────────
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
        'stars':        _userRating,
        'avatarBase64': avatarBase64 ?? '',
        'createdAt':    FieldValue.serverTimestamp(),
      });
      _commentCtrl.clear();
      if (mounted) setState(() { _userRating = 5.0; _isPosting = false; });
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

  void _toggleFav() async {
    await FavoriteManager.toggleFavorite(widget.hotel.name, '住宿資訊');
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      bool isFav = FavoriteManager.savedNames.contains(widget.hotel.name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isFav ? '❤️ 已將 ${widget.hotel.name} 儲存至雲端收藏！' : '🗑️ 已取消收藏'),
        backgroundColor: isFav ? const Color(0xFFE57373) : const Color(0xFF9E9182),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isFav = FavoriteManager.savedNames.contains(widget.hotel.name);

    // ✨ 如果 Images 和 Base64 都沒有，算 1 張圖(預設圖)，否則用陣列長度
    int imgCount = widget.hotel.images.isNotEmpty ? widget.hotel.images.length : 1;

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: Stack(children: [
        CustomScrollView(physics: const BouncingScrollPhysics(), slivers: [
          SliverAppBar(
            expandedHeight: 400.0, pinned: true,
            backgroundColor: const Color(0xFFF9F8F4),
            leading: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: GestureDetector(onTap: () => Navigator.pop(context), child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.white.withOpacity(0.25), shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.4))), child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18)))),
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
                            decoration: BoxDecoration(color: isFav ? Colors.white : Colors.white.withOpacity(0.25), shape: BoxShape.circle, border: Border.all(color: isFav ? const Color(0xFFE57373) : Colors.white.withOpacity(0.4))),
                            child: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? const Color(0xFFE57373) : Colors.white, size: 22)
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(background: Stack(fit: StackFit.expand, children: [
              PageView.builder(
                  onPageChanged: (v) => setState(() => _currImg = v),
                  itemCount: imgCount,
                  // ✨ 使用 buildSmartImage 支援 Base64 + URL
                  itemBuilder: (ctx, i) => buildSmartImage(
                      imageUrl: widget.hotel.images.isNotEmpty ? widget.hotel.images[i] : null,
                      imageBase64: widget.hotel.imageBase64,
                      fit: BoxFit.cover
                  )
              ),
              Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, const Color(0xFFF9F8F4)], stops: const [0.6, 1.0]))),
              if (imgCount > 1)
                Positioned(bottom: 50, left: 0, right: 0, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(imgCount, (i) => AnimatedContainer(duration: const Duration(milliseconds: 300), margin: const EdgeInsets.all(3), width: _currImg == i ? 18 : 6, height: 6, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: _currImg == i ? const Color(0xFF8BAA88) : Colors.white60))))),
            ])),
          ),
          SliverToBoxAdapter(child: Transform.translate(offset: const Offset(0, -30), child: Container(decoration: const BoxDecoration(color: Color(0xFFF9F8F4), borderRadius: BorderRadius.vertical(top: Radius.circular(30))), padding: const EdgeInsets.fromLTRB(24, 30, 24, 150), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(widget.hotel.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)))),
              if (widget.hotel.rating.isNotEmpty)
                _ratingCapsule(widget.hotel.rating),
            ]),

            if (widget.hotel.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: widget.hotel.tags.map((t) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: (_tagColors[t] ?? const Color(0xFF8BAA88)).withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Text(t, style: TextStyle(color: _tagColors[t] ?? const Color(0xFF8BAA88), fontSize: 11, fontWeight: FontWeight.w800)))).toList()),
            ],

            const SizedBox(height: 20),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.location_on_rounded, color: Color(0xFF8BAA88), size: 16), const SizedBox(width: 8), Expanded(child: Text(widget.hotel.address, style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.5, fontWeight: FontWeight.bold)))]),

            if (widget.hotel.phone.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(children: [const Icon(Icons.phone_rounded, color: Color(0xFF8BAA88), size: 16), const SizedBox(width: 8), Text(widget.hotel.phone, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 15, fontWeight: FontWeight.w900))]),
            ],

            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.access_time_rounded, color: Color(0xFF8BAA88), size: 16), const SizedBox(width: 8), Expanded(child: Text(widget.hotel.checkTimeInfo, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 13, height: 1.5, fontWeight: FontWeight.bold)))]),

            const SizedBox(height: 24),
            Row(children: [
              _actionBtn(Icons.navigation_rounded, '導航', onTap: (){
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('導航功能即將推出')));
              }),
              const SizedBox(width: 12),

              _actionBtn(Icons.phone_rounded, '電話撥打', onTap: () async {
                String phone = widget.hotel.phone;
                if (phone.isEmpty || phone == '沒有提供') {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無提供電話')));
                  return;
                }
                final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
                final Uri url = Uri.parse('tel:$cleanPhone');
                try {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無法跳轉撥號畫面')));
                }
              }),
              const SizedBox(width: 12),

              _actionBtn(Icons.language_rounded, '網站', onTap: () async {
                String web = widget.hotel.websiteUrl;
                if (web.isEmpty || web == '沒有') {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無提供網站')));
                  return;
                }
                if (!web.startsWith('http')) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('網址格式無效')));
                  return;
                }
                try {
                  final Uri url = Uri.parse(web);
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('網頁跳轉失敗')));
                }
              }),
            ]),

            if (widget.hotel.desc.isNotEmpty) ...[
              const SizedBox(height: 32),
              const Text('住宿簡介', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 12),
              Text(widget.hotel.desc, style: const TextStyle(color: Color(0xFF7D6E5D), fontSize: 14, height: 1.8)),
            ],

            const SizedBox(height: 40),
            const Text('網友留言', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 16),
            _buildInteractiveInput(),
            const SizedBox(height: 24),
            _buildCommentList(),
          ]))))
        ]),
        Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 32), decoration: BoxDecoration(color: Colors.white.withOpacity(0.98), borderRadius: const BorderRadius.vertical(top: Radius.circular(32)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, -5))]), child: ElevatedButton(onPressed: () {}, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: const Color(0xFF8BAA88), elevation: 5, shadowColor: const Color(0xFF8BAA88).withOpacity(0.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))), child: Text(widget.hotel.price > 0 ? '立刻預約 ─ NT\$ ${widget.hotel.price}起' : '立刻預約', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))))),
      ]),
    );
  }

  Widget _ratingCapsule(String r) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.12), borderRadius: BorderRadius.circular(20)), child: Row(children: [const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 16), const SizedBox(width: 4), Text(r, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF7D6E5D)))]));
  }

  Widget _actionBtn(IconData icon, String label, {VoidCallback? onTap}) {
    return Expanded(
        child: GestureDetector(
            onTap: onTap,
            child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 16, color: const Color(0xFF8BAA88)),
                      const SizedBox(width: 6),
                      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)
                    ]
                )
            )
        )
    );
  }

  Widget _buildInteractiveInput() {
    final user = FirebaseAuth.instance.currentUser;
    final isGuest = user == null;

    // 訪客顯示提示，不顯示輸入框
    if (isGuest) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF8BAA88).withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded, color: Color(0xFF8BAA88), size: 18),
            SizedBox(width: 8),
            Text('請先登入才能留言', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 14)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.grey.withOpacity(0.2))),
      child: Column(
        children: [
          // 評分列
          Row(
            children: [
              const Text('點擊評分：', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
              ...List.generate(5, (i) => GestureDetector(
                  onTap: () => setState(() => _userRating = i + 1.0),
                  child: Icon(i < _userRating ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFF8BAA88), size: 24)
              )),
            ],
          ),
          const Divider(height: 20),
          // 輸入列
          Row(
            children: [
              // ★ 顯示帳號頭像（讀 avatarBase64 或 photoURL，fallback 用首字母）
              _buildMyAvatar(user),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _commentCtrl,
                  decoration: const InputDecoration(
                    hintText: '說點什麼吧...',
                    border: InputBorder.none,
                    hintStyle: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Colors.grey),
                  ),
                ),
              ),
              _isPosting
                  ? const SizedBox(width: 36, height: 36,
                  child: Padding(padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8BAA88))))
                  : GestureDetector(
                onTap: _postComment,
                child: Container(padding: const EdgeInsets.all(10), decoration: const BoxDecoration(color: Color(0xFF8BAA88), shape: BoxShape.circle), child: const Icon(Icons.send_rounded, color: Colors.white, size: 16)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 我的頭像 widget ───────────────────────────────────────────
  Widget _buildMyAvatar(User user) {
    // ★ 優先從 Firestore 讀取自訂頭像（avatarBase64）
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final avatarB64 = (data is Map) ? (data as Map<String,dynamic>)['avatarBase64']?.toString() ?? '' : '';
        if (avatarB64.isNotEmpty) {
          try {
            final bytes = base64Decode(avatarB64);
            return CircleAvatar(radius: 18, backgroundImage: MemoryImage(bytes));
          } catch (_) {}
        }
        // fallback：首字母
        final initial = (user.displayName?.isNotEmpty == true)
            ? user.displayName![0].toUpperCase()
            : (user.email?.isNotEmpty == true ? user.email![0].toUpperCase() : '?');
        return CircleAvatar(
          radius: 18,
          backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
          child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 14)),
        );
      },
    );
  }

  Widget _buildCommentList() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return StreamBuilder<QuerySnapshot>(
      stream: _commentsRef.orderBy('createdAt', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88), strokeWidth: 2)),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(child: Text('載入留言失敗', style: TextStyle(color: Colors.grey[400], fontFamily: 'MyCustomFont'))),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text('目前尚無留言，趕快留下第一筆評價吧！',
                  style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 14)),
            ),
          );
        }

        return Column(
          children: docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final uid      = data['uid']?.toString() ?? '';
            final userName = data['userName']?.toString() ?? '匿名旅人';
            final text     = data['text']?.toString() ?? '';
            final stars    = (data['stars'] as num?)?.toDouble() ?? 5.0;
            final avatarB64 = data['avatarBase64']?.toString() ?? '';
            final isMe     = uid.isNotEmpty && uid == myUid;

            // 格式化時間
            String dateLabel = '';
            final ts = data['createdAt'];
            if (ts is Timestamp) {
              final dt = ts.toDate();
              final now = DateTime.now();
              final diff = now.difference(dt);
              if (diff.inMinutes < 1) dateLabel = '剛剛';
              else if (diff.inHours < 1) dateLabel = '${diff.inMinutes} 分鐘前';
              else if (diff.inDays < 1) dateLabel = '${diff.inHours} 小時前';
              else dateLabel = '${dt.year}/${dt.month}/${dt.day}';
            }

            // 頭像 widget
            Widget avatarWidget;
            if (avatarB64.isNotEmpty) {
              try {
                final bytes = base64Decode(avatarB64);
                avatarWidget = CircleAvatar(radius: 20, backgroundImage: MemoryImage(bytes));
              } catch (_) {
                avatarWidget = _defaultAvatar(userName);
              }
            } else {
              avatarWidget = _defaultAvatar(userName);
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatarWidget,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(userName,
                                style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF7D6E5D)))),
                            Text(dateLabel,
                                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                            if (isMe) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => _deleteComment(doc.id),
                                child: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFB07070)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(children: List.generate(5, (i) => Icon(
                            i < stars ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: const Color(0xFF8BAA88), size: 13))),
                        const SizedBox(height: 6),
                        Text(text, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.5)),
                        const SizedBox(height: 12),
                        Container(height: 1, color: const Color(0xFF8BAA88).withOpacity(0.1)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _defaultAvatar(String name) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xFF8BAA88).withOpacity(0.15),
      child: Text(initial, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 14)),
    );
  }
}