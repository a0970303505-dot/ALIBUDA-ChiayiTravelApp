// pubspec.yaml 需新增：
// dependencies:
//   image_picker: ^1.1.2
//   shared_preferences: ^2.2.2
//
// iOS：在 Info.plist 加入：
// NSPhotoLibraryUsageDescription, NSCameraUsageDescription
// Android：AndroidManifest.xml 加入 READ_MEDIA_IMAGES 權限

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cover_screen.dart';
import 'home_screen.dart' show UserAvatar;
import 'community_screen.dart' show MyPostsScreen, PostDetailScreen;
import 'help_support_screen.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'community_post_service.dart';
import 'login_screen.dart';
import 'system_settings_screen.dart';
import 'app_state.dart';

// ═══════════════════════════════════════════════════════════════
//  我的帳號頁面 ─ 頭貼嚴格綁定帳號 UID 版
//  配色：抹茶綠 #8BAA88 / 深咖啡 #7D6E5D / 淡咖啡 #BCAAA4 / 米白 #FDFCF5
// ═══════════════════════════════════════════════════════════════

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  // ── 靜態回調：讓其他頁面（如社群發布後）通知 Profile 刷新貼文數 ──
  static VoidCallback? onPostPublished;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late AnimationController _avatarAnimController;
  late Animation<double> _avatarMoveAnimation;

  late String _userName;
  late String _userId;
  String _userBio = '探索嘉義中，火雞肉飯熱愛者 🌿';

  Uint8List? _avatarBytes;

  // ── 從 Firestore 動態載入的發布紀錄 ─────────────────────────
  List<CommunityPost> _myPosts = [];
  bool _postsLoading = true;

  // ★ 動態從 Firebase 載入
  List<String> _unlockedSpotNames = []; // 已通關景點名稱清單
  bool _stampsLoading = true;
  int? _favCount;

  int get _unlockedStampsCount => _unlockedSpotNames.length;

  // 吉祥物解鎖門檻（對應 assets/images/vo1.png ~ vo9.png）
  static const List<(int, String, String)> _mascotTiers = [
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

  @override
  void initState() {
    super.initState();
    _loadStampsFromFirebase();
    _loadFavoritesCount();

    final currentUser = FirebaseAuth.instance.currentUser;
    _userName = currentUser?.displayName ?? '訪客 (未登入)'; // 訪客顯示

    if (currentUser != null && currentUser.uid.length >= 9) {
      _userId = 'ID : ${currentUser.uid.substring(0, 9)}';
    } else {
      _userId = 'ID : 000000000';
    }

    _avatarAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _avatarMoveAnimation = Tween<double>(begin: 0.0, end: -7.0).animate(
      CurvedAnimation(parent: _avatarAnimController, curve: Curves.easeInOut),
    );
    _avatarAnimController.repeat(reverse: true);

    _loadLocalAvatar();
    _loadMyPosts();
    WidgetsBinding.instance.addObserver(this);
    ProfileScreen.onPostPublished = _loadMyPosts;

    // ★ 監聽帳號切換 → 重置貼文快取並重新拉取
    _profileAuthSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      final newUid = user?.uid;
      if (newUid != _lastLoadedUid) {
        // uid 改變：清空目前顯示的貼文，重新拉取（或顯示空）
        setState(() { _myPosts = []; _postsLoading = true; });
        _lastLoadedUid = null;  // 強制重新載入
        _loadMyPosts(forceRefresh: true);
        _loadStampsFromFirebase();
        _loadFavoritesCount();
        // 同步更新顯示的帳號名稱
        if (user != null) {
          setState(() {
            _userName = user.displayName ?? '旅遊探險家';
            _userId = 'ID : ${user.uid.length >= 9 ? user.uid.substring(0, 9) : user.uid}';
          });
        }
      }
    });
  }

  // ── 從 Firestore 載入我的發布紀錄 ────────────────────────────
  // ★ 加入 uid 快取比對，換帳號後強制重新拉取
  String? _lastLoadedUid;
  StreamSubscription<User?>? _profileAuthSub;

  Future<void> _loadMyPosts({bool forceRefresh = false}) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (mounted) setState(() { _myPosts = []; _postsLoading = false; });
      return;
    }
    // 同一個 uid 且不強制刷新 → 不重複打 Firestore
    if (!forceRefresh && _lastLoadedUid == currentUser.uid && _myPosts.isNotEmpty) {
      if (mounted) setState(() => _postsLoading = false);
      return;
    }
    if (mounted) setState(() => _postsLoading = true);
    _lastLoadedUid = currentUser.uid;
    final posts = await CommunityPostService.instance.fetchMyPosts();
    if (mounted) setState(() { _myPosts = posts; _postsLoading = false; });
  }

  // ★ 修正：讀取時，加入該帳號的 UID 作為唯一識別碼
  Future<void> _loadLocalAvatar() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // 1. 先從 SharedPreferences 讀本地緩存
    final prefs = await SharedPreferences.getInstance();
    final key = 'user_avatar_bytes_${currentUser.uid}';
    final base64String = prefs.getString(key);
    if (base64String != null && base64String.isNotEmpty) {
      if (mounted) setState(() => _avatarBytes = base64Decode(base64String));
      return;
    }

    // 2. 本地無緩存 → 從 Firestore 讀 avatarBase64
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(currentUser.uid).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        final b64 = data['avatarBase64']?.toString();
        if (b64 != null && b64.isNotEmpty) {
          final bytes = base64Decode(b64);
          // 寫回本地
          await prefs.setString(key, b64);
          if (mounted) setState(() => _avatarBytes = bytes);
        }
      }
    } catch (_) {}
  }


  // ★ 吉祥物列表（供 Profile 頭像下方橫排顯示用）
  static const List<(int, String, String, String)> _mascotTiersList = [
    (1,  '阿里山小精靈',   'vo1', '來自阿里山的守護精靈，頭頂永遠有顆柚子，帶著祝福與茶香四處旅行。'),
    (2,  '鐵道站長阿布',   'vo2', '穿梭在百年車站的站長，熱愛嘉義的風景與故事，夢想是開著小火車環島！'),
    (3,  '木棉花仙子',    'vo3', '每年木棉花開時降臨嘉義，用溫柔與勇氣守護這片土地。'),
    (4,  '咖啡農夫熊大力', 'vo4', '來自梅山的咖啡農夫，種出世界級的咖啡，每天的活力來源是濃濃的一杯手沖！'),
    (5,  '布袋魚市小老闆', 'vo5', '最愛新鮮海味的魚市小老闆，叫賣聲響亮，夢想是開一間海味餐廳！'),
    (6,  '雞肉飯小當家',   'vo6', '用一碗碗香噴噴的雞肉飯，征服所有人的胃與心！'),
    (7,  '鳳梨乳牛阿嘉',   'vo7', '來自民雄的鳳梨乳牛，喝著香甜鳳梨汁長大，產出香濃鳳梨風味的鮮乳，酸甜幸福！'),
    (8,  '方塊酥小師傅',   'vo8', '專注製作傳統方塊酥，香酥可口不黏牙，把嘉義最經典的好味道分享給大家！'),
    (9,  '陣頭小天后',    'vo9', '熱愛廟會與陣頭文化，跳起來氣勢十足，是嘉義最閃亮的民俗之星！'),
  ];


  Future<void> _loadFavoritesCount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      // ★ 修正路徑：用小寫 'favorites'，與 favorites_screen.dart / map_screen.dart 存的路徑一致
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('favorites').count().get();
      if (mounted) setState(() => _favCount = snap.count);
    } catch (_) {}
  }

  Future<void> _loadStampsFromFirebase() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { if (mounted) setState(() => _stampsLoading = false); return; }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('stamps').get();
      // 只需要景點名稱清單，按解鎖時間排序
      final names = snap.docs.map((d) => d.id).toList();
      if (mounted) setState(() { _unlockedSpotNames = names; _stampsLoading = false; });
    } catch (e) {
      debugPrint('載入印章失敗: $e');
      if (mounted) setState(() => _stampsLoading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ProfileScreen.onPostPublished = null;
    _profileAuthSub?.cancel();   // ★
    _avatarAnimController.dispose();
    super.dispose();
  }

  // ── App 從背景回到前台時自動重整貼文數 ──────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadMyPosts();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      drawer: const _HomeTxtStyleDrawer(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildInlineHeader(context)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            sliver: SliverToBoxAdapter(child: _buildProfileCard()),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('個人專屬空間', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildActionTile('我的印章收集', Icons.workspace_premium_rounded, const Color(0xFF8BAA88), '已解鎖 $_unlockedStampsCount 枚印章', () => _navigateToPage(_StampCollectionPage(unlockedSpotNames: _unlockedSpotNames, isLoading: _stampsLoading)))),
                      const SizedBox(width: 14),
                      Expanded(child: _buildActionTile('我的發布紀錄', Icons.auto_stories_rounded, const Color(0xFF7FA3B0), _postsLoading ? '載入中…' : '共發表 ${_myPosts.length} 篇貼文', () => _navigateToPage(UserLogsPage(posts: _myPosts, onRefresh: _loadMyPosts)))),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 100),
            sliver: SliverToBoxAdapter(
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.01), blurRadius: 10)]),
                child: Column(
                  children: [
                    _buildSystemRow(Icons.info_outline_rounded, '系統說明與版本規範', () => _showSystemInfoDialog()),
                    Divider(height: 1, color: const Color(0xFFE2E8F0).withOpacity(0.6), indent: 16, endIndent: 16),
                    _buildSystemRow(Icons.logout_rounded, '安全登出當前帳號', () => _showLogoutConfirmationDialog(), isLogout: true),
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildInlineHeader(BuildContext context) {
    // 檢查目前是否為訪客
    final isGuest = FirebaseAuth.instance.currentUser == null;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 52, 24, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            icon: const Icon(Icons.menu_rounded, size: 32, color: Color(0xFF7D6E5D)),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(), alignment: Alignment.centerLeft,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: const TextSpan(
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    children: [
                      TextSpan(text: 'MY ', style: TextStyle(color: Color(0xFF7D6E5D))),
                      TextSpan(text: 'PROFILE', style: TextStyle(color: Color(0xFF8BAA88))),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.assignment_ind_rounded, size: 13, color: Color(0xFF8BAA88)),
                      const SizedBox(width: 6),
                      Text(isGuest ? '訪客瀏覽模式' : '註冊會員帳戶中心', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 只有登入會員才顯示設定按鈕
          if (!isGuest)
            IconButton(
              icon: const Icon(Icons.settings_rounded, size: 26, color: Color(0xFF7D6E5D)),
              onPressed: () => _navigateToPage(
                _EditProfilePage(
                  currentName: _userName,
                  currentBio: _userBio,
                  currentAvatarBytes: _avatarBytes,

                  // ★ 修正：儲存時，也要用該帳號的 UID 作為 Key
                  onSaved: (newName, newBio, newAvatarBytes) async {
                    setState(() {
                      _userName = newName;
                      _userBio = newBio;
                      _avatarBytes = newAvatarBytes;
                    });

                    final currentUser = FirebaseAuth.instance.currentUser;
                    if (currentUser == null) return;

                    try {
                      await currentUser.updateDisplayName(newName);

                      final prefs = await SharedPreferences.getInstance();
                      final key = 'user_avatar_bytes_${currentUser.uid}'; // 綁定 UID

                      if (newAvatarBytes != null) {
                        final base64String = base64Encode(newAvatarBytes);
                        await prefs.setString(key, base64String);
                      } else {
                        await prefs.remove(key);
                      }
                    } catch (e) {
                      debugPrint('更新資料失敗: $e');
                    }
                  },
                ),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 15, offset: const Offset(0, 6))],
        border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.12)),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFF8BAA88).withOpacity(0.12), const Color(0xFF8BAA88).withOpacity(0.01)]),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                AnimatedBuilder(
                  animation: _avatarMoveAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _avatarMoveAnimation.value),
                      child: child,
                    );
                  },
                  child: GestureDetector(
                    onTap: () => _navigateToPage(_EditProfilePage(
                      currentName: _userName,
                      currentBio: _userBio,
                      currentAvatarBytes: _avatarBytes,
                      onSaved: (newName, newBio, newAvatarBytes) async {
                        setState(() {
                          if (newName.isNotEmpty) _userName = newName;
                          if (newBio.isNotEmpty) _userBio = newBio;
                          if (newAvatarBytes != null) _avatarBytes = newAvatarBytes;
                        });
                      },
                    )),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: _unlockedStampsCount >= 8
                              ? [const Color(0xFFE8C547), const Color(0xFFFF9D3D), const Color(0xFFE8C547)]
                              : _unlockedStampsCount >= 4
                              ? [const Color(0xFFD4A017), const Color(0xFFE8C547)]
                              : [const Color(0xFF8BAA88), const Color(0xFF8BAA88)],
                        ),
                      ),
                      child: Builder(builder: (ctx) {
                        final user = FirebaseAuth.instance.currentUser;
                        // 優先用本地緩存；若無，UserAvatar 會從 Firestore 讀 avatarBase64
                        return UserAvatar(user: user, radius: 38);
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_userName, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 4),
                Text(_userId, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(_userBio, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D)), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: const Color(0xFFE2E8F0).withOpacity(0.5)))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatColumn('$_unlockedStampsCount 枚', '已獲印章'),
                Container(width: 1, height: 24, color: const Color(0xFFE2E8F0)),
                _buildStatColumn(_postsLoading ? '…' : '${_myPosts.length} 篇', '社群貼文'),
                Container(width: 1, height: 24, color: const Color(0xFFE2E8F0)),
                _buildStatColumn(_favCount == null ? '…' : '${_favCount} 個', '我的收藏'),
              ],
            ),
          ),
          // ★ 已解鎖吉祥物小縮圖橫排
          if (_unlockedStampsCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.stars_rounded, size: 13, color: Color(0xFF8BAA88)),
                    const SizedBox(width: 4),
                    Text('我的嘉義夥伴 ($_unlockedStampsCount / 9)', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: _ProfileScreenState._mascotTiersList.where((t) => _unlockedStampsCount >= t.$1).map((tier) =>
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Container(
                              width: 52, height: 52,
                              decoration: BoxDecoration(
                                color: Colors.white, borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.35)),
                                boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.08), blurRadius: 6)],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Align(
                                  alignment: const Alignment(0, -0.1),
                                  child: FractionallySizedBox(
                                    widthFactor: 1.25,
                                    heightFactor: 1.25,
                                    child: Image.asset('assets/images/vo/' + tier.$3 + '.png', fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) => Icon(Icons.pets_rounded, color: const Color(0xFF8BAA88).withOpacity(0.4), size: 24)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ).toList(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatColumn(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildActionTile(String title, IconData icon, Color themeColor, String subtitle, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: themeColor.withOpacity(0.18), width: 1.2),
          boxShadow: [BoxShadow(color: themeColor.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: themeColor.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: themeColor, size: 24),
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemRow(IconData icon, String text, VoidCallback onTap, {bool isLogout = false}) {
    return ListTile(
      leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: isLogout ? const Color(0xFFA68A6D).withOpacity(0.1) : const Color(0xFF7D6E5D).withOpacity(0.06), shape: BoxShape.circle), child: Icon(icon, color: isLogout ? const Color(0xFFA68A6D) : const Color(0xFF7D6E5D), size: 18)),
      title: Text(text, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: isLogout ? const Color(0xFFA68A6D) : const Color(0xFF7D6E5D))),
      trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Colors.grey),
      onTap: onTap,
    );
  }

  void _navigateToPage(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => page));
    // 從任何子頁返回後，重新載入貼文數（確保發布紀錄與社群貼文數即時同步）
    _loadMyPosts();
  }

  void _showSystemInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('系統說明', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
        content: const Text('探索嘉義 App 智慧導覽服務平台\n版本序號：v2.5.0-Release (2026)\n\n內嵌智慧預算控管、AI 行程生成系統與跨平台地理圍欄技術模組，保障您的深度休閒旅程品質。', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.5)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('關閉', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)))],
      ),
    );
  }

  void _showLogoutConfirmationDialog() {
    final isGuest = FirebaseAuth.instance.currentUser == null;
    if (isGuest) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('您目前為訪客，無須登出。'), backgroundColor: Color(0xFF7D6E5D)));
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('確認登出安全系統嗎？', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
        content: const Text('登出後帳戶中心將切換為遊客限制瀏覽模式，您依然可以隨時重新登入同步數據。', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await FirebaseAuth.instance.signOut();
                await GoogleSignIn().signOut();
                await FacebookAuth.instance.logOut();
              } catch (e) {
                print('登出發生錯誤: $e');
              }
              if (!context.mounted) return;
              Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const CoverScreen()), (route) => false);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🔒 已安全登出，目前已切換為訪客瀏覽狀態！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)), backgroundColor: Color(0xFF7D6E5D)));
            },
            child: const Text('確認登出', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFA68A6D), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  二級獨立子頁：1. 我的印章收集頁面
