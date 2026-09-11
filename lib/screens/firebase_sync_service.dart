// ═══════════════════════════════════════════════════════════════
//  firebase_sync_service.dart ★ 終極完整保留同步版 ★
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart' as sqflite show ConflictAlgorithm;
import 'local_db_service.dart';
import 'community_post_service.dart';
import 'shared_budget_service.dart';

class FirebaseSyncService {
  static FirebaseSyncService? _instance;
  static FirebaseSyncService get instance => _instance ??= FirebaseSyncService._();
  FirebaseSyncService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth      = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? get _itinerariesRef {
    final uid = _uid;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('itineraries');
  }

  CollectionReference<Map<String, dynamic>>? get _budgetRecordsRef {
    final uid = _uid;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('budget_records');
  }

  CollectionReference<Map<String, dynamic>>? get _budgetConfigsRef {
    final uid = _uid;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('budget_configs');
  }

  // ── 行程同步功能保留 ───────────────────────────────────────────

  Future<void> saveItinerary(SavedItinerary itinerary) async {
    await LocalDbService.instance.insertItinerary(itinerary);
    _pushItineraryToCloud(itinerary).catchError((e) {
      debugPrint('⚠️ [Sync] 行程推送雲端失敗：$e');
    });
  }

  Future<void> updateItinerary(SavedItinerary itinerary) async {
    await LocalDbService.instance.updateItinerary(itinerary);
    _pushItineraryToCloud(itinerary).catchError((e) {
      debugPrint('⚠️ [Sync] 行程推送雲端失敗：$e');
    });
  }

  Future<void> deleteItinerary(String id) async {
    final uid = _uid ?? '';
    await LocalDbService.instance.deleteItinerary(id, userId: uid);
    final ref = _itinerariesRef;
    if (ref == null) return;
    // ★ 修復：優先真正刪除雲端文件（delete），而非只打墓碑。
    //   真刪才能確保 Firebase Console 不會殘留舊紀錄。
    //   若離線導致刪除失敗，退而補打墓碑，待下次同步時再補刪。
    try {
      await ref.doc(id).delete();
      debugPrint('🗑️ [Sync] 行程已從雲端真正刪除：$id');
    } catch (e) {
      debugPrint('⚠️ [Sync] 雲端刪除失敗，改打墓碑待下次補刪：$e');
      try {
        await ref.doc(id).set(
          {'deleted_at': FieldValue.serverTimestamp(), 'id': id},
          SetOptions(merge: true),
        );
        debugPrint('🗑️ [Sync] 行程墓碑標記（fallback）成功：$id');
      } catch (e2) {
        debugPrint('⚠️ [Sync] 墓碑 fallback 也失敗（本地已刪，下次同步補標）：$e2');
      }
    }
  }

  // ── 預算與明細同步功能完全保留 ───────────────────────────────────────────

  Future<void> saveBudgetRecord(BudgetRecord record) async {
    await LocalDbService.instance.insertBudgetRecord(record);
    _pushBudgetRecordToCloud(record).catchError((e) {
      debugPrint('⚠️ [Sync] 消費紀錄推送失敗：$e');
    });
  }

  Future<void> deleteBudgetRecord(String recordId) async {
    await LocalDbService.instance.deleteBudgetRecord(recordId);
    final ref = _budgetRecordsRef;
    if (ref == null) return;
    ref.doc(recordId).set(
      {'deleted_at': FieldValue.serverTimestamp(), 'id': recordId},
      SetOptions(merge: true),
    ).catchError((e) {
      debugPrint('⚠️ [Sync] 消費紀錄雲端標記失敗：$e');
    });
  }

  Future<void> saveBudgetConfig(ItineraryBudgetConfig config) async {
    await LocalDbService.instance.saveBudgetConfig(config);
    _pushBudgetConfigToCloud(config).catchError((e) {
      debugPrint('⚠️ [Sync] 預算設定推送失敗：$e');
    });
  }

  // ── 開機/重登備份還原機制 完整保留 ───────────────────────────────────────────
  Future<void> syncFromFirebase() async {
    final uid = _uid;
    if (uid == null) return;

    await _pullItinerariesFromCloud();
    await _pullBudgetDataFromCloud();
    await _pullAiSessionsFromCloud();
    await _pullSharedBudgetsFromCloud(uid);
  }

