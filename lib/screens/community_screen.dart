// ═══════════════════════════════════════════════════════════════
//  community_screen.dart  (Firebase 版)
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_screen.dart';
import 'community_post_service.dart';
import 'cover_screen.dart';
import 'app_state.dart';
import 'profile_screen.dart' show UserLogsPage;
import 'login_screen.dart';
import 'home_screen.dart' show UserAvatar;
import 'system_settings_screen.dart';
import 'help_support_screen.dart';

// ── 共用圖片與頭貼渲染工具 ──────────────────────────────────────

Widget buildPostImage(String url, {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  if (url.startsWith('http')) {
    return Image.network(url, width: width, height: height, fit: fit, errorBuilder: (_, __, ___) => _errorContainer(width, height));
  } else if (url.length > 100) {
    try {
      final cleanBase64 = url.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
      return Image.memory(base64Decode(cleanBase64), width: width, height: height, fit: fit, errorBuilder: (_, __, ___) => _errorContainer(width, height));
    } catch (_) {
      return _errorContainer(width, height);
    }
  }
  return _errorContainer(width, height);
}

Widget _errorContainer(double? width, double? height) {
  return Container(width: width ?? double.infinity, height: height ?? 140, color: Colors.grey[100], child: const Icon(Icons.image_not_supported_rounded, color: Colors.grey));
}

Widget buildAvatar(String avatarData, {double radius = 14}) {
  if (avatarData.startsWith('http')) {
    return CircleAvatar(radius: radius, backgroundImage: NetworkImage(avatarData), backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2));
  } else if (avatarData.length > 100) {
    try {
      final cleanBase64 = avatarData.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(base64Decode(cleanBase64)), backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2));
    } catch (_) {
      return CircleAvatar(radius: radius, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2), child: Text('🦃', style: TextStyle(fontSize: radius)));
    }
  } else {
    return CircleAvatar(radius: radius, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2), child: Text(avatarData.isEmpty ? '🦃' : avatarData, style: TextStyle(fontSize: radius, color: const Color(0xFF7D6E5D))));
  }
}

// 🌟 將側邊欄頭像與 _UserAvatar 元件結合，確保同步無延遲
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
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: const Color(0xFF8BAA88),
        child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)),
      );
    }

    if (_cloudAvatarBytes != null) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: const Color(0xFF8BAA88),
        backgroundImage: MemoryImage(_cloudAvatarBytes!),
      );
    }

    if (widget.user?.photoURL != null && widget.user!.photoURL!.isNotEmpty) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: const Color(0xFF8BAA88),
        backgroundImage: NetworkImage(widget.user!.photoURL!),
      );
    }

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF8BAA88),
      child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  主社群牆頁面