// ═══════════════════════════════════════════════════════════════
class _StampCollectionPage extends StatelessWidget {
  final List<String> unlockedSpotNames; // 已通關景點名稱（來自 Firebase）
  final bool isLoading;

  const _StampCollectionPage({
    required this.unlockedSpotNames,
    this.isLoading = false,
  });

  int get _count => unlockedSpotNames.length;

  // 吉祥物解鎖門檻（集 N 章解鎖）
  static const List<(int, String, String, String)> _mascots = [
    (1,  '阿里山小精靈',   'vo1', '來自阿里山的守護精靈，頭頂永遠有顆柚子，帶著祝福與茶香四處旅行。'),
    (2,  '鐵道站長阿布',   'vo2', '穿梭在百年車站的站長，熱愛嘉義的風景與故事，夢想是開著小火車環島！'),
    (3,  '木棉花仙子',    'vo3', '每年木棉花開時降臨嘉義，用溫柔與勇氣守護這片土地。'),
    (4,  '咖啡農夫熊大力', 'vo4', '來自梅山的咖啡農夫，種出世界級的咖啡，每天的活力來源是濃濃的一杯手沖！'),
    (5,  '布袋魚市小老闆', 'vo5', '最愛新鮮海味的魚市小老闆，叫賣聲響亮，夢想是開一間海味餐廳！'),
    (6,  '雞肉飯小當家',   'vo6', '用一碗碗香噴噴的雞肉飯，征服所有人的胃與心！'),
    (7,  '鳳梨乳牛阿嘉',   'vo7', '來自民雄的鳳梨乳牛，喝著香甜鳳梨汁長大，產出香濃鳳梨風味的鮮乳，酸甜幸福！'),
    (8,  '方塊酥小師傅',   'vo8', '專注製作傳統方塊酥，香酥可口不黏牙，把嘉義最經典的好味道分享給大家！'),
    (9,  '陣頭小天后',    'vo9', '熱愛廟會與陣頭文化，跳起來氣勢十足，是嘉義最閃亮的民俗之星！'),
  ];