  Future<void> signOut() async {
    final uid = _uid ?? '';
    await LocalDbService.instance.clearAllData();
    if (uid.isNotEmpty) {
      await LocalDbService.instance.clearItinerariesForUser(uid);
    }
    await CommunityPostService.instance.clearMyCachedPosts();
    await _auth.signOut();
    debugPrint('✅ 登出完成，本地快取已安全清理');
  }

  // uploadToFirebase 已不再使用 backup，改為空方法保留相容性
  Future<void> uploadToFirebase() async {}

  // ★ 推送單一 AI 對話 session 到 Firebase（在每次對話結束後呼叫）
  // 這樣不需要等到登出才備份，確保對話紀錄即時同步
  Future<void> pushSessionToCloud(String sessionId) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final session = await LocalDbService.instance.getSession(sessionId);
      if (session == null) return;
      final messages = await LocalDbService.instance.getMessagesForSession(sessionId);
      final sessionData = {
        'session': session.toMap(),
        'messages': messages.map((m) => m.toMap()).toList(),
        'synced_at': FieldValue.serverTimestamp(),
      };
      await _firestore
          .collection('users').doc(uid)
          .collection('ai_sessions').doc(sessionId)
          .set(sessionData, SetOptions(merge: true));
      debugPrint('☁️ [AI] session 已推送雲端：$sessionId');
    } catch (e) {
      debugPrint('⚠️ [AI] session 推送失敗：$e');
    }
  }

  // ★ 從 Firebase ai_sessions 拉取所有對話（syncFromFirebase 時呼叫）
  Future<void> _pullAiSessionsFromCloud() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final snap = await _firestore
          .collection('users').doc(uid)
          .collection('ai_sessions')
          .orderBy('session.updated_at', descending: false)
          .get();
      int added = 0;
      for (final doc in snap.docs) {
        try {
          final data = doc.data();
          final sessionMap = data['session'] as Map<String, dynamic>?;
          final messagesList = data['messages'] as List<dynamic>?;
          if (sessionMap == null) continue;
          final sessionId = sessionMap['id'] as String?;
          if (sessionId == null) continue;
          // merge：本地已有就跳過
          final existing = await LocalDbService.instance.getSession(sessionId);
          if (existing != null) continue;
          await LocalDbService.instance.insertSession(ChatSession.fromMap(sessionMap));
          for (final msg in (messagesList ?? [])) {
            await LocalDbService.instance.insertMessage(
                ChatMessageRecord.fromMap(msg as Map<String, dynamic>));
          }
          added++;
        } catch (_) {}
      }
      debugPrint('✅ [AI] 從雲端補入 $added 個 session');
    } catch (e) {
      debugPrint('⚠️ [AI] 拉取 ai_sessions 失敗：$e');
    }
  }

  Future<void> ensureUserProfile() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final ref = _firestore.collection('users').doc(user.uid);
      final doc = await ref.get();

      final email = (user.email ?? '').toLowerCase();
      final fallbackName = email.isNotEmpty ? email.split('@').first : '旅遊探險家';
      final displayName = (user.displayName != null && user.displayName!.trim().isNotEmpty) ? user.displayName! : fallbackName;

      if (!doc.exists) {
        await ref.set({
          'uid': user.uid, 'email': email, 'displayName': displayName, 'photoUrl': user.photoURL ?? '', 'createdAt': FieldValue.serverTimestamp(), 'lastLogin': FieldValue.serverTimestamp(),
        });
        if (user.displayName == null || user.displayName!.trim().isEmpty) {
          await user.updateDisplayName(displayName).catchError((_) {});
        }
      } else {
        final existingData = doc.data() ?? {};
        final storedName = existingData['displayName'] as String? ?? '';
        await ref.update({
          'lastLogin': FieldValue.serverTimestamp(), 'email': email, if (storedName.isEmpty || storedName == '旅遊探險家') 'displayName': displayName,
        });
        if (user.displayName == null || user.displayName!.trim().isEmpty) {
          await user.updateDisplayName(storedName.isNotEmpty ? storedName : displayName).catchError((_) {});
        }
      }
    } catch (e) {
      debugPrint('⚠️ 建立使用者資料失敗：$e');
    }
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      return doc.data();
    } catch (_) { return null; }
  }

  // ═══════════════════════════════════════════════════════════
  //  私有輔助推送方法（★ Bug 1 核心復活修復點）
  // ═══════════════════════════════════════════════════════════

  Future<void> _pushItineraryToCloud(SavedItinerary itinerary) async {
    final ref = _itinerariesRef;
    if (ref == null) return;

    // ★ 修正：明確設定 deleted_at: null，防止舊墓碑標記讓新存的行程在雲端「消失」
    //   （若之前同 id 曾被刪除留下 deleted_at，merge:true 不會清除它，導致撈不回來）
    final Map<String, dynamic> doc = {
      ...itinerary.toMap(),
      'synced_at': FieldValue.serverTimestamp(),
      'deleted_at': null,  // ★ 強制清除墓碑
    };
    await ref.doc(itinerary.id).set(doc, SetOptions(merge: true));
    debugPrint('☁️ [Sync] 行程已推送：${itinerary.title}');
  }

  Future<void> _pushBudgetRecordToCloud(BudgetRecord record) async {
    final ref = _budgetRecordsRef;
    if (ref == null) return;
    await ref.doc(record.id).set({
      ...record.toMap(), 'synced_at': FieldValue.serverTimestamp(), 'deleted_at': null,
    }, SetOptions(merge: true));
  }

  Future<void> _pushBudgetConfigToCloud(ItineraryBudgetConfig config) async {
    final ref = _budgetConfigsRef;
    if (ref == null) return;
    await ref.doc(config.itineraryId).set({
      ...config.toMap(), 'synced_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _pullItinerariesFromCloud() async {
    final ref = _itinerariesRef;
    final uid = _uid;
    if (ref == null || uid == null) return;

    try {
      // ★ Bug 1 修復 Step 1：先把「本地已刪但雲端可能漏打墓碑」的 ID 全部補推雲端，
      //   確保下方拉取時這些 ID 都已帶 deleted_at，不會被 where('deleted_at', isNull: true) 拉回來。
      final localDeletedIds = (await LocalDbService.instance.getDeletedIds(userId: uid)).toSet();
      if (localDeletedIds.isNotEmpty) {
        final tombstoneChecks = await Future.wait(
          localDeletedIds.map((id) => ref.doc(id).get()),
        );
        for (final doc in tombstoneChecks) {
          final data = doc.data();
          if (doc.exists && data != null && data['deleted_at'] == null) {
            try {
              await ref.doc(doc.id).set(
                {'deleted_at': FieldValue.serverTimestamp(), 'id': doc.id},
                SetOptions(merge: true),
              );
              debugPrint('🗑️ [Sync] 補打雲端墓碑：${doc.id}');
            } catch (_) {}
          }
        }
      }

      final snapshot = await ref.where('deleted_at', isNull: true).get();

      int merged = 0;
      for (final doc in snapshot.docs) {
        final id   = doc.id;
        final data = doc.data();

        if (localDeletedIds.contains(id)) {
          // 雙重保險：已在本地刪除，確保雲端也打上墓碑
          ref.doc(id).set({'deleted_at': FieldValue.serverTimestamp()}, SetOptions(merge: true));
          continue;
        }

        try {
          final normalized = _normalizeTimestamps(data);
          normalized['user_id'] = uid;  // ★ 確保 user_id 一定是當前登入者
          final itinerary = SavedItinerary.fromMap({...normalized, 'id': id});
          // ★ insertItinerary 內部已使用 ConflictAlgorithm.replace，
          //   會正確覆蓋舊的 user_id 為空字串的記錄
          await LocalDbService.instance.insertItinerary(itinerary);
          merged++;
        } catch (_) {}
      }

      final deletedSnap = await ref.where('deleted_at', isNull: false).get();
      for (final doc in deletedSnap.docs) {
        final localItem = await LocalDbService.instance.getItinerary(doc.id);
        if (localItem != null) {
          await LocalDbService.instance.deleteItinerary(doc.id, userId: uid);
        }
      }
      debugPrint('✅ [Sync] 行程同步完成（uid=$uid）');
    } catch (_) {}
  }

  Future<void> _pullBudgetDataFromCloud() async {
    final uid = _uid;
    if (uid == null) return;

    try {
      final ref = _budgetRecordsRef;
      if (ref != null) {
        final deletedSnap = await ref.where('deleted_at', isNull: false).get();
        for (final doc in deletedSnap.docs) {
          try { await LocalDbService.instance.deleteBudgetRecord(doc.id); } catch (_) {}
        }

        final snap = await ref.where('deleted_at', isNull: true).get();
        for (final doc in snap.docs) {
          try {
            final data = Map<String, dynamic>.from(doc.data());
            data.remove('synced_at');
            data.remove('deleted_at');
            if (data['created_at'] is Timestamp) {
              data['created_at'] = (data['created_at'] as Timestamp).toDate().toIso8601String();
            }
            data['user_id'] = uid;
            await LocalDbService.instance.insertBudgetRecord(BudgetRecord.fromMap({...data, 'id': doc.id}));
          } catch (_) {}
        }
      }
    } catch (_) {}

    try {
      final ref = _budgetConfigsRef;
      if (ref != null) {
        final snap = await ref.get();
        for (final doc in snap.docs) {
          try {
            final data = Map<String, dynamic>.from(doc.data());
            data.remove('synced_at');
            if (data['updated_at'] is Timestamp) {
              data['updated_at'] = (data['updated_at'] as Timestamp).toDate().toIso8601String();
            }
            data['user_id'] = uid;
            await LocalDbService.instance.saveBudgetConfig(ItineraryBudgetConfig.fromMap({...data, 'itinerary_id': doc.id}));
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Map<String, dynamic> _normalizeTimestamps(Map<String, dynamic> data) {
    final result = Map<String, dynamic>.from(data);
    for (final key in ['created_at', 'updated_at', 'start_date', 'end_date']) {
      final val = result[key];
      if (val is Timestamp) {
        result[key] = val.toDate().toIso8601String();
      } else if (val == null) {
        result[key] = DateTime.now().toIso8601String();
      }
    }
    result.remove('synced_at');
    result.remove('deleted_at');
    return result;
  }

  Future<void> syncBudgetForItinerary({
    required String itineraryId,
    required int budgetLimit,
    required String uid,
  }) async {
    try {
      final config = ItineraryBudgetConfig(
        itineraryId: itineraryId, userId: uid, budgetLimit: budgetLimit, isMultiMode: true, membersJson: '[]', updatedAt: DateTime.now(),
      );
      await LocalDbService.instance.saveBudgetConfig(config);
    } catch (_) {}
  }

  // ★ Fix-Bug3：重登後同步拉取共享預算房間（多人分帳資料不在個人備份路徑）
  //   1. 查詢 memberUids 陣列包含自己的所有 shared_budgets
  //   2. 若對應的本地行程骨架不存在，自動補建（確保卡片出現在首頁）
  //   3. 將 budgetConfig 同步寫入本地，標記 isMultiMode=true
  Future<void> _pullSharedBudgetsFromCloud(String uid) async {
    try {
      final snap = await _firestore
          .collection('shared_budgets')
          .where('memberUids', arrayContains: uid)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        final kickedUids = List<dynamic>.from(data['kickedUids'] as List? ?? []);
        if (kickedUids.contains(uid)) continue; // 已被踢出，跳過

        final budgetId   = doc.id;
        final itineraryId = data['itineraryId'] as String?;
        final title      = data['title'] as String? ?? '共享行程';
        final totalBudget = data['totalBudget'] as int? ?? 0;

        // ── 若有綁定行程 ID，確保本地行程骨架存在 ──
        if (itineraryId != null && itineraryId.isNotEmpty) {
          final existing = await LocalDbService.instance.getItinerary(itineraryId);
          if (existing == null) {
            // 補建本地行程骨架，讓 UI 首頁卡片可以顯示
            try {
              final nowStr = DateTime.now().toIso8601String();
              final db = await LocalDbService.instance.db;
              await db.insert('saved_itineraries', {
                'id': itineraryId,
                'user_id': uid,
                'title': title,
                'estimated_budget': totalBudget,
                'start_date': nowStr,
                'end_date': nowStr,
                'plans_json': '[]',
                'is_from_ai': 0,
                'created_at': nowStr,
                'updated_at': nowStr,
              }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
              debugPrint('🏗️ [Sync] 補建共享行程骨架：$title ($itineraryId)');
            } catch (e) {
              debugPrint('⚠️ [Sync] 補建骨架失敗：$e');
            }
          }

          // 同步寫入多人 budgetConfig
          try {
            final membersRaw = (data['members'] as List<dynamic>? ?? [])
                .map((m) => (m as Map<String, dynamic>)['displayName']?.toString() ?? '成員')
                .toList();
            final config = ItineraryBudgetConfig(
              itineraryId: itineraryId,
              userId: uid,
              budgetLimit: totalBudget,
              isMultiMode: true,
              membersJson: jsonEncode(membersRaw),
              updatedAt: DateTime.now(),
            );
            await LocalDbService.instance.saveBudgetConfig(config);
          } catch (_) {}
        }

        debugPrint('✅ [Sync] 共享預算同步完成：$title (budgetId=$budgetId)');
      }
    } catch (e) {
      debugPrint('⚠️ [Sync] 共享預算同步失敗：$e');
    }
  }
}