// ══════════════════════════════════════════════════════════════
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen>
    with TickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  int _tabIndex = 0;
  final List<String> _tabs = ['全部', '景點', '美食', '住宿', '行程', '其他'];
  final TextEditingController _searchController = TextEditingController();

  bool _isFabMenuOpen = false;
  late AnimationController _menuAnimationController;
  late Animation<double> _menuFadeAnimation;

  List<CommunityPost> _posts = [];
  bool _isLoading = true;
  bool _hasError = false;

  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _menuAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _menuFadeAnimation = CurvedAnimation(
      parent: _menuAnimationController,
      curve: Curves.easeInOut,
    );
    _loadPosts();
  }

  @override
  void dispose() {
    _menuAnimationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPosts({String? typeFilter}) async {
    setState(() { _isLoading = true; _hasError = false; });
    try {
      final posts = await CommunityPostService.instance.fetchPosts();
      if (mounted) setState(() { _posts = posts; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
    }
  }

  void _toggleFabMenu() {
    setState(() {
      _isFabMenuOpen = !_isFabMenuOpen;
      if (_isFabMenuOpen) {
        _menuAnimationController.forward();
      } else {
        _menuAnimationController.reverse();
      }
    });
  }

  void _navigateToCreatePost(String type) async {
    if (_currentUid == null) {
      _toggleFabMenu();
      _showLoginRequiredSnackBar();
      return;
    }

    _toggleFabMenu();

    final result = await Navigator.push<CommunityPost>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(postType: type),
      ),
    );

    if (result != null && mounted) {
      setState(() => _posts.insert(0, result));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('🎉 貼文成功發布至社群分享牆！',
                style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
          ]),
          backgroundColor: const Color(0xFF8BAA88),
        ),
      );
    }
  }

  void _showLoginRequiredSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('請先登入才能發布貼文喔！',
            style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
        backgroundColor: Color(0xFF7D6E5D),
      ),
    );
  }

  void _showOwnerOptions(CommunityPost post) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFDFCF5),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Color(0xFF7D6E5D)),
              title: const Text('編輯貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
              onTap: () async {
                Navigator.pop(context);
                final updated = await Navigator.push<CommunityPost>(
                  context,
                  MaterialPageRoute(builder: (_) => EditPostScreen(post: post)),
                );
                if (updated != null && mounted) {
                  setState(() {
                    final idx = _posts.indexWhere((p) => p.id == updated.id);
                    if (idx != -1) _posts[idx] = updated;
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: const Color(0xFFB07070)),
              title: const Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFB07070), fontWeight: FontWeight.bold)),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFFFDFCF5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    title: const Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                    content: const Text('確定要刪除這則貼文嗎？', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('確認刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFB07070), fontWeight: FontWeight.bold))),
                    ],
                  ),
                );
                if (confirm == true) {
                  final ok = await CommunityPostService.instance.deletePost(post.id);
                  if (ok && mounted) {
                    setState(() => _posts.removeWhere((p) => p.id == post.id));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('貼文已刪除', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF7D6E5D)),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showZoomedImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(color: Colors.black.withOpacity(0.4)),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: buildPostImage(imageUrl, fit: BoxFit.contain),
                ),
              ),
            ),
            const Positioned(
              top: 40, right: 24,
              child: Icon(Icons.close_rounded, color: Colors.white, size: 30),
            ),
          ],
        ),
      ),
    );
  }

  void _onTabChanged(int index) {
    setState(() => _tabIndex = index);
  }

  List<CommunityPost> get _filteredPosts {
    List<CommunityPost> base = _posts;
    if (_tabIndex > 0) {
      final typeFilter = _tabs[_tabIndex];
      base = base.where((p) => p.type == typeFilter).toList();
    }
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((p) =>
    p.content.toLowerCase().contains(q) ||
        p.authorName.toLowerCase().contains(q) ||
        (p.locationName?.toLowerCase().contains(q) ?? false)
    ).toList();
  }

  // 🌟 把這段單獨新增到 _CommunityScreenState 裡面即可
  // 側邊欄直接沿用 profile_screen.dart 的 _HomeTxtStyleDrawer
  Widget _buildAppDrawer() => const _HomeTxtStyleDrawer();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      drawer: const _HomeTxtStyleDrawer(),
      body: GestureDetector(
        onTap: () {
          if (_isFabMenuOpen) setState(() => _isFabMenuOpen = false);
        },
        child: Stack(
          children: [
            CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildInlineSpecialHeader(context)),
                SliverToBoxAdapter(child: _buildSearchBarSection()),
                SliverToBoxAdapter(child: _buildFilterTabsSection()),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  sliver: SliverToBoxAdapter(child: _buildBody(context)),
                ),
              ],
            ),
            if (_isFabMenuOpen) _buildScreenshotStyleOverlay(),
            Positioned(
              bottom: 24, right: 20,
              child: GestureDetector(
                onTap: _toggleFabMenu,
                child: AnimatedRotation(
                  duration: const Duration(milliseconds: 250),
                  turns: _isFabMenuOpen ? 0.375 : 0,
                  child: Container(
                    width: 56, height: 56,
                    decoration: const BoxDecoration(
                      color: Color(0xFF8BAA88),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Color(0x338BAA88), blurRadius: 12, offset: Offset(0, 4))],
                    ),
                    child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 300,
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF8BAA88)),
        ),
      );
    }
    if (_hasError) {
      return SizedBox(
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 48, color: Color(0xFF8BAA88)),
              const SizedBox(height: 12),
              const Text('載入失敗，請檢查網路', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _loadPosts(),
                child: const Text('重新載入', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
    }

    final posts = _filteredPosts;

    if (posts.isEmpty) {
      return SizedBox(
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🌿', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              const Text('目前還沒有分享，來第一個發文吧！',
                  style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    }

    return _buildWaterfallGrid(context, posts);
  }

  Widget _buildScreenshotStyleOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: _toggleFabMenu,
            child: Container(color: Colors.transparent),
          ),
          Positioned(
            bottom: 92, right: 20,
            child: FadeTransition(
              opacity: _menuFadeAnimation,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildStaggeredMenuButton(text: '分享景點', icon: Icons.landscape_rounded, delayIndex: 3, onTap: () => _navigateToCreatePost('景點')),
                  const SizedBox(height: 10),
                  _buildStaggeredMenuButton(text: '分享美食', icon: Icons.restaurant_rounded, delayIndex: 2, onTap: () => _navigateToCreatePost('美食')),
                  const SizedBox(height: 10),
                  _buildStaggeredMenuButton(text: '分享住宿', icon: Icons.hotel_rounded, delayIndex: 1, onTap: () => _navigateToCreatePost('住宿')),
                  const SizedBox(height: 10),
                  _buildStaggeredMenuButton(text: '其他分享', icon: Icons.edit_calendar_rounded, delayIndex: 0, onTap: () => _navigateToCreatePost('其他')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStaggeredMenuButton({
    required String text,
    required IconData icon,
    required int delayIndex,
    required VoidCallback onTap,
  }) {
    final slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _menuAnimationController,
      curve: Interval((4 - delayIndex) * 0.1, 1.0, curve: Curves.easeOutBack),
    ));

    return SlideTransition(
      position: slideAnimation,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF7D6E5D),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Text(text, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            ],
          ),
        ),
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
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            icon: const Icon(Icons.menu_rounded, size: 32, color: Color(0xFF7D6E5D)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  overflow: TextOverflow.ellipsis,
                  text: const TextSpan(
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    children: [
                      TextSpan(text: 'MY ', style: TextStyle(color: Color(0xFF7D6E5D))),
                      TextSpan(text: 'COMMUNITY', style: TextStyle(color: Color(0xFF8BAA88))),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8BAA88).withOpacity(0.06),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.35), width: 1.2),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.favorite_rounded, size: 13, color: Color(0xFF8BAA88)),
                      SizedBox(width: 6),
                      Text('社群分享牆', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _loadPosts(),
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF8BAA88), size: 24),
            tooltip: '重新整理',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBarSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
          decoration: const InputDecoration(
            hintText: '搜尋景點、美食、住宿...',
            hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTabsSection() {
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _tabs.length,
        itemBuilder: (context, i) {
          final isSel = i == _tabIndex;
          return GestureDetector(
            onTap: () => _onTabChanged(i),
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
                  if (isSel)
                    BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 3))
                  else
                    BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4, offset: const Offset(0, 2)),
                ],
              ),
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: isSel ? Colors.white : const Color(0xFF7D6E5D),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWaterfallGrid(BuildContext context, List<CommunityPost> posts) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildWaterfallColumn(0, posts, context)),
        const SizedBox(width: 12),
        Expanded(child: _buildWaterfallColumn(1, posts, context)),
      ],
    );
  }

  Widget _buildWaterfallColumn(int colIndex, List<CommunityPost> posts, BuildContext context) {
    final colItems = List.generate(posts.length, (i) => i).where((i) => i % 2 == colIndex).toList();
    return Column(
      children: colItems.map((i) => _SuspendedCardWrapper(
        index: i,
        child: _buildPostCard(i, posts[i], context),
      )).toList(),
    );
  }

  Widget _buildPostCard(int index, CommunityPost post, BuildContext context) {
    Color tagThemeColor = const Color(0xFF8BAA88);
    if (post.type == '美食') tagThemeColor = const Color(0xFFB09070);
    else if (post.type == '住宿') tagThemeColor = const Color(0xFF7FA3B0);
    else if (post.type == '行程') tagThemeColor = const Color(0xFF8B9EB5);

    final isMyPost = _currentUid != null && post.authorUid == _currentUid;

    return GestureDetector(
      onTap: () async {
        final updated = await Navigator.push<CommunityPost>(
          context,
          MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
        );
        if (updated != null && mounted) {
          setState(() {
            final idx = _posts.indexWhere((p) => p.id == updated.id);
            if (idx != -1) _posts[idx] = updated;
            if (updated.id.isEmpty) _posts.removeWhere((p) => p.id == post.id);
          });
        }
      },
      onLongPress: isMyPost ? () => _showOwnerOptions(post) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 14, offset: const Offset(0, 6)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (post.imageUrl.isNotEmpty)
              GestureDetector(
                onTap: () => _showZoomedImage(context, post.imageUrl),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  // 🌟 [修復點] 加入 width: double.infinity 確保圖片寬度填滿，不再留白
                  child: buildPostImage(post.imageUrl, width: double.infinity, height: 140 + (index % 3) * 40.0),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: tagThemeColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                        child: Text(post.type, style: TextStyle(fontFamily: 'MyCustomFont', color: tagThemeColor, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                      const Spacer(),
                      if (isMyPost)
                        GestureDetector(
                          onTap: () => _showOwnerOptions(post),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(Icons.more_horiz_rounded, color: Colors.grey[400], size: 18),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    post.content,
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF7D6E5D), height: 1.4),
                    maxLines: 3, overflow: TextOverflow.ellipsis,
                  ),
                  if (post.locationName != null && post.locationName!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.location_on_rounded, size: 12, color: Color(0xFF8BAA88)),
                      const SizedBox(width: 2),
                      Expanded(child: Text(post.locationName!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8BAA88)), overflow: TextOverflow.ellipsis)),
                    ]),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      // 頭像固定寬度
                      buildAvatar(post.authorAvatar, radius: 11),
                      const SizedBox(width: 4),
                      // 作者名：佔滿剩餘空間，過長自動截斷
                      Expanded(
                        child: Text(
                          post.authorName,
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      // 行程按鈕（只有行程類型才顯示）
                      if (post.type == '行程' && post.itineraryId != null) ...[
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _onAddToMyItinerary(post),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7FA3B0).withOpacity(0.10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '+ 行程',
                              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, color: Color(0xFF7FA3B0), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                      // 固定寬度的 icon 群，不會 overflow
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => showCommentsBottomSheet(context, post.id),
                        child: const Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF8B9EB5), size: 15),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _onLikeTap(post),
                        child: Icon(
                          post.isLikedByMe ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                          color: const Color(0xFF8BAA88), size: 15,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Text('${post.likesCount}', style: const TextStyle(fontSize: 10, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _onFavoriteTap(post),
                        child: Icon(
                          post.isFavoriteByMe ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                          color: const Color(0xFF7FA3B0), size: 15,
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

  void _onLikeTap(CommunityPost post) async {
    if (_currentUid == null) { _showLoginRequiredSnackBar(); return; }

    final newCount = await CommunityPostService.instance.toggleLike(
      post.id, post.isLikedByMe, post.likesCount,
    );
    if (mounted) {
      setState(() {
        final idx = _posts.indexWhere((p) => p.id == post.id);
        if (idx != -1) {
          _posts[idx] = _posts[idx].copyWith(
            isLikedByMe: !post.isLikedByMe,
            likesCount: newCount,
          );
        }
      });
    }
  }

  void _onFavoriteTap(CommunityPost post) async {
    if (_currentUid == null) { _showLoginRequiredSnackBar(); return; }

    await CommunityPostService.instance.toggleFavorite(post.id, post.isFavoriteByMe);
    if (mounted) {
      setState(() {
        final idx = _posts.indexWhere((p) => p.id == post.id);
        if (idx != -1) {
          _posts[idx] = _posts[idx].copyWith(isFavoriteByMe: !post.isFavoriteByMe);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            Icon(post.isFavoriteByMe ? Icons.bookmark_border_rounded : Icons.bookmark_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(post.isFavoriteByMe ? '已取消收藏' : '已加入收藏貼文',
                style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
          ]),
          backgroundColor: const Color(0xFF8BAA88),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _onAddToMyItinerary(CommunityPost post) async {
    if (_currentUid == null) { _showLoginRequiredSnackBar(); return; }
    if (post.itineraryId == null && (post.itineraryDayPlans == null || post.itineraryDayPlans!.isEmpty)) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 12),
          Text('正在載入行程資料…', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
        ]),
        backgroundColor: Color(0xFF7FA3B0),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      Map<String, dynamic>? tripMap;

      if (post.itineraryId != null &&
          post.authorUid.isNotEmpty &&
          post.authorUid != 'guest') {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(post.authorUid)
            .collection('itineraries')
            .doc(post.itineraryId)
            .get();

        if (doc.exists) {
          final data = doc.data()!;
          List<dynamic> plans = [];
          try {
            final plansJson = data['plans_json']?.toString() ?? '[]';
            if (plansJson.isNotEmpty) plans = jsonDecode(plansJson) as List<dynamic>;
          } catch (_) {}
          tripMap = {
            'title': '${data['title'] ?? post.itineraryTitle ?? post.itineraryId}（來自社群）',
            'estimatedBudget': data['estimated_budget'] ?? post.itineraryBudget ?? 0,
            'days': plans,
          };
        }
      }

      if (tripMap == null &&
          post.itineraryDayPlans != null &&
          post.itineraryDayPlans!.isNotEmpty) {
        final days = post.itineraryDayPlans!.map((day) => {
          'dayLabel': day.dayLabel,
          'items': day.items.map((item) => {
            'time': item.time,
            'title': item.title,
            'location': item.location,
            'duration': item.duration,
            'lat': 0.0,
            'lon': 0.0,
            'tips': '',
            'ticket': '',
          }).toList(),
        }).toList();
        tripMap = {
          'title': '${post.itineraryTitle ?? '社群行程'}（來自社群）',
          'estimatedBudget': post.itineraryBudget ?? 0,
          'days': days,
        };
      }

      if (!mounted) return;

      if (tripMap == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找不到行程資料，貼文未包含完整行程內容', style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: Color(0xFFD97B2A),
          ),
        );
        return;
      }

      AppStateManager.aiGeneratedTripNotifier.value = tripMap;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('✅ 已加入您的行程！切換到地圖查看', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
          ]),
          backgroundColor: Color(0xFF7FA3B0),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [Community] 載入行程失敗：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('載入行程失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: const Color(0xFFB07070),
          ),
        );
      }
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  貼文詳細頁
// ══════════════════════════════════════════════════════════════
class PostDetailScreen extends StatefulWidget {
  final CommunityPost post;
  const PostDetailScreen({super.key, required this.post});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  late CommunityPost _post;
  bool _isLoading = false;

  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
    _reloadPost();
  }

  Future<void> _reloadPost() async {
    setState(() => _isLoading = true);
    final fresh = await CommunityPostService.instance.fetchPost(_post.id);
    if (fresh != null && mounted) {
      setState(() {
        _post = fresh;
        _isLoading = false;
      });
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _onLikeTap() async {
    if (_currentUid == null) return;
    final newCount = await CommunityPostService.instance.toggleLike(
      _post.id, _post.isLikedByMe, _post.likesCount,
    );
    if (mounted) {
      setState(() => _post = _post.copyWith(isLikedByMe: !_post.isLikedByMe, likesCount: newCount));
    }
  }

  Future<void> _onFavoriteTap() async {
    if (_currentUid == null) return;
    await CommunityPostService.instance.toggleFavorite(_post.id, _post.isFavoriteByMe);
    if (mounted) {
      setState(() => _post = _post.copyWith(isFavoriteByMe: !_post.isFavoriteByMe));
    }
  }

  Color get _tagColor {
    if (_post.type == '美食') return const Color(0xFFB09070);
    if (_post.type == '住宿') return const Color(0xFF7FA3B0);
    if (_post.type == '行程') return const Color(0xFF8B9EB5);
    return const Color(0xFF8BAA88);
  }

  // 🌟 [修補] 補上詳細頁面漏掉的日期格式化工具
  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  // 🌟 [修補] 補上詳細頁面漏掉的加入行程功能
  void _onAddToMyItinerary() async {
    if (_currentUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先登入才能加入行程喔！', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF7D6E5D)),
      );
      return;
    }
    if (_post.itineraryId == null && (_post.itineraryDayPlans == null || _post.itineraryDayPlans!.isEmpty)) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 12),
          Text('正在載入行程資料…', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
        ]),
        backgroundColor: Color(0xFF7FA3B0),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      Map<String, dynamic>? tripMap;

      if (_post.itineraryId != null &&
          _post.authorUid.isNotEmpty &&
          _post.authorUid != 'guest') {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_post.authorUid)
            .collection('itineraries')
            .doc(_post.itineraryId)
            .get();

        if (doc.exists) {
          final data = doc.data()!;
          List<dynamic> plans = [];
          try {
            final plansJson = data['plans_json']?.toString() ?? '[]';
            if (plansJson.isNotEmpty) plans = jsonDecode(plansJson) as List<dynamic>;
          } catch (_) {}
          tripMap = {
            'title': '${data['title'] ?? _post.itineraryTitle ?? _post.itineraryId}（來自社群）',
            'estimatedBudget': data['estimated_budget'] ?? _post.itineraryBudget ?? 0,
            'days': plans,
          };
        }
      }

      if (tripMap == null &&
          _post.itineraryDayPlans != null &&
          _post.itineraryDayPlans!.isNotEmpty) {
        final days = _post.itineraryDayPlans!.map((day) => {
          'dayLabel': day.dayLabel,
          'items': day.items.map((item) => {
            'time': item.time,
            'title': item.title,
            'location': item.location,
            'duration': item.duration,
            'lat': 0.0,
            'lon': 0.0,
            'tips': '',
            'ticket': '',
          }).toList(),
        }).toList();
        tripMap = {
          'title': '${_post.itineraryTitle ?? '社群行程'}（來自社群）',
          'estimatedBudget': _post.itineraryBudget ?? 0,
          'days': days,
        };
      }

      if (!mounted) return;

      if (tripMap == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找不到行程資料，貼文未包含完整行程內容', style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: Color(0xFFD97B2A),
          ),
        );
        return;
      }

      // 觸發全域變數，地圖頁面會自動接收並渲染
      AppStateManager.aiGeneratedTripNotifier.value = tripMap;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('✅ 已加入您的行程！切換到地圖查看', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
            ]),
            backgroundColor: Color(0xFF7FA3B0),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ [Community] 加入行程失敗：$e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFB07070)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _post);
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFDFCF5),
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              backgroundColor: const Color(0xFFFDFCF5),
              leading: GestureDetector(
                onTap: () => Navigator.pop(context, _post),
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF7D6E5D), size: 18),
                ),
              ),
              actions: [
                if (_currentUid != null && _post.authorUid == _currentUid)
                  Container(
                    margin: const EdgeInsets.only(right: 8, top: 6),
                    child: PopupMenuButton<String>(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), shape: BoxShape.circle),
                        child: const Icon(Icons.more_vert_rounded, color: Color(0xFF7D6E5D), size: 18),
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      color: const Color(0xFFFDFCF5),
                      onSelected: (val) async {
                        if (val == 'edit') {
                          final updated = await Navigator.push<CommunityPost>(
                            context,
                            MaterialPageRoute(builder: (_) => EditPostScreen(post: _post)),
                          );
                          if (updated != null && mounted) setState(() => _post = updated);
                        } else if (val == 'delete') {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              backgroundColor: const Color(0xFFFDFCF5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              title: const Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                              content: const Text('確定要刪除這則貼文嗎？刪除後無法還原。', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
                                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('確認刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFB07070), fontWeight: FontWeight.bold))),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            final ok = await CommunityPostService.instance.deletePost(_post.id);
                            if (ok && mounted) {
                              Navigator.pop(context, CommunityPost(
                                id: '', authorUid: '', authorName: '', authorAvatar: '',
                                content: '', type: '', imageUrl: '', likesCount: 0, createdAt: DateTime.now(),
                              ));
                            }
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(children: [
                            Icon(Icons.edit_outlined, color: Color(0xFF7D6E5D), size: 18),
                            SizedBox(width: 10),
                            Text('編輯貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
                          ]),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(children: [
                            Icon(Icons.delete_outline_rounded, color: const Color(0xFFB07070), size: 18),
                            SizedBox(width: 10),
                            Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFB07070))),
                          ]),
                        ),
                      ],
                    ),
                  ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: _post.imageUrl.isNotEmpty
                    ? Hero(
                  tag: _post.id,
                  // 🌟 [修復點] 確保詳細頁面的圖片也補上 width: double.infinity
                  child: buildPostImage(_post.imageUrl, width: double.infinity, fit: BoxFit.cover),
                )
                    : Container(
                  color: const Color(0xFFE8E0D8),
                  child: const Center(child: Icon(Icons.image_rounded, size: 64, color: Colors.white54)),
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)))
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: _tagColor.withOpacity(0.13),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(_post.type, style: TextStyle(fontFamily: 'MyCustomFont', color: _tagColor, fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => showCommentsBottomSheet(context, _post.id),
                          child: const Row(children: [
                            Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF8B9EB5), size: 22),
                            SizedBox(width: 4),
                            Text('留言', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                          ]),
                        ),
                        const SizedBox(width: 16),
                        GestureDetector(
                          onTap: _currentUid != null ? _onLikeTap : null,
                          child: Row(children: [
                            Icon(_post.isLikedByMe ? Icons.favorite_rounded : Icons.favorite_outline_rounded, color: const Color(0xFF8BAA88), size: 22),
                            const SizedBox(width: 4),
                            Text('${_post.likesCount}', style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                          ]),
                        ),
                        const SizedBox(width: 16),
                        GestureDetector(
                          onTap: _currentUid != null ? _onFavoriteTap : null,
                          child: Icon(
                            _post.isFavoriteByMe ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                            color: const Color(0xFF7FA3B0), size: 22,
                          ),
                        ),
                      ],
                    ),

                    if (_post.type == '行程' && _post.itineraryId != null) ...[
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: () => _onAddToMyItinerary(),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7FA3B0).withOpacity(0.10),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.35), width: 1.5),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_location_alt_rounded, size: 18, color: Color(0xFF7FA3B0)),
                              SizedBox(width: 8),
                              Text('加入我的地圖行程', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF7FA3B0), fontWeight: FontWeight.w900)),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    Text(
                      _post.content,
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, height: 1.7, color: Color(0xFF4A3F35), fontWeight: FontWeight.w500),
                    ),

                    if (_post.type == '行程' &&
                        _post.itineraryDayPlans != null &&
                        _post.itineraryDayPlans!.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Row(children: [
                        const Icon(Icons.route_rounded, size: 18, color: Color(0xFF8B9EB5)),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _post.itineraryTitle ?? '行程詳細',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_post.itineraryDays != null)
                          _itineraryChip(Icons.calendar_today_rounded, '${_post.itineraryDays} 天'),
                        if (_post.itineraryBudget != null && _post.itineraryBudget! > 0) ...[
                          const SizedBox(width: 6),
                          _itineraryChip(Icons.account_balance_wallet_rounded, 'NT\$ ${_post.itineraryBudget}'),
                        ],
                      ]),
                      const SizedBox(height: 12),
                      ...(_post.itineraryDayPlans!.map((day) => _buildDaySection(day))),
                    ],

                    if (_post.locationName != null && _post.locationName!.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8BAA88).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.location_on_rounded, color: Color(0xFF8BAA88), size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_post.locationName!, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold))),
                        ]),
                      ),
                    ],

                    const SizedBox(height: 24),
                    const Divider(height: 1, color: Color(0xFFEEEBE4)),
                    const SizedBox(height: 16),

                    Row(children: [
                      buildAvatar(_post.authorAvatar, radius: 22),
                      const SizedBox(width: 12),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_post.authorName, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), fontSize: 14)),
                        Text(
                          _formatDate(_post.createdAt),
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey),
                        ),
                      ]),
                    ]),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaySection(ItineraryDayData day) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF8B9EB5).withOpacity(0.2)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF8B9EB5).withOpacity(0.12),
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18)),
            ),
            child: Row(children: [
              const Icon(Icons.wb_sunny_rounded, size: 15, color: Color(0xFF8B9EB5)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  day.dayLabel,
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF8B9EB5)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),  // 不用 Spacer，避免把 Flexible 擠扁
              Text(
                '${day.items.length} 個行程',
                style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: const Color(0xFF8B9EB5).withOpacity(0.8)),
              ),
            ]),
          ),
          ...day.items.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            final isLast = idx == day.items.length - 1;
            return _buildItineraryItemRow(item, isLast: isLast);
          }),
        ],
      ),
    );
  }

  Widget _buildItineraryItemRow(ItineraryItemData item, {bool isLast = false}) {
    Color catColor;
    IconData catIcon;
    switch (item.category) {
      case '餐廳':
        catColor = const Color(0xFFB09070); catIcon = Icons.restaurant_rounded; break;
      case '住宿':
        catColor = const Color(0xFF7FA3B0); catIcon = Icons.hotel_rounded; break;
      case '自訂':
        catColor = const Color(0xFF9E9182); catIcon = Icons.edit_note_rounded; break;
      default:
        catColor = const Color(0xFF8BAA88); catIcon = Icons.landscape_rounded;
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 56,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  item.time,
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: catColor, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 4),
              Container(width: 2, color: isLast ? Colors.transparent : catColor.withOpacity(0.2)),
            ]),
          ),
          Column(children: [
            const SizedBox(height: 16),
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: catColor, shape: BoxShape.circle),
            ),
          ]),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: 12, top: 10, bottom: isLast ? 14 : 6, right: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(catIcon, size: 14, color: catColor),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF4A3F35)),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                  if (item.location.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(children: [
                      Icon(Icons.location_on_rounded, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          item.location,
                          style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey.shade500),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.duration.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 0,
                          child: Text(item.duration, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: catColor.withOpacity(0.8)), overflow: TextOverflow.ellipsis),
                        )
                      ],
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itineraryChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF8B9EB5).withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF8B9EB5).withOpacity(0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: const Color(0xFF8B9EB5)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8B9EB5), fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  我的發布紀錄頁面
// ══════════════════════════════════════════════════════════════
class MyPostsScreen extends StatefulWidget {
  const MyPostsScreen({super.key});