  static const Color _green = Color(0xFF8BAA88);
  static const Color _brown = Color(0xFF7D6E5D);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── Header ──
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
                          border: Border.all(color: _green.withOpacity(0.2)),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
                      child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: _brown),
                    ),
                  ),
                  Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('MY ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: _brown, letterSpacing: 1.5)),
                        Text('STAMPS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: _green, letterSpacing: 1.5)),
                      ]),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(color: _green.withOpacity(0.08), borderRadius: BorderRadius.circular(16), border: Border.all(color: _green.withOpacity(0.3))),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.workspace_premium_rounded, size: 14, color: _green),
                          const SizedBox(width: 6),
                          Text('已解鎖 $_count 個印章', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: _brown)),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
            ),
          ),

          if (isLoading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: _green, strokeWidth: 2)))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList(
                delegate: SliverChildListDelegate([

                  // ════════════════════════════════
                  //  上區：已通關景點清單
                  // ════════════════════════════════
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7FA3B0).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.35)),
                      ),
                      child: const Icon(Icons.map_outlined, size: 18, color: Color(0xFF7FA3B0)),
                    ),
                    const SizedBox(width: 10),
                    const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('已通關景點', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
                      Text('完成問答即可獲得印章！', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                    ]),
                  ]),
                  const SizedBox(height: 12),

                  // 已通關景點名稱框框列表
                  if (_count == 0)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3F0),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFD4CEC8)),
                      ),
                      child: const Column(children: [
                        Icon(Icons.explore_outlined, size: 32, color: Color(0xFFBCAAA4)),
                        SizedBox(height: 8),
                        Text('尚未通關任何景點', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFFBCAAA4), fontWeight: FontWeight.bold)),
                        SizedBox(height: 4),
                        Text('前往景點完成知識問答來獲得印章吧！', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFFD4CEC8))),
                      ]),
                    )
                  else
                    Column(
                      children: unlockedSpotNames.asMap().entries.map((e) {
                        final idx = e.key;
                        final spotName = e.value;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: _green.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _green.withOpacity(0.3), width: 1.2),
                          ),
                          child: Row(children: [
                            Container(
                              width: 24, height: 24,
                              decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(8)),
                              child: Center(
                                child: Text('${idx + 1}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.white, fontWeight: FontWeight.w900)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(spotName, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: _brown)),
                            ),
                            const Icon(Icons.check_circle_rounded, size: 16, color: _green),
                          ]),
                        );
                      }).toList(),
                    ),

                  const SizedBox(height: 28),

                  // ════════════════════════════════
                  //  下區：印章收藏（按通關數量顯示 po1~poN）
                  // ════════════════════════════════
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _green.withOpacity(0.35)),
                      ),
                      child: const Icon(Icons.auto_awesome_mosaic_rounded, size: 18, color: _green),
                    ),
                    const SizedBox(width: 10),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('印章收藏', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
                      Text('已收集 $_count 枚', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                    ]),
                  ]),
                  const SizedBox(height: 12),

                  // 進度條
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _count == 0 ? 0 : (_count / 12).clamp(0.0, 1.0),
                      backgroundColor: _green.withOpacity(0.12),
                      valueColor: const AlwaysStoppedAnimation(_green),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 印章 Grid：通關幾關就顯示 po1~poN，其餘空框
                  GridView.builder(
                    shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1,
                    ),
                    itemCount: 12, // po1~po12 共 12 個槽位
                    itemBuilder: (ctx, i) {
                      final isUnlocked = i < _count;
                      final stampAsset = 'assets/images/po/po${i + 1}.png';
                      if (isUnlocked) {
                        return GestureDetector(
                          onTap: () => showDialog(
                            context: ctx,
                            barrierColor: Colors.black.withOpacity(0.7),
                            builder: (_) => Dialog(
                              backgroundColor: Colors.transparent,
                              elevation: 0,
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Container(
                                  width: 240, height: 240,
                                  decoration: BoxDecoration(
                                    color: Colors.white, shape: BoxShape.circle,
                                    border: Border.all(color: _green.withOpacity(0.6), width: 3),
                                    boxShadow: [BoxShadow(color: _green.withOpacity(0.25), blurRadius: 30, offset: const Offset(0, 8))],
                                  ),
                                  child: ClipOval(child: Image.asset(stampAsset, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.workspace_premium_rounded, color: _green, size: 80))),
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                  decoration: BoxDecoration(color: _green.withOpacity(0.15), borderRadius: BorderRadius.circular(24), border: Border.all(color: _green.withOpacity(0.4))),
                                  child: Text('第 ${i + 1} 枚印章', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
                                ),
                                if (i < unlockedSpotNames.length) ...[
                                  const SizedBox(height: 6),
                                  Text(unlockedSpotNames[i], style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.white70)),
                                ],
                              ]),
                            ),
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white, shape: BoxShape.circle,
                              border: Border.all(color: _green.withOpacity(0.6), width: 2),
                              boxShadow: [BoxShadow(color: _green.withOpacity(0.18), blurRadius: 8, offset: const Offset(0, 3))],
                            ),
                            child: ClipOval(child: Image.asset(stampAsset, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.workspace_premium_rounded, color: _green, size: 32))),
                          ),
                        );
                      } else {
                        // 未解鎖：印章圖片灰階化 + 半透明遮罩，製造期待感
                        return Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFD4CEC8), width: 1.2),
                          ),
                          child: ClipOval(
                            child: Stack(alignment: Alignment.center, children: [
                              // 灰階印章圖（隱隱約約可見）
                              ColorFiltered(
                                colorFilter: const ColorFilter.matrix([
                                  0.33, 0.59, 0.11, 0, 0,
                                  0.33, 0.59, 0.11, 0, 0,
                                  0.33, 0.59, 0.11, 0, 0,
                                  0,    0,    0,    0.35, 0,
                                ]),
                                child: Image.asset(stampAsset, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(color: const Color(0xFFF0EDE8))),
                              ),
                              // 半透明白色霧化遮罩
                              Container(color: Colors.white.withOpacity(0.45)),
                              // 鎖頭 icon
                              const Icon(Icons.lock_rounded, size: 18, color: Color(0xFFBCAAA4)),
                            ]),
                          ),
                        );
                      }
                    },
                  ),

                  const SizedBox(height: 28),

                  // ════════════════════════════════
                  //  吉祥物：集 N 章解鎖（同邏輯）
                  // ════════════════════════════════
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _green.withOpacity(0.35)),
                      ),
                      child: const Icon(Icons.card_giftcard_rounded, size: 18, color: _green),
                    ),
                    const SizedBox(width: 10),
                    const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('嘉義特色吉祥物', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
                      Text('收集印章解鎖嘉義夥伴！', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                    ]),
                  ]),
                  const SizedBox(height: 12),

                  GridView.builder(
                    shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 16, crossAxisSpacing: 16, childAspectRatio: 0.78),
                    itemCount: _mascots.length,
                    itemBuilder: (ctx, i) {
                      final mascot = _mascots[i];
                      final needed = mascot.$1;
                      final name = mascot.$2;
                      final assetKey = mascot.$3;
                      final desc = mascot.$4;
                      final isUnlocked = _count >= needed;

                      return GestureDetector(
                        onTap: () {
                          if (isUnlocked) {
                            _showMascotDetail(ctx, mascot, true);
                          } else {
                            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('再收集 ${needed - _count} 個印章即可解鎖此吉祥物 🔒',
                                  style: const TextStyle(fontFamily: 'MyCustomFont')),
                              backgroundColor: const Color(0xFF9E7B6B),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ));
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isUnlocked ? Colors.white : const Color(0xFFF5F3F0),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: isUnlocked ? _green.withOpacity(0.4) : const Color(0xFFE2E8F0), width: isUnlocked ? 1.5 : 1),
                            boxShadow: isUnlocked ? [BoxShadow(color: _green.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, 4))] : null,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // RARE badge + 解鎖門檻
                              Padding(
                                padding: const EdgeInsets.only(top: 8, left: 8, right: 8),
                                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: isUnlocked ? _green : Colors.grey[400], borderRadius: BorderRadius.circular(6)),
                                    child: const Text('RARE', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isUnlocked ? _green.withOpacity(0.12) : const Color(0xFFEDEAE5),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: isUnlocked ? _green.withOpacity(0.4) : const Color(0xFFD4CEC8), width: 0.8),
                                    ),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(isUnlocked ? Icons.lock_open_rounded : Icons.lock_rounded, size: 9,
                                          color: isUnlocked ? _green : Colors.grey[400]),
                                      const SizedBox(width: 2),
                                      Text('集$needed章', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, fontWeight: FontWeight.bold,
                                          color: isUnlocked ? _green : Colors.grey[400])),
                                    ]),
                                  ),
                                ]),
                              ),
                              // 圖片
                              SizedBox(
                                height: 140,
                                child: ClipRect(
                                  child: isUnlocked
                                      ? Hero(
                                    tag: 'mascot_$i',
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: FractionallySizedBox(
                                        widthFactor: 1.4, heightFactor: 1.4,
                                        child: Image.asset('assets/images/vo/$assetKey.png', fit: BoxFit.contain,
                                            errorBuilder: (_, __, ___) => Icon(Icons.pets_rounded, size: 40, color: _green.withOpacity(0.4))),
                                      ),
                                    ),
                                  )
                                      : Container(
                                    margin: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(12)),
                                    child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                      Icon(Icons.lock_outline_rounded, size: 28, color: Colors.grey[500]),
                                      const SizedBox(height: 4),
                                      Text('集 $needed 章解鎖', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, color: Colors.grey[600], fontWeight: FontWeight.bold)),
                                    ])),
                                  ),
                                ),
                              ),
                              // 名稱
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                                child: Column(children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                    decoration: BoxDecoration(color: isUnlocked ? _brown : Colors.grey[400], borderRadius: BorderRadius.circular(8)),
                                    child: Text(name, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                                  const SizedBox(height: 3),
                                  Text('嘉義特色系列 Vol.$needed', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 8, color: Colors.grey[500]), textAlign: TextAlign.center),
                                ]),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                ]),
              ),
            ),
        ],
      ),
    );
  }

  void _showMascotDetail(BuildContext ctx, (int, String, String, String) mascot, bool isUnlocked) {
    showModalBottomSheet(
      context: ctx, backgroundColor: Colors.transparent, isScrollControlled: true,
      builder: (bctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          Container(
            height: 200,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [const Color(0xFF8BAA88).withOpacity(0.08), const Color(0xFFF9F8F4)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Align(
                alignment: const Alignment(0, -0.15),
                child: FractionallySizedBox(
                  widthFactor: 1.25, heightFactor: 1.25,
                  child: Image.asset('assets/images/vo/${mascot.$3}.png', fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(Icons.pets_rounded, size: 80, color: const Color(0xFF8BAA88).withOpacity(0.4))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(mascot.$2, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          const SizedBox(height: 4),
          Text('嘉義特色系列 Vol.${mascot.$1}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.06), borderRadius: BorderRadius.circular(14)),
            child: Text(mascot.$4, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.6), textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3))),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_circle_rounded, color: Color(0xFF8BAA88), size: 16),
              SizedBox(width: 6),
              Text('已解鎖！加入你的嘉義夥伴行列', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  二級獨立子頁：2. 我的發布紀錄頁面（Firestore 真實資料版）
// ═══════════════════════════════════════════════════════════════
// ★ 改成 public class，讓側邊欄可以直接跳過來
// ★ 不再依賴外部傳入 posts，自己從 Firestore 抓
class UserLogsPage extends StatefulWidget {
  final List<CommunityPost> posts;        // 保留舊參數以免破壞 profile 內部呼叫
  final Future<void> Function() onRefresh;
  const UserLogsPage({super.key, required this.posts, required this.onRefresh});

  @override
  State<UserLogsPage> createState() => _UserLogsPageState();
}

class _UserLogsPageState extends State<UserLogsPage> {
  final GlobalKey<ScaffoldState> _logScaffoldKey = GlobalKey<ScaffoldState>();
  List<CommunityPost> _posts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // ★ 若外部有傳貼文就用，否則自己抓
    if (widget.posts.isNotEmpty) {
      _posts = widget.posts;
      _isLoading = false;
    } else {
      _fetchPosts();
    }
  }

  Future<void> _fetchPosts() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final posts = await CommunityPostService.instance.fetchMyPosts();
      if (mounted) setState(() { _posts = posts; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Color _typeColor(String type) {
    if (type == '美食') return const Color(0xFFB09070);
    if (type == '住宿') return const Color(0xFF7FA3B0);
    if (type == '行程') return const Color(0xFF8B9EB5);
    return const Color(0xFF8BAA88);
  }

  IconData _typeIcon(String type) {
    if (type == '美食') return Icons.restaurant_rounded;
    if (type == '住宿') return Icons.hotel_rounded;
    if (type == '行程') return Icons.map_rounded;
    if (type == '景點') return Icons.landscape_rounded;
    return Icons.article_rounded;
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _logScaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      drawer: const _HomeTxtStyleDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        toolbarHeight: 88,
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, size: 30, color: Color(0xFF7D6E5D)),
          onPressed: () => _logScaffoldKey.currentState?.openDrawer(),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: const TextSpan(
                style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                children: [
                  TextSpan(text: 'MY ', style: TextStyle(color: Color(0xFF7D6E5D))),
                  TextSpan(text: 'LOGS', style: TextStyle(color: Color(0xFF7FA3B0))),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF7FA3B0).withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.35), width: 1.2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_stories_rounded, size: 12, color: Color(0xFF7FA3B0)),
                  const SizedBox(width: 5),
                  Text(
                    '共發表 ${_posts.length} 篇貼文',
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // ★ 刷新按鈕
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF8BAA88), size: 22),
            onPressed: _fetchPosts,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 22),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)))
          : _posts.isEmpty
          ? Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_stories_rounded, size: 56, color: const Color(0xFF7FA3B0).withOpacity(0.4)),
          const SizedBox(height: 16),
          const Text('還沒有發布任何貼文', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF9E9182))),
          const SizedBox(height: 6),
          const Text('到社群或行程頁面發布第一篇吧！', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
        ]),
      )
          : RefreshIndicator(
        color: const Color(0xFF7FA3B0),
        onRefresh: () async {
          await widget.onRefresh();
          final fresh = await CommunityPostService.instance.fetchMyPosts();
          if (mounted) setState(() => _posts = fresh);
        },
        child: ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 100),
          itemCount: _posts.length,
          itemBuilder: (context, index) {
            final post = _posts[index];
            final color = _typeColor(post.type);
            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: color.withOpacity(0.18), width: 1.2),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面圖（有的話）
                  if (post.imageUrl.isNotEmpty)
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(21)),
                      child: Image.network(post.imageUrl, width: double.infinity, height: 150, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 頂部：類型標籤 + 日期
                        Row(children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(_typeIcon(post.type), size: 12, color: color),
                              const SizedBox(width: 4),
                              Text(post.type, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                            ]),
                          ),
                          const Spacer(),
                          Text(_formatDate(post.createdAt), style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                        ]),
                        const SizedBox(height: 10),
                        // 行程標題（type == '行程' 才顯示）
                        if (post.type == '行程' && (post.itineraryTitle ?? '').isNotEmpty) ...[
                          Row(children: [
                            const Icon(Icons.map_rounded, size: 13, color: Color(0xFF8B9EB5)),
                            const SizedBox(width: 5),
                            Expanded(child: Text(post.itineraryTitle!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF8B9EB5)), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            if ((post.itineraryDays ?? 0) > 0) ...[
                              const SizedBox(width: 8),
                              Text('${post.itineraryDays}天', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                            ],
                          ]),
                          const SizedBox(height: 6),
                        ],
                        // 貼文內容摘要
                        Text(
                          post.content,
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.5),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 10),
                        // 底部：按讚數 + 更多 + 刪除
                        Row(children: [
                          Icon(Icons.favorite_rounded, size: 13, color: Colors.pinkAccent.withOpacity(0.7)),
                          const SizedBox(width: 4),
                          Text('${post.likesCount}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                          if ((post.locationName ?? '').isNotEmpty) ...[
                            const SizedBox(width: 14),
                            Icon(Icons.location_on_rounded, size: 13, color: Colors.grey.shade400),
                            const SizedBox(width: 3),
                            Expanded(child: Text(post.locationName!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ] else
                            const Spacer(),
                          // ★ 更多按鈕 → 跳 PostDetailScreen，離開後回到此頁
                          GestureDetector(
                            onTap: () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => PostDetailScreen(post: post),
                            )),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF8BAA88).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                              ),
                              child: const Text('更多', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                            ),
                          ),
                          // 刪除按鈕
                          GestureDetector(
                            onTap: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  backgroundColor: const Color(0xFFFDFCF5),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  title: const Text('刪除貼文', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                                  content: const Text('確定要刪除這則貼文嗎？', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
                                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFB07070), fontWeight: FontWeight.bold))),
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
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(color: const Color(0xFFB07070).withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
                              child: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFB07070)),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  二級獨立子頁：3. 修改個人資料資訊頁面
