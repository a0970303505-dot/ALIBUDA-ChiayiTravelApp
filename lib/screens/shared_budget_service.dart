// ═══════════════════════════════════════════════════════════════
//  shared_budget_service.dart  ★ 完美修正無錯版 v6 ★
// ═══════════════════════════════════════════════════════════════

import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────
//  資料模型
// ──────────────────────────────────────────────────────────────

class SharedBudgetMember {
  final String uid;
  final String displayName;
  final String email;
  final String role; // 'owner' | 'editor'
  final DateTime joinedAt;

  const SharedBudgetMember({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.role,
    required this.joinedAt,
  });

  bool get isOwner => role == 'owner';

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'displayName': displayName,
    'email': email,
    'role': role,
    'joinedAt': joinedAt.toIso8601String(),
  };

  factory SharedBudgetMember.fromMap(Map<String, dynamic> m) {
    DateTime parsedDate = DateTime.now();
    if (m['joinedAt'] != null) {
      final dynamic ja = m['joinedAt'];
      if (ja is Timestamp) {
        parsedDate = ja.toDate();
      } else if (ja is String) {
        try { parsedDate = DateTime.parse(ja); } catch (_) {}
      }
    }

    return SharedBudgetMember(
      uid: m['uid'] ?? '',
      displayName: m['displayName'] ?? '使用者',
      email: m['email'] ?? '',
      role: m['role'] ?? 'editor',
      joinedAt: parsedDate,
    );
  }
}

class SharedBudgetRecord {
  final String id;
  final String title;
  final String category;
  final int amount;
  final String payerUid;
  final String payerName;
  final String createdBy;
  final String note;
  final DateTime createdAt;
  final int? createdAtMs;
  final DateTime? deletedAt;
  // ★ 新增：參與分攤的成員 UID 清單（空 = 全員均攤）
  final List<String> splitParticipants;

  const SharedBudgetRecord({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.payerUid,
    required this.payerName,
    required this.createdBy,
    required this.note,
    required this.createdAt,
    this.createdAtMs,
    this.deletedAt,
    this.splitParticipants = const [],
  });

  Map<String, dynamic> toMap() => {
    'title': title,
    'category': category,
    'amount': amount,
    'payerUid': payerUid,
    'payerName': payerName,
    'createdBy': createdBy,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
    'createdAtMs': createdAtMs ?? createdAt.millisecondsSinceEpoch,
    'deleted_at': deletedAt?.toIso8601String(),
    // ★ 新增：空清單代表全員均攤，不佔空間
    'splitParticipants': splitParticipants,
  };