  @override
  State<MyPostsScreen> createState() => _MyPostsScreenState();
}

class _MyPostsScreenState extends State<MyPostsScreen> {
  List<CommunityPost> _posts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final posts = await CommunityPostService.instance.fetchMyPosts();
    if (mounted) setState(() { _posts = posts; _isLoading = false; });
  }

  Future<void> _deletePost(CommunityPost post) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
        content: const Text('確定要刪除這則貼文嗎？刪除後無法還原。', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('確認刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFB07070), fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (confirm == true) {
      final ok = await CommunityPostService.instance.deletePost(post.id);
      if (ok && mounted) {
        setState(() => _posts.removeWhere((p) => p.id == post.id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('貼文已刪除', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF7D6E5D)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF7D6E5D)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('我的發布紀錄', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF8BAA88)),
            onPressed: _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)))
          : _posts.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🌿', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            const Text('你還沒有發布任何貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 8),
            const Text('回到社群牆點擊 + 開始分享吧！', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13)),
          ],
        ),
      )
          : ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        itemCount: _posts.length,
        itemBuilder: (context, i) {
          final post = _posts[i];
          Color tagColor = const Color(0xFF8BAA88);
          if (post.type == '美食') tagColor = const Color(0xFFB09070);
          else if (post.type == '住宿') tagColor = const Color(0xFF7FA3B0);
          else if (post.type == '行程') tagColor = const Color(0xFF8B9EB5);

          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: post.imageUrl.isNotEmpty
                  ? ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: buildPostImage(post.imageUrl, width: 56, height: 56),
              )
                  : Container(width: 56, height: 56, decoration: BoxDecoration(color: tagColor.withOpacity(0.13), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.article_rounded, color: tagColor)),
              title: Text(post.content, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w700, color: Color(0xFF7D6E5D), fontSize: 13)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: tagColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                    child: Text(post.type, style: TextStyle(fontFamily: 'MyCustomFont', color: tagColor, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Text(_formatDate(post.createdAt), style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                  const SizedBox(width: 8),
                  Icon(Icons.favorite_rounded, size: 12, color: const Color(0xFF8BAA88)),
                  const SizedBox(width: 2),
                  Text('${post.likesCount}', style: const TextStyle(fontSize: 11, color: Color(0xFF7D6E5D))),
                ]),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: const Color(0xFFB07070), size: 20),
                onPressed: () => _deletePost(post),
              ),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostDetailScreen(post: post))),
            ),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime dt) => '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
}