// ═══════════════════════════════════════════════════════════════
class _EditProfilePage extends StatefulWidget {
  final String currentName;
  final String currentBio;
  final Uint8List? currentAvatarBytes;
  final Function(String, String, Uint8List?) onSaved;

  const _EditProfilePage({
    required this.currentName,
    required this.currentBio,
    required this.currentAvatarBytes,
    required this.onSaved,
  });

  @override
  State<_EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<_EditProfilePage> {
  final GlobalKey<ScaffoldState> editScaffoldKey = GlobalKey<ScaffoldState>();
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  final ImagePicker _picker = ImagePicker();

  Uint8List? _previewBytes;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _bioController = TextEditingController(text: widget.currentBio);
    _previewBytes = widget.currentAvatarBytes;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickFromGallery() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _previewBytes = bytes);
  }

  Future<void> _pickFromCamera() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => _previewBytes = bytes);
  }

  void _showPickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFFFDFCF5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 20), decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(2))),
              const Text('更換大頭貼', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 20),
              _sheetButton(Icons.photo_library_rounded, '從相簿選取', () { Navigator.pop(ctx); _pickFromGallery(); }),
              const SizedBox(height: 10),
              _sheetButton(Icons.camera_alt_rounded, '開啟相機拍照', () { Navigator.pop(ctx); _pickFromCamera(); }),
              if (_previewBytes != null) ...[
                const SizedBox(height: 10),
                _sheetButton(Icons.delete_outline_rounded, '移除目前頭貼', () { Navigator.pop(ctx); setState(() => _previewBytes = null); }, isDestructive: true),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(IconData icon, String label, VoidCallback onTap, {bool isDestructive = false}) {
    final color = isDestructive ? const Color(0xFFA68A6D) : const Color(0xFF7D6E5D);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        decoration: BoxDecoration(
          color: isDestructive ? const Color(0xFFA68A6D).withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.18)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: editScaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      drawer: const _HomeTxtStyleDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5), elevation: 0, centerTitle: true,
        leading: IconButton(icon: const Icon(Icons.menu_rounded, color: Color(0xFF7D6E5D), size: 30), onPressed: () => editScaffoldKey.currentState?.openDrawer()),
        title: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('MY ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
            Text('PROFILE', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
          ]),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF8BAA88).withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
            ),
            child: const Text('變更使用者資訊', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          ),
        ]),
        toolbarHeight: 72,
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold)))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _showPickerSheet,
                    child: Stack(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF8BAA88), width: 2),
                          ),
                          child: CircleAvatar(
                            radius: 52,
                            backgroundColor: const Color(0xFFF0EDE8),
                            backgroundImage: _previewBytes != null ? MemoryImage(_previewBytes!) : null,
                            child: _previewBytes == null
                                ? const Icon(Icons.person_rounded, size: 52, color: Color(0xFFBCAAA4))
                                : null,
                          ),
                        ),
                        Positioned(
                          bottom: 4, right: 4,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Color(0xFF8BAA88),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.camera_alt_rounded, size: 14, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '點擊頭像即可更換照片',
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text('會員暱稱大名', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D)),
              decoration: InputDecoration(
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
              ),
            ),
            const SizedBox(height: 24),
            const Text('個人簡介文案', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _bioController,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D)),
              decoration: InputDecoration(
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
              ),
            ),
            const SizedBox(height: 44),
            SizedBox(
              width: double.infinity, height: 52,
              child: ElevatedButton(
                onPressed: () {
                  widget.onSaved(
                    _nameController.text,
                    _bioController.text,
                    _previewBytes,
                  );
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('💾 個人資訊修改儲存成功！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                      backgroundColor: Color(0xFF8BAA88),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8BAA88),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                ),
                child: const Text('確認儲存變更', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Drawer ─ 側邊欄同步判定訪客狀態
// ═══════════════════════════════════════════════════════════════
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
                    onTap: () => Navigator.pop(context)),
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