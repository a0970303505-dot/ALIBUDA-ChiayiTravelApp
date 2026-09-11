// ═══════════════════════════════════════════════════════════════
//  community_post_service.dart
//  社群貼文 Firestore 服務 (強制抓取 Base64 自訂頭貼版 + 個人資料同步)
// ═══════════════════════════════════════════════════════════════
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'local_db_service.dart';

// ── 行程每日景點資料（用於貼文詳情展示）─────────────────────────

class ItineraryItemData {
  final String time;
  final String title;
  final String location;
  final String category;
  final String duration;

  const ItineraryItemData({
    required this.time,
    required this.title,
    required this.location,
    required this.category,
    required this.duration,
  });

  Map<String, dynamic> toMap() => {
    'time': time,
    'title': title,
    'location': location,
    'category': category,
    'duration': duration,
  };

  factory ItineraryItemData.fromMap(Map<String, dynamic> m) => ItineraryItemData(
    time: m['time']?.toString() ?? '',
    title: m['title']?.toString() ?? '',
    location: m['location']?.toString() ?? '',
    category: m['category']?.toString() ?? '景點',
    duration: m['duration']?.toString() ?? '',
  );
}

class ItineraryDayData {
  final String dayLabel;
  final List<ItineraryItemData> items;

  const ItineraryDayData({required this.dayLabel, required this.items});

  Map<String, dynamic> toMap() => {
    'dayLabel': dayLabel,
    'items': items.map((e) => e.toMap()).toList(),
  };

  factory ItineraryDayData.fromMap(Map<String, dynamic> m) => ItineraryDayData(
    dayLabel: m['dayLabel']?.toString() ?? '',
    items: (m['items'] as List<dynamic>? ?? [])
        .map((e) => ItineraryItemData.fromMap(e as Map<String, dynamic>))
        .toList(),
  );
}

// ── 資料模型 ─────────────────────────────────────────────────────

class CommunityPost {
  final String id;
  final String authorUid;
  final String authorName;
  final String authorAvatar;
  final String content;
  final String type;
  final String imageUrl;
  final String? locationName;
  final double? locationLat;
  final double? locationLon;
  final int likesCount;
  final bool isLikedByMe;
  final bool isFavoriteByMe;
  final DateTime createdAt;
  final String? itineraryId;
  final String? itineraryTitle;
  final int? itineraryDays;
  final int? itineraryBudget;
  final List<ItineraryDayData>? itineraryDayPlans;

  CommunityPost({
    required this.id,
    required this.authorUid,
    required this.authorName,
    required this.authorAvatar,
    required this.content,
    required this.type,
    required this.imageUrl,
    this.locationName,
    this.locationLat,
    this.locationLon,
    required this.likesCount,
    this.isLikedByMe = false,
    this.isFavoriteByMe = false,
    required this.createdAt,
    this.itineraryId,
    this.itineraryTitle,
    this.itineraryDays,
    this.itineraryBudget,
    this.itineraryDayPlans,
  });

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'author_uid': authorUid,
    'author_name': authorName,
    'author_avatar': authorAvatar,
    'content': content,
    'type': type,
    'image_url': imageUrl,
    'location_name': locationName,
    'location_lat': locationLat,
    'location_lon': locationLon,
    'likes_count': likesCount,
    'itinerary_id': itineraryId,
    'itinerary_title': itineraryTitle,
    'itinerary_days': itineraryDays,
    'itinerary_budget': itineraryBudget,
    'itinerary_day_plans': itineraryDayPlans?.map((d) => d.toMap()).toList(),
    'created_at': FieldValue.serverTimestamp(),
  };

  factory CommunityPost.fromFirestore(
      Map<String, dynamic> data,
      String docId, {
        bool isLikedByMe = false,
        bool isFavoriteByMe = false,
      }) {
    final ts = data['created_at'];
    final createdAt = ts is Timestamp
        ? ts.toDate()
        : DateTime.tryParse(data['created_at']?.toString() ?? '') ?? DateTime.now();

    return CommunityPost(
      id: docId,
      authorUid: data['author_uid'] ?? '',
      authorName: data['author_name'] ?? '旅遊探險家',
      authorAvatar: data['author_avatar'] ?? '🦃',
      content: data['content'] ?? '',
      type: data['type'] ?? '其他',
      imageUrl: data['image_url'] ?? '',
      locationName: data['location_name'],
      locationLat: (data['location_lat'] as num?)?.toDouble(),
      locationLon: (data['location_lon'] as num?)?.toDouble(),
      likesCount: (data['likes_count'] as num?)?.toInt() ?? 0,
      isLikedByMe: isLikedByMe,
      isFavoriteByMe: isFavoriteByMe,
      itineraryId: data['itinerary_id'],
      itineraryTitle: data['itinerary_title']?.toString(),
      itineraryDays: (data['itinerary_days'] as num?)?.toInt(),
      itineraryBudget: (data['itinerary_budget'] as num?)?.toInt(),
      itineraryDayPlans: (data['itinerary_day_plans'] as List<dynamic>?)
          ?.map((d) => ItineraryDayData.fromMap(d as Map<String, dynamic>))
          .toList(),
      createdAt: createdAt,
    );
  }

  CommunityPost copyWith({
    int? likesCount,
    bool? isLikedByMe,
    bool? isFavoriteByMe,
  }) => CommunityPost(
    id: id,
    authorUid: authorUid,
    authorName: authorName,
    authorAvatar: authorAvatar,
    content: content,
    type: type,
    imageUrl: imageUrl,
    locationName: locationName,
    locationLat: locationLat,
    locationLon: locationLon,
    likesCount: likesCount ?? this.likesCount,
    isLikedByMe: isLikedByMe ?? this.isLikedByMe,
    isFavoriteByMe: isFavoriteByMe ?? this.isFavoriteByMe,
    createdAt: createdAt,
    itineraryId: itineraryId,
    itineraryTitle: itineraryTitle,
    itineraryDays: itineraryDays,
    itineraryBudget: itineraryBudget,
    itineraryDayPlans: itineraryDayPlans,
  );
}