// ══════════════════════════════════════════════════════════════
//  發布新貼文頁面
// ══════════════════════════════════════════════════════════════
class CreatePostScreen extends StatefulWidget {
  final String postType;
  final String? prefillTitle;
  final String? prefillItineraryId;
  final List<String>? prefillSpots;
  final int? prefillDays;
  final int? prefillBudget;
  final List<dynamic>? prefillDailyPlans;

  const CreatePostScreen({
    super.key,
    required this.postType,
    this.prefillTitle,
    this.prefillItineraryId,
    this.prefillSpots,
    this.prefillDays,
    this.prefillBudget,
    this.prefillDailyPlans,
  });

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  late final TextEditingController _contentController;
  final TextEditingController _locationController = TextEditingController();

  final ImagePicker _picker = ImagePicker();
  String _imageUrl = '';

  bool _isSubmitting = false;
  late String _selectedType;

  static const _typeList = ['景點', '美食', '住宿', '其他'];

  static Color _typeColor(String type) {
    if (type == '美食') return const Color(0xFFB09070);
    if (type == '住宿') return const Color(0xFF7FA3B0);
    if (type == '行程') return const Color(0xFF8B9EB5);
    if (type == '其他') return const Color(0xFF9E9182);
    return const Color(0xFF8BAA88);
  }