  factory SharedBudgetRecord.fromDoc(DocumentSnapshot doc) {
    return SharedBudgetRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  // ★ 核心修復：補上這個被 UI 流呼叫的方法，徹底消滅未定義問題
  factory SharedBudgetRecord.fromMap(Map<String, dynamic> m, String documentId) {
    DateTime parsedCreated = DateTime.now();
    if (m['createdAt'] != null) {
      final dynamic ca = m['createdAt'];
      if (ca is Timestamp) {
        parsedCreated = ca.toDate();
      } else if (ca is String) {
        try { parsedCreated = DateTime.parse(ca); } catch (_) {}
      }
    }

    DateTime? parsedDeletedAt;
    if (m['deleted_at'] != null) {
      final dynamic da = m['deleted_at'];
      if (da is Timestamp) {
        parsedDeletedAt = da.toDate();
      } else if (da is String) {
        try { parsedDeletedAt = DateTime.parse(da); } catch (_) {}
      }
    }

    return SharedBudgetRecord(
      id: documentId,
      title: m['title'] ?? '',
      category: m['category'] ?? '其他',
      amount: m['amount'] ?? 0,
      payerUid: m['payerUid'] ?? '',
      payerName: m['payerName'] ?? '使用者',
      createdBy: m['createdBy'] ?? '',
      note: m['note'] ?? '',
      createdAt: parsedCreated,
      createdAtMs: m['createdAtMs'] as int?,
      deletedAt: parsedDeletedAt,
      // ★ 新增：從 Firestore 讀回時解析，舊資料沒有此欄位預設空清單（= 全員均攤）
      splitParticipants: (m['splitParticipants'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class SharedBudget {
  final String id;
  final String title;
  final int totalBudget;
  final String ownerUid;
  final String ownerName;
  final List<SharedBudgetMember> members;
  final List<dynamic> historyLogs;
  final List<dynamic> kickedUids;
  final String? itineraryId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SharedBudget({
    required this.id,
    required this.title,
    required this.totalBudget,
    required this.ownerUid,
    required this.ownerName,
    required this.members,
    required this.historyLogs,
    required this.kickedUids,
    this.itineraryId,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isOwner =>
      ownerUid == FirebaseAuth.instance.currentUser?.uid;

  factory SharedBudget.fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;

    final membersList = (m['members'] as List<dynamic>? ?? [])
        .map((e) => SharedBudgetMember.fromMap(e as Map<String, dynamic>))
        .toList();

    DateTime parsedCreated = DateTime.now();
    if (m['createdAt'] != null) {
      final dynamic ca = m['createdAt'];
      if (ca is Timestamp) {
        parsedCreated = ca.toDate();
      } else if (ca is String) {
        try { parsedCreated = DateTime.parse(ca); } catch (_) {}
      }
    }

    DateTime parsedUpdated = DateTime.now();
    if (m['updatedAt'] != null) {
      final dynamic ua = m['updatedAt'];
      if (ua is Timestamp) {
        parsedUpdated = ua.toDate();
      } else if (ua is String) {
        try { parsedUpdated = DateTime.parse(ua); } catch (_) {}
      }
    }

    return SharedBudget(
      id: doc.id,
      title: m['title'] ?? '共享行程',
      totalBudget: m['totalBudget'] ?? 0,
      ownerUid: m['ownerUid'] ?? '',
      ownerName: m['ownerName'] ?? '使用者',
      members: membersList,
      historyLogs: m['historyLogs'] as List<dynamic>? ?? [],
      kickedUids: m['kickedUids'] as List<dynamic>? ?? [],
      itineraryId: m['itineraryId'],
      createdAt: parsedCreated,
      updatedAt: parsedUpdated,
    );
  }
}

class SharedBudgetInvite {
  final String budgetId;
  final String title;
  final String ownerName;
  final String ownerUid;
  final String status;
  final DateTime invitedAt;

  const SharedBudgetInvite({
    required this.budgetId,
    required this.title,
    required this.ownerName,
    required this.ownerUid,
    required this.status,
    required this.invitedAt,
  });

  factory SharedBudgetInvite.fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;

    DateTime parsedInvited = DateTime.now();
    if (m['invitedAt'] != null) {
      final dynamic ia = m['invitedAt'];
      if (ia is Timestamp) {
        parsedInvited = ia.toDate();
      } else if (ia is String) {
        try { parsedInvited = DateTime.parse(ia); } catch (_) {}
      }
    }

    return SharedBudgetInvite(
      budgetId: doc.id,
      title: m['title'] ?? '',
      ownerName: m['ownerName'] ?? '使用者',
      ownerUid: m['ownerUid'] ?? '',
      status: m['status'] ?? 'pending',
      invitedAt: parsedInvited,
    );
  }
}

class SettlementEntry {
  final String fromUid;
  final String fromName;
  final String toUid;
  final String toName;
  final int amount;

  const SettlementEntry({
    required this.fromUid,
    required this.fromName,
    required this.toUid,
    required this.toName,
    required this.amount,
  });
}

class SharedBudgetService {
  static SharedBudgetService? _instance;
  static SharedBudgetService get instance => _instance ??= SharedBudgetService._();
  SharedBudgetService._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? get _uid  => _auth.currentUser?.uid;
  String  get _name => _auth.currentUser?.displayName ?? '使用者';
  String  get _email => _auth.currentUser?.email ?? '';

  Future<String?> createSharedBudget({
    required String title,
    required int totalBudget,
    String? itineraryId,
  }) async {
    final uid = _uid;
    if (uid == null) return null;

    try {
      final docRef = _db.collection('shared_budgets').doc();
      final now = FieldValue.serverTimestamp();

      final ownerMember = SharedBudgetMember(
        uid: uid,
        displayName: _name,
        email: _email,
        role: 'owner',
        joinedAt: DateTime.now(),
      );

      await docRef.set({
        'title': title,
        'totalBudget': totalBudget,
        'ownerUid': uid,
        'ownerName': _name,
        'members': [ownerMember.toMap()],
        'memberUids': [uid],
        'kickedUids': [],
        'historyLogs': [
          {
            'uid': uid,
            'userName': _name,
            'action': '建立了共享房間',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ],
        'itineraryId': itineraryId,
        'createdAt': now,
        'updatedAt': now,
      });

      return docRef.id;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 建立失敗：$e');
      return null;
    }
  }

  Future<void> logOpenAction(String budgetId, String userName) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _db.collection('shared_budgets').doc(budgetId).update({
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': userName,
            'action': '打開了管理頁面',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });
    } catch (_) {}
  }

  Future<Map<String, String>?> findUserByEmail(String email) async {
    if (email.isEmpty) return null;
    try {
      final snap = await _db
          .collection('users')
          .where('email', isEqualTo: email.trim().toLowerCase())
          .limit(1)
          .get();

      if (snap.docs.isEmpty) return null;
      final d = snap.docs.first.data();
      return {
        'uid': snap.docs.first.id,
        'displayName': d['displayName'] ?? '使用者',
        'email': d['email'] ?? email,
      };
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 搜尋使用者失敗：$e');
      return null;
    }
  }

  Future<bool> sendInvite({
    required String budgetId,
    required String budgetTitle,
    required String targetUid,
    required String targetEmail,
  }) async {
    final uid = _uid;
    if (uid == null || targetUid == uid) return false;

    try {
      final budgetDoc = await _db.collection('shared_budgets').doc(budgetId).get();
      if (!budgetDoc.exists) return false;

      final budgetData = budgetDoc.data()!;
      final members = (budgetData['members'] as List<dynamic>? ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList();

      final alreadyMember = members.any((m) => m['uid'] == targetUid);
      if (alreadyMember) return false;

      await _db
          .collection('users')
          .doc(targetUid)
          .collection('shared_budget_invites')
          .doc(budgetId)
          .set({
        'budgetId': budgetId,
        'title': budgetTitle,
        'ownerName': budgetData['ownerName'] ?? _name,
        'ownerUid': budgetData['ownerUid'] ?? uid,
        'status': 'pending',
        'invitedAt': FieldValue.serverTimestamp(),
        'invitedBy': uid,
        'invitedByName': _name,
        'targetEmail': targetEmail,
      });

      await _db.collection('shared_budgets').doc(budgetId).update({
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '發送邀請信給了 $targetEmail',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });
      return true;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 邀請失敗：$e');
      return false;
    }
  }

  Future<SharedBudget?> acceptInvite(String budgetId) async {
    final uid = _uid;
    if (uid == null) return null;

    try {
      final budgetDoc = await _db.collection('shared_budgets').doc(budgetId).get();
      if (!budgetDoc.exists) return null;

      final data = budgetDoc.data()!;
      final kickedList = data['kickedUids'] as List<dynamic>? ?? [];
      if (kickedList.contains(uid)) return null;

      final existingMembers = data['members'] as List<dynamic>? ?? [];
      final alreadyMember = existingMembers.any((m) => (m as Map)['uid'] == uid);

      if (!alreadyMember) {
        final batch = _db.batch();
        final member = SharedBudgetMember(
          uid: uid,
          displayName: _name,
          email: _email,
          role: 'editor',
          joinedAt: DateTime.now(),
        );

        batch.update(_db.collection('shared_budgets').doc(budgetId), {
          'members': FieldValue.arrayUnion([member.toMap()]),
          'memberUids': FieldValue.arrayUnion([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
          'historyLogs': FieldValue.arrayUnion([
            {
              'uid': uid,
              'userName': _name,
              'action': '接受邀請並加入了共享記帳',
              'timestamp': DateTime.now().toIso8601String(),
            }
          ])
        });

        batch.update(
          _db.collection('users').doc(uid).collection('shared_budget_invites').doc(budgetId),
          {'status': 'accepted'},
        );
        await batch.commit();
      }

      final updatedDoc = await _db.collection('shared_budgets').doc(budgetId).get();
      return SharedBudget.fromDoc(updatedDoc);
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 接受邀請失敗：$e');
      return null;
    }
  }

  Future<void> declineInvite(String budgetId) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _db
          .collection('users')
          .doc(uid)
          .collection('shared_budget_invites')
          .doc(budgetId)
          .update({'status': 'declined'});
    } catch (_) {}
  }

  Future<List<SharedBudget>> getMySharedBudgets() async {
    final uid = _uid;
    if (uid == null) return [];
    try {
      final snap = await _db
          .collection('shared_budgets')
          .where('memberUids', arrayContains: uid)
          .get();
      return snap.docs
          .map(SharedBudget.fromDoc)
          .where((b) => !b.kickedUids.contains(uid))
          .toList();
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 取得列表失敗：$e');
      return [];
    }
  }

  Stream<List<SharedBudget>> watchMySharedBudgets() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();

    return _db
        .collection('shared_budgets')
        .where('memberUids', arrayContains: uid)
        .snapshots()
        .map((snap) => snap.docs
        .map(SharedBudget.fromDoc)
        .where((b) => !b.kickedUids.contains(uid))
        .toList());
  }

  Stream<SharedBudget?> watchBudget(String budgetId) {
    return _db
        .collection('shared_budgets')
        .doc(budgetId)
        .snapshots()
        .map((doc) => doc.exists ? SharedBudget.fromDoc(doc) : null);
  }

  Stream<List<SharedBudgetRecord>> watchRecords(String budgetId) {
    return _db
        .collection('shared_budgets')
        .doc(budgetId)
        .collection('records')
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) {
        return SharedBudgetRecord.fromMap(doc.data(), doc.id);
      }).where((r) => r.deletedAt == null).toList();

      list.sort((a, b) {
        final tA = a.createdAtMs ?? a.createdAt.millisecondsSinceEpoch;
        final tB = b.createdAtMs ?? b.createdAt.millisecondsSinceEpoch;
        return tA.compareTo(tB);
      });
      return list;
    });
  }

  Future<List<SharedBudgetRecord>> getRecords(String budgetId) async {
    try {
      final snap = await _db
          .collection('shared_budgets')
          .doc(budgetId)
          .collection('records')
          .get();
      final list = snap.docs
          .map(SharedBudgetRecord.fromDoc)
          .where((r) => r.deletedAt == null)
          .toList();
      list.sort((a, b) => (a.createdAtMs ?? 0).compareTo(b.createdAtMs ?? 0));
      return list;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 取得紀錄失敗：$e');
      return [];
    }
  }

  Future<String?> addRecord({
    required String budgetId,
    required String title,
    required String category,
    required int amount,
    required String payerUid,
    required String payerName,
    String createdBy = '',
    String note = '',
    // ★ 新增：參與分攤的成員 UID 清單，空 = 全員均攤
    List<String> splitParticipants = const [],
  }) async {
    final uid = _uid;
    if (uid == null) return null;

    try {
      final now = DateTime.now();
      final docRef = _db.collection('shared_budgets').doc(budgetId).collection('records').doc();

      await docRef.set({
        'title': title,
        'category': category,
        'amount': amount,
        'payerUid': payerUid,
        'payerName': payerName,
        'createdBy': uid,
        'createdByName': _name,
        'note': note,
        'createdAt': now.toIso8601String(),
        'createdAtMs': now.millisecondsSinceEpoch,
        'deleted_at': null,
        // ★ 新增：寫入 Firestore，空清單代表全員分攤
        'splitParticipants': splitParticipants,
      });

      await _db.collection('shared_budgets').doc(budgetId).update({
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '新增了一筆消費明細「$title」 NT\$$amount',
            'timestamp': now.toIso8601String(),
          }
        ])
      });
      return docRef.id;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 新增消費失敗：$e');
      return null;
    }
  }

  Future<bool> deleteRecord({
    required String budgetId,
    required String recordId,
    required String createdBy,
  }) async {
    final uid = _uid;
    if (uid == null) return false;

    try {
      await _db
          .collection('shared_budgets')
          .doc(budgetId)
          .collection('records')
          .doc(recordId)
          .update({'deleted_at': FieldValue.serverTimestamp()});

      await _db.collection('shared_budgets').doc(budgetId).update({
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '刪除了一筆消費紀錄',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });
      return true;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 刪除失敗：$e');
      return false;
    }
  }

  /// 更新一筆消費紀錄（只有原始新增者可以修改）
  Future<bool> updateRecord({
    required String budgetId,
    required String recordId,
    required String createdBy,
    required String title,
    required String category,
    required int amount,
    required String payerUid,
    required String payerName,
    List<String> splitParticipants = const [],
  }) async {
    final uid = _uid;
    if (uid == null) return false;

    // 權限檢查：只有原始新增者可以修改
    if (uid != createdBy) return false;

    try {
      await _db
          .collection('shared_budgets')
          .doc(budgetId)
          .collection('records')
          .doc(recordId)
          .update({
        'title': title,
        'category': category,
        'amount': amount,
        'payerUid': payerUid,
        'payerName': payerName,
        'splitParticipants': splitParticipants,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _db.collection('shared_budgets').doc(budgetId).update({
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '修改了一筆消費明細「$title」NT\$$amount',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });
      return true;
    } catch (e) {
      debugPrint('⚠️ [SharedBudget] 更新消費失敗：$e');
      return false;
    }
  }

  Future<bool> updateTotalBudget(String budgetId, int newBudget) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      await _db.collection('shared_budgets').doc(budgetId).update({
        'totalBudget': newBudget,
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '修改預算上限為 NT\$ $newBudget',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> kickMember({
    required String budgetId,
    required String targetUid,
    required String targetName,
  }) async {
    final uid = _uid;
    if (uid == null || targetUid == uid) return false;

    try {
      final doc = await _db.collection('shared_budgets').doc(budgetId).get();
      final data = doc.data();
      if (data == null || data['ownerUid'] != uid) return false;

      final List<dynamic> currentMembers = data['members'] ?? [];
      final members = List<Map<String, dynamic>>.from(currentMembers.cast<Map<String, dynamic>>());

      members.removeWhere((m) => m['uid'] == targetUid);
      final memberUids = members.map((m) => m['uid'] as String).toList();

      await _db.collection('shared_budgets').doc(budgetId).update({
        'members': members,
        'memberUids': memberUids,
        'kickedUids': FieldValue.arrayUnion([targetUid]),
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '將成員「$targetName」移出了共享房間',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });

      await _db
          .collection('users')
          .doc(targetUid)
          .collection('shared_budget_invites')
          .doc(budgetId)
          .delete();

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> leaveSharedBudget(String budgetId) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final doc = await _db.collection('shared_budgets').doc(budgetId).get();
      final data = doc.data();
      if (data == null || data['ownerUid'] == uid) return false;

      final members = List<Map<String, dynamic>>.from((data['members'] as List).cast<Map<String, dynamic>>());
      members.removeWhere((m) => m['uid'] == uid);
      final memberUids = members.map((m) => m['uid'] as String).toList();

      await _db.collection('shared_budgets').doc(budgetId).update({
        'members': members,
        'memberUids': memberUids,
        'updatedAt': FieldValue.serverTimestamp(),
        'historyLogs': FieldValue.arrayUnion([
          {
            'uid': uid,
            'userName': _name,
            'action': '主動離開了共享預算房間',
            'timestamp': DateTime.now().toIso8601String(),
          }
        ])
      });

      await _db.collection('users').doc(uid).collection('shared_budget_invites').doc(budgetId).delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteSharedBudget(String budgetId) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final doc = await _db.collection('shared_budgets').doc(budgetId).get();
      if ((doc.data()?['ownerUid'] ?? '') != uid) return false;

      final memberUids = List<String>.from(doc.data()?['memberUids'] ?? []);
      final records = await _db.collection('shared_budgets').doc(budgetId).collection('records').get();

      final batch = _db.batch();
      for (final r in records.docs) {
        batch.delete(r.reference);
      }
      batch.delete(_db.collection('shared_budgets').doc(budgetId));
      await batch.commit();

      for (final memberUid in memberUids) {
        _db.collection('users').doc(memberUid).collection('shared_budget_invites').doc(budgetId).delete().catchError((_) {});
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Stream<List<SharedBudgetInvite>> watchPendingInvites() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('users')
        .doc(uid)
        .collection('shared_budget_invites')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) => snap.docs.map(SharedBudgetInvite.fromDoc).toList());
  }

  List<SettlementEntry> calculateSettlement({
    required List<SharedBudgetMember> members,
    required List<SharedBudgetRecord> records,
  }) {
    if (members.length < 2 || records.isEmpty) return [];

    // ★ 修改：按每筆紀錄的 splitParticipants 計算各人「應付金額」
    //   splitParticipants 空 = 全員均攤（向下相容舊資料）
    final allUids = members.map((m) => m.uid).toList();

    // 各人「實際付了多少」
    final Map<String, int> actualPaid = {};
    for (final r in records) {
      actualPaid[r.payerUid] = (actualPaid[r.payerUid] ?? 0) + r.amount;
    }

    // 各人「應付多少」（按每筆的參與人數平均分攤）
    final Map<String, int> shouldPay = {for (final uid in allUids) uid: 0};
    for (final r in records) {
      final participants = r.splitParticipants.isEmpty
          ? allUids                     // 空 = 全員分攤（舊資料相容）
          : r.splitParticipants.where((uid) => shouldPay.containsKey(uid)).toList();
      if (participants.isEmpty) continue;
      final share = r.amount ~/ participants.length;
      final remainder = r.amount - share * participants.length; // 處理整除餘數
      for (int i = 0; i < participants.length; i++) {
        final uid = participants[i];
        // 第一人多承擔餘數（確保金額加總精確）
        shouldPay[uid] = (shouldPay[uid] ?? 0) + share + (i == 0 ? remainder : 0);
      }
    }

    // net > 0 = 別人欠你；net < 0 = 你欠別人
    final Map<String, int> net = {
      for (final m in members) m.uid: (actualPaid[m.uid] ?? 0) - (shouldPay[m.uid] ?? 0),
    };

    final Map<String, Map<String, String>> info = {
      for (var m in members) m.uid: {'name': m.displayName},
    };

    final creditors = net.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final debtors = net.entries.where((e) => e.value < 0).toList()..sort((a, b) => a.value.compareTo(b.value));

    final credAmts = creditors.map((e) => e.value).toList();
    final debtAmts = debtors.map((e) => e.value.abs()).toList();

    final result = <SettlementEntry>[];
    int ci = 0, di = 0;
    while (ci < creditors.length && di < debtors.length) {
      final pay = min(credAmts[ci], debtAmts[di]);
      if (pay > 0) {
        result.add(SettlementEntry(
          fromUid: debtors[di].key,
          fromName: info[debtors[di].key]?['name'] ?? '成員',
          toUid: creditors[ci].key,
          toName: info[creditors[ci].key]?['name'] ?? '成員',
          amount: pay,
        ));
      }
      credAmts[ci] -= pay;
      debtAmts[di] -= pay;
      if (credAmts[ci] == 0) ci++;
      if (debtAmts[di] == 0) di++;
    }
    return result;
  }

  Future<void> syncMemberUids(String budgetId) async {
    try {
      final doc = await _db.collection('shared_budgets').doc(budgetId).get();
      final members = (doc.data()?['members'] as List<dynamic>? ?? [])
          .map((e) => (e as Map<String, dynamic>)['uid'] as String)
          .toList();
      await _db.collection('shared_budgets').doc(budgetId).update({'memberUids': members});
    } catch (_) {}
  }
}