// ── 服務主體 ─────────────────────────────────────────────────────

class CommunityPostService {
  static CommunityPostService? _instance;
  static CommunityPostService get instance =>
      _instance ??= CommunityPostService._();
  CommunityPostService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> get _postsRef =>
      _firestore.collection('community_posts');

  Future<List<CommunityPost>> fetchPosts({
    String? typeFilter,
    DocumentSnapshot? startAfter,
    int limit = 20,
  }) async {
    Query<Map<String, dynamic>> q = _postsRef
        .orderBy('created_at', descending: true)
        .limit(limit);

    if (typeFilter != null && typeFilter != '全部') {
      q = _postsRef
          .where('type', isEqualTo: typeFilter)
          .orderBy('created_at', descending: true)
          .limit(limit);
    }

    if (startAfter != null) {
      q = q.startAfterDocument(startAfter);
    }

    try {
      final snapshot = await q.get();
      final uid = _uid;
      Set<String> likedIds = {};
      Set<String> favIds = {};

      if (uid != null) {
        final likedSnap = await _firestore
            .collection('user_post_actions')
            .where('uid', isEqualTo: uid)
            .where('action', isEqualTo: 'like')
            .get();
        likedIds = likedSnap.docs.map((d) => d['post_id'] as String).toSet();

        final favSnap = await _firestore
            .collection('user_post_actions')
            .where('uid', isEqualTo: uid)
            .where('action', isEqualTo: 'favorite')
            .get();
        favIds = favSnap.docs.map((d) => d['post_id'] as String).toSet();
      }

      return snapshot.docs.map((doc) => CommunityPost.fromFirestore(
        doc.data(), doc.id,
        isLikedByMe: likedIds.contains(doc.id),
        isFavoriteByMe: favIds.contains(doc.id),
      )).toList();
    } catch (e) {
      debugPrint('⚠️ [Community] 讀取貼文失敗：$e');
      return [];
    }
  }

  Future<CommunityPost?> fetchPost(String postId) async {
    try {
      final doc = await _postsRef.doc(postId).get();
      if (!doc.exists) return null;
      final uid = _uid;
      bool liked = false;
      bool fav = false;
      if (uid != null) {
        final likeDoc = await _firestore
            .collection('user_post_actions')
            .doc('${uid}_like_$postId')
            .get();
        liked = likeDoc.exists;
        final favDoc = await _firestore
            .collection('user_post_actions')
            .doc('${uid}_favorite_$postId')
            .get();
        fav = favDoc.exists;
      }
      return CommunityPost.fromFirestore(doc.data()!, doc.id,
          isLikedByMe: liked, isFavoriteByMe: fav);
    } catch (e) {
      debugPrint('⚠️ [Community] 讀取單筆貼文失敗：$e');
      return null;
    }
  }