  @override
  void initState() {
    super.initState();
    _selectedType = (widget.prefillTitle != null)
        ? '行程'
        : (_typeList.contains(widget.postType) ? widget.postType : '其他');
    final hint = widget.prefillTitle != null
        ? '我剛完成了「${widget.prefillTitle}」的行程！\n\n分享我的心得：\n'
        : '';
    _contentController = TextEditingController(text: hint);
  }

  @override
  void dispose() {
    _contentController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _showPickerSheet() {
    showModalBottomSheet(
      context: context, backgroundColor: const Color(0xFFFDFCF5), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 20), decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(2))),
              const Text('選取貼文照片', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 20),
              _sheetButton(Icons.photo_library_rounded, '從相簿選取', () { Navigator.pop(ctx); _pickImage(ImageSource.gallery); }),
              const SizedBox(height: 10),
              _sheetButton(Icons.camera_alt_rounded, '開啟相機拍照', () { Navigator.pop(ctx); _pickImage(ImageSource.camera); }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF7D6E5D).withOpacity(0.18))),
        child: Row(children: [Icon(icon, color: const Color(0xFF7D6E5D), size: 20), const SizedBox(width: 12), Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)))]),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() {
        _imageUrl = base64Encode(bytes);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('選取圖片失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont'))));
      }
    }
  }

  List<ItineraryDayData>? _buildItineraryDayData() {
    final plans = widget.prefillDailyPlans;
    if (plans == null || plans.isEmpty) return null;
    try {
      return plans.map((day) {
        final dayLabel = (day as dynamic).dayLabel?.toString() ?? '';
        final rawItems = (day as dynamic).items as List<dynamic>? ?? [];
        final items = rawItems.map((item) {
          final i = item as dynamic;
          return ItineraryItemData(
            time: i.time?.toString() ?? '',
            title: i.title?.toString() ?? '',
            location: i.location?.toString() ?? '',
            category: i.category?.toString() ?? '景點',
            duration: i.duration?.toString() ?? '',
          );
        }).toList();
        return ItineraryDayData(dayLabel: dayLabel, items: items);
      }).toList();
    } catch (e) {
      debugPrint('⚠️ [Community] 轉換行程資料失敗：$e');
      return null;
    }
  }

  Future<void> _submitPost() async {
    if (_contentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請輸入您想分享的內容喔！', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF7D6E5D)),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final id = await CommunityPostService.instance.publishPost(
      content: _contentController.text.trim(),
      type: _selectedType,
      imageUrl: _imageUrl,
      locationName: _locationController.text.trim().isEmpty ? null : _locationController.text.trim(),
      itineraryId: widget.prefillItineraryId,
      itineraryTitle: widget.prefillTitle,
      itineraryDays: widget.prefillDays,
      itineraryBudget: widget.prefillBudget,
      itineraryDayPlans: _buildItineraryDayData(),
    );

    setState(() => _isSubmitting = false);

    if (id != null && mounted) {
      final newPost = await CommunityPostService.instance.fetchPost(id);
      if (mounted) Navigator.pop(context, newPost);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('發布失敗，請稍後再試', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFB07070)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFromItinerary = widget.prefillTitle != null;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF7D6E5D)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isFromItinerary ? '分享行程至社群' : '發布${_selectedType}分享',
          style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 18),
        ),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            if (!isFromItinerary) ...[
              const Text('分類標籤', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _typeList.map((type) {
                  final isSel = _selectedType == type;
                  final color = _typeColor(type);
                  return GestureDetector(
                    onTap: () => setState(() => _selectedType = type),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSel ? color : color.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: isSel ? color : color.withOpacity(0.3), width: 1.5),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: isSel ? Colors.white : color,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],

            if (isFromItinerary) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF8BAA88).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3), width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.map_rounded, color: Color(0xFF8BAA88), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.prefillTitle!,
                          style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15),
                        ),
                      ),
                    ]),
                    if (widget.prefillDays != null || widget.prefillBudget != null) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (widget.prefillDays != null)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.calendar_today_rounded, size: 13, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text('${widget.prefillDays} 天', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                            ]),
                          if (widget.prefillBudget != null && widget.prefillBudget! > 0)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.account_balance_wallet_rounded, size: 13, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text('NT\$ ${widget.prefillBudget}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                            ]),
                        ],
                      ),
                    ],
                    if (widget.prefillSpots != null && widget.prefillSpots!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: widget.prefillSpots!.take(8).map((spot) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8BAA88).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            spot,
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold),
                          ),
                        )).toList()
                          ..addAll(widget.prefillSpots!.length > 8
                              ? [Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                            child: Text('+${widget.prefillSpots!.length - 8} 個景點', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                          )]
                              : []),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            const Text('封面照片（選填）', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _showPickerSheet(),
              child: Container(
                width: double.infinity,
                height: _imageUrl.isNotEmpty ? 200 : 120,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.35), width: 1.5),
                ),
                child: _imageUrl.isNotEmpty
                    ? Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      // 🌟 [修復點] 加入 width: double.infinity
                      child: buildPostImage(_imageUrl, width: double.infinity, height: 200),
                    ),
                    Positioned(
                      top: 10, right: 10,
                      child: GestureDetector(
                        onTap: () => setState(() => _imageUrl = ''),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ],
                )
                    : const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined, size: 36, color: Color(0xFF8BAA88)),
                    SizedBox(height: 8),
                    Text('點擊選取封面照片（可不選）', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 13)),
                    SizedBox(height: 4),
                    Text('不上傳圖片也可以發布', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 11)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            if (!isFromItinerary) ...[
              const Text('地點（選填）', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15)),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
                ),
                child: TextField(
                  controller: _locationController,
                  style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '例：阿里山、文化路夜市...',
                    hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                    prefixIcon: Icon(Icons.location_on_rounded, color: Color(0xFF8BAA88), size: 20),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            Text(
              isFromItinerary ? '行程心得' : '分享心得',
              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
              ),
              child: TextField(
                controller: _contentController,
                maxLines: 7,
                maxLength: 300,
                style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                decoration: InputDecoration(
                  hintText: isFromItinerary
                      ? '分享這趟行程的精彩片段、踩雷心得、必吃景點...'
                      : '寫下您在嘉義的旅遊心得、攻略、秘境分享...',
                  hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
            ),
            const SizedBox(height: 40),

            SizedBox(
              width: double.infinity, height: 52,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitPost,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8BAA88),
                  disabledBackgroundColor: const Color(0xFF8BAA88).withOpacity(0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                ),
                child: _isSubmitting
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(
                  isFromItinerary ? '發布行程至社群牆 🗺️' : '確認發布至社群牆',
                  style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  編輯貼文頁面
// ══════════════════════════════════════════════════════════════
class EditPostScreen extends StatefulWidget {
  final CommunityPost post;
  const EditPostScreen({super.key, required this.post});

  @override
  State<EditPostScreen> createState() => _EditPostScreenState();
}

class _EditPostScreenState extends State<EditPostScreen> {
  late final TextEditingController _contentController;
  late String _selectedType;
  bool _isSubmitting = false;

  static const _typeList = ['景點', '美食', '住宿', '行程', '其他'];

  static Color _typeColor(String type) {
    if (type == '美食') return const Color(0xFFB09070);
    if (type == '住宿') return const Color(0xFF7FA3B0);
    if (type == '行程') return const Color(0xFF8B9EB5);
    if (type == '其他') return const Color(0xFF9E9182);
    return const Color(0xFF8BAA88);
  }

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.post.content);
    _selectedType = widget.post.type;
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _saveEdit() async {
    if (_contentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('內容不能為空', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF7D6E5D)),
      );
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await FirebaseFirestore.instance.collection('community_posts').doc(widget.post.id).update({
        'content': _contentController.text.trim(),
        'type': _selectedType,
      });
      final updated = widget.post.copyWith();
      final updatedPost = CommunityPost(
        id: widget.post.id,
        authorUid: widget.post.authorUid,
        authorName: widget.post.authorName,
        authorAvatar: widget.post.authorAvatar,
        content: _contentController.text.trim(),
        type: _selectedType,
        imageUrl: widget.post.imageUrl,
        locationName: widget.post.locationName,
        locationLat: widget.post.locationLat,
        locationLon: widget.post.locationLon,
        likesCount: widget.post.likesCount,
        isLikedByMe: widget.post.isLikedByMe,
        isFavoriteByMe: widget.post.isFavoriteByMe,
        createdAt: widget.post.createdAt,
        itineraryId: widget.post.itineraryId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ 貼文已更新', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF8BAA88)),
        );
        Navigator.pop(context, updatedPost);
      }
    } catch (e) {
      debugPrint('⚠️ 編輯貼文失敗：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失敗：$e', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFB07070)),
        );
      }
    }
    if (mounted) setState(() => _isSubmitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF7D6E5D)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('編輯貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 18)),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('分類標籤', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _typeList.map((type) {
                final isSel = _selectedType == type;
                final color = _typeColor(type);
                return GestureDetector(
                  onTap: () => setState(() => _selectedType = type),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSel ? color : color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSel ? color : color.withOpacity(0.3), width: 1.5),
                    ),
                    child: Text(type, style: TextStyle(fontFamily: 'MyCustomFont', color: isSel ? Colors.white : color, fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Text('分享心得', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 15)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
              ),
              child: TextField(
                controller: _contentController,
                maxLines: 8,
                maxLength: 300,
                style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '修改您的分享內容...',
                  hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity, height: 52,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _saveEdit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8BAA88),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                ),
                child: _isSubmitting
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('儲存修改', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuspendedCardWrapper extends StatefulWidget {
  final int index;
  final Widget child;
  const _SuspendedCardWrapper({required this.index, required this.child});

  @override
  State<_SuspendedCardWrapper> createState() => _SuspendedCardWrapperState();
}

class _SuspendedCardWrapperState extends State<_SuspendedCardWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _opacity = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _slide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  留言板 BottomSheet 元件 (全域方法)
// ══════════════════════════════════════════════════════════════
void showCommentsBottomSheet(BuildContext context, String postId) {
  final TextEditingController commentController = TextEditingController();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true, // 允許隨鍵盤推升
    useSafeArea: true,
    backgroundColor: const Color(0xFFFDFCF5),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox( // 改用 ConstrainedBox
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7, // 最多佔 70%
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min, // 關鍵：讓高度隨內容自動縮放，不要硬撐
              children: [
                // 頂部把手與標題
                Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
                const Text('留言區', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 8),
                const Divider(color: Color(0xFFEEEBE4)),

                // 留言列表
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: CommunityPostService.instance.getCommentsStream(postId),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)));
                      }
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(
                          child: Text('目前還沒有留言，來搶頭香吧！', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
                        );
                      }

                      final comments = snapshot.data!.docs;
                      return ListView.separated(
                        physics: const BouncingScrollPhysics(),
                        itemCount: comments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final comment = comments[index].data() as Map<String, dynamic>;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 呼叫你寫好的 buildAvatar
                              buildAvatar(comment['author_avatar'] ?? '', radius: 18),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          comment['author_name'] ?? '旅人',
                                          style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF7D6E5D))
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        comment['content'] ?? '',
                                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF4A3F35)),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),

                // 輸入框區塊
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                        ),
                        child: TextField(
                          controller: commentController,
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14),
                          decoration: const InputDecoration(
                            hintText: '新增留言...',
                            hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () async {
                        final text = commentController.text.trim();
                        if (text.isEmpty) return;

                        // 如果使用者沒登入，擋下來
                        if (FirebaseAuth.instance.currentUser == null) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先登入才能留言喔！', style: TextStyle(fontFamily: 'MyCustomFont'))));
                          return;
                        }

                        commentController.clear();
                        FocusScope.of(context).unfocus(); // 收起鍵盤

                        // ── 從 users collection 取正確的姓名與頭像 ──
                        final _fireUser = FirebaseAuth.instance.currentUser!;
                        String _authorName = _fireUser.displayName ?? _fireUser.email ?? '旅人';
                        String _authorAvatar = _fireUser.photoURL ?? '';

                        try {
                          final _userDoc = await FirebaseFirestore.instance
                              .collection('users')
                              .doc(_fireUser.uid)
                              .get();
                          if (_userDoc.exists) {
                            final _d = _userDoc.data()!;
                            // displayName 優先用 Firestore 的（使用者可能改過）
                            if ((_d['displayName'] as String?)?.isNotEmpty == true) {
                              _authorName = _d['displayName'] as String;
                            } else if ((_d['name'] as String?)?.isNotEmpty == true) {
                              _authorName = _d['name'] as String;
                            }
                            // 頭像：有 avatarBase64 就用，否則用 photoURL
                            if ((_d['avatarBase64'] as String?)?.length != null &&
                                (_d['avatarBase64'] as String).length > 100) {
                              _authorAvatar = _d['avatarBase64'] as String;
                            }
                          }
                        } catch (_) {}

                        // 直接寫入 Firestore，帶正確的 author 資訊
                        final _newRef = FirebaseFirestore.instance
                            .collection('community_posts')
                            .doc(postId)
                            .collection('comments')
                            .doc();
                        await _newRef.set({
                          'id': _newRef.id,
                          'post_id': postId,
                          'author_uid': _fireUser.uid,
                          'author_name': _authorName,
                          'author_avatar': _authorAvatar,
                          'content': text,
                          'created_at': FieldValue.serverTimestamp(),
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const BoxDecoration(
                          color: Color(0xFF8BAA88),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      ),
                    )
                  ],
                )
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ══════════════════════════════════════════════════════════════
//  統一側邊欄（與 profile_screen.dart 相同）
// ══════════════════════════════════════════════════════════════

class _HomeTxtStyleDrawer extends StatelessWidget {
  const _HomeTxtStyleDrawer();

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