  Future<List<CommunityPost>> fetchMyPosts() async {
    final uid = _uid;
    if (uid == null) return [];
    try {
      // ★ 修正：移除 orderBy，避免需要 Firestore composite index 而靜默失敗
      //   改在 client 端依 createdAt 降冪排列
      final snapshot = await _postsRef
          .where('author_uid', isEqualTo: uid)
          .get();
      final posts = snapshot.docs
          .map((doc) => CommunityPost.fromFirestore(doc.data(), doc.id))
          .toList();
      posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return posts;
    } catch (e) {
      debugPrint('⚠️ [Community] 讀取我的貼文失敗：$e');
      return [];
    }
  }

  // 🌟 自動同步個人資料到舊貼文的強大功能
  Future<void> syncUserProfileToPosts(String newName, String newAvatarBase64) async {
    final uid = _uid;
    if (uid == null) return;

    try {
      final snapshot = await _postsRef.where('author_uid', isEqualTo: uid).get();

      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.update(doc.reference, {
          'author_name': newName,
          'author_avatar': newAvatarBase64,
        });
      }
      await batch.commit();
      debugPrint('✅ [Community] 成功將使用者的所有貼文更新為新頭貼與暱稱');
    } catch (e) {
      debugPrint('⚠️ [Community] 同步頭貼至貼文失敗：$e');
    }
  }

  Future<String?> publishPost({
    required String content,
    required String type,
    required String imageUrl,
    String? locationName,
    double? locationLat,
    double? locationLon,
    String? itineraryId,
    String? itineraryTitle,
    int? itineraryDays,
    int? itineraryBudget,
    List<ItineraryDayData>? itineraryDayPlans,
  }) async {
    final id = const Uuid().v4();
    final uid = _uid;

    if (uid == null) {
      debugPrint('⚠️ [Community] 未登入，無法發布貼文');
      return null;
    }

    // 🌟 【動態抓取真實大頭貼與名稱】強制優先尋找 avatarBase64
    String actualAuthorName = _auth.currentUser?.displayName ?? '旅遊探險家';
    String actualAuthorAvatar = '🦃'; // 極端情況的備用

    try {
      // 1. 優先嘗試用 Document ID (uid) 去抓 (速度最快)
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(uid).get();
      Map<String, dynamic>? uData;

      if (userDoc.exists && userDoc.data() != null) {
        uData = userDoc.data() as Map<String, dynamic>;
      } else {
        // 2. 如果使用者的 doc ID 不是 uid，改用 where 去尋找
        final userSnap = await _firestore.collection('users').where('uid', isEqualTo: uid).limit(1).get();
        if (userSnap.docs.isNotEmpty) {
          uData = userSnap.docs.first.data();
        }
      }

      if (uData != null) {
        if (uData['displayName'] != null && uData['displayName'].toString().isNotEmpty) {
          actualAuthorName = uData['displayName'];
        }

        // 🌟 絕對優先採用 avatarBase64！
        if (uData['avatarBase64'] != null && uData['avatarBase64'].toString().length > 100) {
          actualAuthorAvatar = uData['avatarBase64'];
        } else if (uData['photoUrl'] != null && uData['photoUrl'].toString().isNotEmpty) {
          actualAuthorAvatar = uData['photoUrl'];
        } else if (_auth.currentUser?.photoURL != null) {
          actualAuthorAvatar = _auth.currentUser!.photoURL!;
        }
      } else if (_auth.currentUser?.photoURL != null) {
        actualAuthorAvatar = _auth.currentUser!.photoURL!;
      }
    } catch (e) {
      debugPrint('⚠️ [Community] 取得使用者真實大頭貼失敗：$e');
      if (_auth.currentUser?.photoURL != null) {
        actualAuthorAvatar = _auth.currentUser!.photoURL!;
      }
    }

    final post = CommunityPost(
      id: id,
      authorUid: uid,
      authorName: actualAuthorName,
      authorAvatar: actualAuthorAvatar, // 🌟 綁定使用者實際頭像
      content: content,
      type: type,
      imageUrl: imageUrl,
      locationName: locationName,
      locationLat: locationLat,
      locationLon: locationLon,
      likesCount: 0,
      createdAt: DateTime.now(),
      itineraryId: itineraryId,
      itineraryTitle: itineraryTitle,
      itineraryDays: itineraryDays,
      itineraryBudget: itineraryBudget,
      itineraryDayPlans: itineraryDayPlans,
    );

    try {
      await _postsRef.doc(id).set(post.toFirestore());
      debugPrint('✅ [Community] 貼文已發布：$id');
      return id;
    } catch (e) {
      debugPrint('⚠️ [Community] 發布貼文失敗：$e');
      return null;
    }
  }

  Future<int> toggleLike(String postId, bool currentlyLiked, int currentCount) async {
    final uid = _uid;
    if (uid == null) return currentCount;

    final actionDocId = '${uid}_like_$postId';
    final actionRef = _firestore.collection('user_post_actions').doc(actionDocId);
    final postRef = _postsRef.doc(postId);

    try {
      if (currentlyLiked) {
        await actionRef.delete();
        await postRef.update({'likes_count': FieldValue.increment(-1)});
        return currentCount - 1;
      } else {
        await actionRef.set({
          'uid': uid,
          'post_id': postId,
          'action': 'like',
          'created_at': FieldValue.serverTimestamp(),
        });
        await postRef.update({'likes_count': FieldValue.increment(1)});
        return currentCount + 1;
      }
    } catch (e) {
      debugPrint('⚠️ [Community] 按讚操作失敗：$e');
      return currentCount;
    }
  }

  Future<void> toggleFavorite(String postId, bool currentlyFav) async {
    final uid = _uid;
    if (uid == null) return;

    final actionDocId = '${uid}_favorite_$postId';
    final actionRef = _firestore.collection('user_post_actions').doc(actionDocId);

    try {
      if (currentlyFav) {
        await actionRef.delete();
      } else {
        await actionRef.set({
          'uid': uid,
          'post_id': postId,
          'action': 'favorite',
          'created_at': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('⚠️ [Community] 收藏操作失敗：$e');
    }
  }

  Future<bool> deletePost(String postId) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final doc = await _postsRef.doc(postId).get();
      if (doc.data()?['author_uid'] != uid) return false;
      await _postsRef.doc(postId).delete();
      return true;
    } catch (e) {
      debugPrint('⚠️ [Community] 刪除貼文失敗：$e');
      return false;
    }
  }
  Future<int> countMyLocalPosts() async {
    try {
      final uid = _uid ?? '';
      if (uid.isEmpty) return 0;
      final sessions = await LocalDbService.instance.getAllSessions();
      return sessions.where((s) =>
      s.mode == 'community_post' && s.title.startsWith('[$uid]')
      ).length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clearMyCachedPosts() async {
    try {
      await LocalDbService.instance.clearCommunityPostSessions();
    } catch (e) {
      debugPrint('⚠️ [Community] 清除本地貼文快取失敗：$e');
    }
  }

  // 1. 新增留言
  Future<bool> addComment(String postId, String content) async {
    final uid = _uid; // 假設你 Service 中有取得當前使用者 UID 的變數
    if (uid == null || uid.isEmpty) return false;

    try {
      // 獲取當前使用者的名稱與頭貼 (請替換為你實際獲取當前使用者資料的邏輯，例如從 LocalDb 或 Firestore users 集合)
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final authorName = userData['name'] ?? '匿名使用者';
      final authorAvatar = userData['avatar'] ?? '';

      // 建立 comments 子集合的 Reference
      final commentRef = _firestore
          .collection('community_posts')
          .doc(postId)
          .collection('comments')
          .doc();

      // 寫入留言
      await commentRef.set({
        'id': commentRef.id,
        'post_id': postId,
        'author_uid': uid,
        'author_name': authorName,
        'author_avatar': authorAvatar,
        'content': content,
        'created_at': FieldValue.serverTimestamp(),
      });

      // 可選：更新貼文主體的 comments_count (方便 UI 直接顯示留言數)
      await _firestore.collection('community_posts').doc(postId).update({
        'comments_count': FieldValue.increment(1),
      });

      return true;
    } catch (e) {
      debugPrint('⚠️ [Community] 新增留言失敗：$e');
      return false;
    }
  }

  // 2. 獲取特定貼文的留言 Stream (即時更新)
  Stream<QuerySnapshot> getCommentsStream(String postId) {
    return _firestore
        .collection('community_posts')
        .doc(postId)
        .collection('comments')
        .orderBy('created_at', descending: false) // false 代表舊留言在最上面
        .snapshots();
  }
}