// ═══════════════════════════════════════════════════════════════
//  local_db_service.dart ★ 終極完整保留隔離版 v8 ★
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

// ── 資料模型（原本的模型全部保留） ──────────────────────────────────────────────

class ChatSession {
  final String id;
  final String mode;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  ChatSession({
    required this.id,
    required this.mode,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'mode': mode,
    'title': title,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ChatSession.fromMap(Map<String, dynamic> m) => ChatSession(
    id: m['id'],
    mode: m['mode'],
    title: m['title'],
    createdAt: DateTime.parse(m['created_at']),
    updatedAt: DateTime.parse(m['updated_at']),
  );
}

class ChatMessageRecord {
  final String id;
  final String sessionId;
  final bool isUser;
  final String text;
  final String? messageType;
  final String? recType;
  final DateTime createdAt;

  ChatMessageRecord({
    required this.id,
    required this.sessionId,
    required this.isUser,
    required this.text,
    this.messageType,
    this.recType,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'is_user': isUser ? 1 : 0,
    'text': text,
    'message_type': messageType ?? 'text',
    'rec_type': recType,
    'created_at': createdAt.toIso8601String(),
  };

  factory ChatMessageRecord.fromMap(Map<String, dynamic> m) => ChatMessageRecord(
    id: m['id'],
    sessionId: m['session_id'],
    isUser: m['is_user'] == 1,
    text: m['text'],
    messageType: m['message_type'],
    recType: m['rec_type'],
    createdAt: DateTime.parse(m['created_at']),
  );
}

class SavedItinerary {
  final String id;
  final String userId;
  final String title;
  final int estimatedBudget;
  final DateTime startDate;
  final DateTime endDate;
  final String plansJson;
  final bool isFromAi;
  final DateTime createdAt;
  final DateTime updatedAt;

  SavedItinerary({
    required this.id,
    this.userId = '',
    required this.title,
    required this.estimatedBudget,
    required this.startDate,
    required this.endDate,
    required this.plansJson,
    required this.isFromAi,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'title': title,
    'estimated_budget': estimatedBudget,
    'start_date': startDate.toIso8601String(),
    'end_date': endDate.toIso8601String(),
    'plans_json': plansJson,
    'is_from_ai': isFromAi ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory SavedItinerary.fromMap(Map<String, dynamic> m) => SavedItinerary(
    id: m['id'],
    userId: m['user_id']?.toString() ?? '',
    title: m['title'],
    estimatedBudget: m['estimated_budget'] ?? 0,
    startDate: DateTime.parse(m['start_date']),
    endDate: DateTime.parse(m['end_date']),
    plansJson: m['plans_json'],
    isFromAi: m['is_from_ai'] == 1,
    createdAt: DateTime.parse(m['created_at']),
    updatedAt: DateTime.parse(m['updated_at']),
  );
}

class BudgetRecord {
  final String id;
  final String itineraryId;
  final String userId;
  final String title;
  final String category;
  final int amount;
  final String payer;
  final DateTime createdAt;

  BudgetRecord({
    required this.id,
    required this.itineraryId,
    required this.userId,
    required this.title,
    required this.category,
    required this.amount,
    required this.payer,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'itinerary_id': itineraryId,
    'user_id': userId,
    'title': title,
    'category': category,
    'amount': amount,
    'payer': payer,
    'created_at': createdAt.toIso8601String(),
  };

  factory BudgetRecord.fromMap(Map<String, dynamic> m) => BudgetRecord(
    id: m['id'],
    itineraryId: m['itinerary_id'],
    userId: m['user_id']?.toString() ?? '',
    title: m['title'],
    category: m['category'],
    amount: m['amount'] as int,
    payer: m['payer'] ?? '自己',
    createdAt: DateTime.parse(m['created_at']),
  );
}

class ItineraryBudgetConfig {
  final String itineraryId;
  final String userId;
  final int budgetLimit;
  final bool isMultiMode;
  final String membersJson;
  final DateTime updatedAt;

  ItineraryBudgetConfig({
    required this.itineraryId,
    required this.userId,
    required this.budgetLimit,
    required this.isMultiMode,
    required this.membersJson,
    required this.updatedAt,
  });

  List<String> get members {
    try {
      if (membersJson.isEmpty) return <String>['自己'];
      final decoded = jsonDecode(membersJson);
      if (decoded is List && decoded.isNotEmpty) {
        return decoded.map((e) => e.toString()).toList();
      }
      return <String>['自己'];
    } catch (_) {
      return <String>['自己'];
    }
  }

  Map<String, dynamic> toMap() => {
    'itinerary_id': itineraryId,
    'user_id': userId,
    'budget_limit': budgetLimit,
    'is_multi_mode': isMultiMode ? 1 : 0,
    'members_json': membersJson,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ItineraryBudgetConfig.fromMap(Map<String, dynamic> m) => ItineraryBudgetConfig(
    itineraryId: m['itinerary_id'],
    userId: m['user_id']?.toString() ?? '',
    budgetLimit: m['budget_limit'] ?? 0,
    isMultiMode: m['is_multi_mode'] == 1,
    membersJson: m['members_json'] ?? '["自己"]',
    updatedAt: DateTime.parse(m['updated_at']),
  );
}

class NotificationRecord {
  final String id;
  final String type;
  final String budgetId;
  final String budgetTitle;
  final String senderName;
  final String senderUid;
  final String status;
  final String action;
  final DateTime createdAt;
  final DateTime? readAt;

  NotificationRecord({
    required this.id,
    required this.type,
    required this.budgetId,
    required this.budgetTitle,
    required this.senderName,
    required this.senderUid,
    required this.status,
    required this.action,
    required this.createdAt,
    this.readAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type,
    'budget_id': budgetId,
    'budget_title': budgetTitle,
    'sender_name': senderName,
    'sender_uid': senderUid,
    'status': status,
    'action': action,
    'created_at': createdAt.toIso8601String(),
    'read_at': readAt?.toIso8601String(),
  };

  factory NotificationRecord.fromMap(Map<String, dynamic> m) {
    DateTime? parsedRead;
    if (m['read_at'] != null) {
      try { parsedRead = DateTime.parse(m['read_at']); } catch (_) {}
    }

    return NotificationRecord(
      id: m['id'],
      type: m['type'] ?? 'budget_invite',
      budgetId: m['budget_id'] ?? '',
      budgetTitle: m['budget_title'] ?? '',
      senderName: m['sender_name'] ?? '',
      senderUid: m['sender_uid'] ?? '',
      status: m['status'] ?? 'unread',
      action: m['action'] ?? 'pending',
      createdAt: DateTime.parse(m['created_at']),
      readAt: parsedRead,
    );
  }
}

// ── LocalDbService 主體 ───────────────────────────────────────

class LocalDbService {
  static LocalDbService? _instance;
  static LocalDbService get instance => _instance ??= LocalDbService._();
  LocalDbService._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'chiayi_travel.db');
    return openDatabase(
      path,
      version: 8,   // ★ 升級至 v8：修正 deleted_itinerary_ids 表結構，加入 user_id 複合主鍵隔離
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS deleted_itinerary_ids (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)');
        }
        if (oldVersion < 4) {
          final cols = await db.rawQuery('PRAGMA table_info(saved_itineraries)');
          final hasUserIdCol = cols.any((c) => c['name'] == 'user_id');
          if (!hasUserIdCol) {
            await db.execute('ALTER TABLE saved_itineraries ADD COLUMN user_id TEXT DEFAULT ""');
          }
        }
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS budget_records (
              id TEXT PRIMARY KEY,
              itinerary_id TEXT NOT NULL,
              user_id TEXT NOT NULL DEFAULT "",
              title TEXT NOT NULL,
              category TEXT NOT NULL DEFAULT "其他",
              amount INTEGER NOT NULL DEFAULT 0,
              payer TEXT NOT NULL DEFAULT "自己",
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS itinerary_budget_configs (
              itinerary_id TEXT PRIMARY KEY,
              user_id TEXT NOT NULL DEFAULT "",
              budget_limit INTEGER NOT NULL DEFAULT 0,
              is_multi_mode INTEGER NOT NULL DEFAULT 0,
              members_json TEXT NOT NULL DEFAULT '["自己"]',
              updated_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS notifications (
              id TEXT PRIMARY KEY,
              type TEXT NOT NULL DEFAULT "budget_invite",
              budget_id TEXT NOT NULL,
              budget_title TEXT NOT NULL,
              sender_name TEXT NOT NULL,
              sender_uid TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT "unread",
              action TEXT NOT NULL DEFAULT "pending",
              created_at TEXT NOT NULL,
              read_at TEXT
            )
          ''');
        }
        if (oldVersion < 7) {
          try {
            await db.execute('ALTER TABLE itinerary_budget_configs RENAME TO itinerary_budget_configs_old');
            await db.execute('''
              CREATE TABLE itinerary_budget_configs (
                itinerary_id TEXT NOT NULL,
                user_id TEXT NOT NULL DEFAULT "",
                budget_limit INTEGER NOT NULL DEFAULT 0,
                is_multi_mode INTEGER NOT NULL DEFAULT 0,
                members_json TEXT NOT NULL DEFAULT '["自己"]',
                updated_at TEXT NOT NULL,
                PRIMARY KEY (itinerary_id, user_id)
              )
            ''');
            await db.execute('''
              INSERT OR IGNORE INTO itinerary_budget_configs
              SELECT itinerary_id, user_id, budget_limit, is_multi_mode, members_json, updated_at
              FROM itinerary_budget_configs_old
            ''');
            await db.execute('DROP TABLE itinerary_budget_configs_old');
          } catch (e) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS itinerary_budget_configs (
                itinerary_id TEXT NOT NULL,
                user_id TEXT NOT NULL DEFAULT "",
                budget_limit INTEGER NOT NULL DEFAULT 0,
                is_multi_mode INTEGER NOT NULL DEFAULT 0,
                members_json TEXT NOT NULL DEFAULT '["自己"]',
                updated_at TEXT NOT NULL,
                PRIMARY KEY (itinerary_id, user_id)
              )
            ''');
          }
        }
        if (oldVersion < 8) {
          // ★ Bug 1 核心修復：升級時將舊刪除表重構，補上 user_id 並改為複合主鍵，防重登/換帳號相互污染
          try {
            await db.execute('ALTER TABLE deleted_itinerary_ids RENAME TO deleted_itinerary_ids_old');
            await db.execute('''
              CREATE TABLE deleted_itinerary_ids (
                id TEXT NOT NULL,
                user_id TEXT NOT NULL DEFAULT "",
                deleted_at TEXT NOT NULL,
                PRIMARY KEY (id, user_id)
              )
            ''');
            await db.execute('''
              INSERT OR IGNORE INTO deleted_itinerary_ids (id, user_id, deleted_at)
              SELECT id, "", deleted_at FROM deleted_itinerary_ids_old
            ''');
            await db.execute('DROP TABLE deleted_itinerary_ids_old');
          } catch (_) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS deleted_itinerary_ids (
                id TEXT NOT NULL,
                user_id TEXT NOT NULL DEFAULT "",
                deleted_at TEXT NOT NULL,
                PRIMARY KEY (id, user_id)
              )
            ''');
          }
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE chat_sessions (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE chat_messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            is_user INTEGER NOT NULL,
            text TEXT NOT NULL,
            message_type TEXT DEFAULT "text",
            rec_type TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE saved_itineraries (
            id TEXT PRIMARY KEY,
            user_id TEXT DEFAULT "",
            title TEXT NOT NULL,
            estimated_budget INTEGER NOT NULL DEFAULT 0,
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL,
            plans_json TEXT NOT NULL,
            is_from_ai INTEGER DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE TABLE IF NOT EXISTS deleted_itinerary_ids (id TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT "", deleted_at TEXT NOT NULL, PRIMARY KEY (id, user_id))');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS budget_records (
            id TEXT PRIMARY KEY,
            itinerary_id TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT "",
            title TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT "其他",
            amount INTEGER NOT NULL DEFAULT 0,
            payer TEXT NOT NULL DEFAULT "自己",
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS itinerary_budget_configs (
            itinerary_id TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT "",
            budget_limit INTEGER NOT NULL DEFAULT 0,
            is_multi_mode INTEGER NOT NULL DEFAULT 0,
            members_json TEXT NOT NULL DEFAULT \'["自己"]\',
            updated_at TEXT NOT NULL,
            PRIMARY KEY (itinerary_id, user_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS notifications (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL DEFAULT "budget_invite",
            budget_id TEXT NOT NULL,
            budget_title TEXT NOT NULL,
            sender_name TEXT NOT NULL,
            sender_uid TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT "unread",
            action TEXT NOT NULL DEFAULT "pending",
            created_at TEXT NOT NULL,
            read_at TEXT
          )
        ''');
      },
    );
  }

  // ── Chat Sessions 原有功能不作任何刪剪 ──────────────────────────────────────────

  Future<void> insertSession(ChatSession session) async {
    final d = await db;
    await d.insert('chat_sessions', session.toMap());
  }

  Future<ChatSession?> getSession(String id) async {
    final d = await db;
    final rows = await d.query('chat_sessions', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return ChatSession.fromMap(rows.first);
  }

  Future<List<ChatSession>> getAllSessions() async {
    final d = await db;
    final rows = await d.query('chat_sessions', orderBy: 'updated_at DESC');
    return rows.map(ChatSession.fromMap).toList();
  }

  Future<void> updateSession(ChatSession session) async {
    final d = await db;
    await d.update('chat_sessions', session.toMap(), where: 'id = ?', whereArgs: [session.id]);
  }

  Future<void> updateSessionTime(String sessionId) async {
    final d = await db;
    await d.update('chat_sessions', {'updated_at': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> deleteSession(String id) async {
    final d = await db;
    await d.delete('chat_messages', where: 'session_id = ?', whereArgs: [id]);
    await d.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
  }

  // ── Chat Messages 原有功能完全保留 ──────────────────────────────────────────

  Future<void> insertMessage(ChatMessageRecord msg) async {
    final d = await db;
    await d.insert('chat_messages', msg.toMap());
  }

  Future<List<ChatMessageRecord>> getMessagesForSession(String sessionId) async {
    final d = await db;
    final rows = await d.query('chat_messages', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at ASC');
    return rows.map(ChatMessageRecord.fromMap).toList();
  }

  // ── Saved Itineraries 精準資料隔離 ──────────────────────────────────────

  Future<void> insertItinerary(SavedItinerary itinerary) async {
    final d = await db;
    await d.execute('''
      CREATE TABLE IF NOT EXISTS saved_itineraries (
        id TEXT PRIMARY KEY,
        user_id TEXT DEFAULT "",
        title TEXT NOT NULL,
        estimated_budget INTEGER NOT NULL DEFAULT 0,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        plans_json TEXT NOT NULL,
        is_from_ai INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await d.insert('saved_itineraries', itinerary.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateItinerary(SavedItinerary itinerary) async {
    final d = await db;
    await d.update('saved_itineraries', itinerary.toMap(), where: 'id = ?', whereArgs: [itinerary.id]);
  }

  // ★ Bug 1 核心修復：本地行程刪除標記加入當前操作的 user_id，避免覆滅其他同行者的本地快取
  Future<void> deleteItinerary(String id, {String userId = ''}) async {
    final d = await db;
    await d.delete('saved_itineraries', where: 'id = ?', whereArgs: [id]);
    await d.insert(
      'deleted_itinerary_ids',
      {'id': id, 'user_id': userId, 'deleted_at': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await d.delete('budget_records', where: 'itinerary_id = ? AND user_id = ?', whereArgs: [id, userId]);
    await d.delete('itinerary_budget_configs', where: 'itinerary_id = ? AND user_id = ?', whereArgs: [id, userId]);
  }

  // ★ Bug 4 核心修復：加載時，只會比對「當前 user_id 刪除過」的墓碑清單，徹底解決阿里郎被誤判已刪除而走失的缺陷
  Future<List<SavedItinerary>> getAllItineraries({String userId = ''}) async {
    final d = await db;
    await d.execute('CREATE TABLE IF NOT EXISTS deleted_itinerary_ids (id TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT "", deleted_at TEXT NOT NULL, PRIMARY KEY (id, user_id))');

    final deletedRows = await d.query('deleted_itinerary_ids', columns: ['id'], where: 'user_id = ?', whereArgs: [userId]);
    final deletedIds = deletedRows.map((r) => r['id'] as String).toSet();

    final List<Map<String, Object?>> rows;
    if (userId.isNotEmpty) {
      rows = await d.rawQuery('SELECT * FROM saved_itineraries WHERE user_id = ? ORDER BY updated_at DESC', [userId]);
    } else {
      rows = await d.query('saved_itineraries', where: 'user_id = "" OR user_id IS NULL', orderBy: 'updated_at DESC');
    }

    return rows
        .map(SavedItinerary.fromMap)
        .where((s) => !deletedIds.contains(s.id))
        .toList();
  }

  Future<List<String>> getDeletedIds({String userId = ''}) async {
    final d = await db;
    await d.execute('CREATE TABLE IF NOT EXISTS deleted_itinerary_ids (id TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT "", deleted_at TEXT NOT NULL, PRIMARY KEY (id, user_id))');
    final rows = await d.query('deleted_itinerary_ids', columns: ['id'], where: 'user_id = ?', whereArgs: [userId]);
    return rows.map((r) => r['id'] as String).toList();
  }

  Future<SavedItinerary?> getItinerary(String id) async {
    final d = await db;
    final rows = await d.query('saved_itineraries', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return SavedItinerary.fromMap(rows.first);
  }

  // ── Budget Records 100% 完整保留 ────────────────────────────────────────

  Future<void> insertBudgetRecord(BudgetRecord record) async {
    final d = await db;
    await d.insert('budget_records', record.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<BudgetRecord>> getBudgetRecords(String itineraryId, {String userId = ''}) async {
    final d = await db;
    final List<Map<String, Object?>> rows;
    if (userId.isNotEmpty) {
      rows = await d.query('budget_records', where: 'itinerary_id = ? AND user_id = ?', whereArgs: [itineraryId, userId], orderBy: 'created_at DESC');
    } else {
      rows = await d.query('budget_records', where: 'itinerary_id = ?', whereArgs: [itineraryId], orderBy: 'created_at DESC');
    }
    return rows.map(BudgetRecord.fromMap).toList();
  }

  Future<void> deleteBudgetRecord(String id) async {
    final d = await db;
    await d.delete('budget_records', where: 'id = ?', whereArgs: [id]);
  }

  // ── Budget Config 100% 完整保留 ─────────────────────────────────────────

  Future<ItineraryBudgetConfig> getBudgetConfig(String itineraryId, {String userId = '', int defaultBudget = 0}) async {
    final d = await db;
    final List<Map<String, Object?>> rows;
    if (userId.isNotEmpty) {
      // ★ Bug 2 修復：移除 `OR user_id = ""` 條件，嚴格按帳號隔離，
      //   防止帳號 B 撈到帳號 A 留下的空 user_id 設定造成兩帳號首頁顯示一模一樣。
      rows = await d.query(
        'itinerary_budget_configs',
        where: 'itinerary_id = ? AND user_id = ?',
        whereArgs: [itineraryId, userId],
        limit: 1,
      );
    } else {
      rows = await d.query('itinerary_budget_configs', where: 'itinerary_id = ?', whereArgs: [itineraryId], limit: 1);
    }
    if (rows.isEmpty) {
      return ItineraryBudgetConfig(itineraryId: itineraryId, userId: userId, budgetLimit: defaultBudget, isMultiMode: false, membersJson: '["自己"]', updatedAt: DateTime.now());
    }
    return ItineraryBudgetConfig.fromMap(rows.first);
  }

  Future<void> saveBudgetConfig(ItineraryBudgetConfig config) async {
    final d = await db;
    await d.insert('itinerary_budget_configs', config.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── 通知與備份機制 原有功能不變 ───────────────────────────────────────────

  Future<void> insertNotification(NotificationRecord notification) async {
    final d = await db;
    await d.insert('notifications', notification.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<NotificationRecord>> getUnreadNotifications() async {
    final d = await db;
    final rows = await d.query('notifications', where: 'status = ?', whereArgs: ['unread'], orderBy: 'created_at DESC');
    return rows.map(NotificationRecord.fromMap).toList();
  }

  Future<void> updateNotificationStatus(String notificationId, String status) async {
    final d = await db;
    await d.update('notifications', {'status': status, 'read_at': status == 'read' ? DateTime.now().toIso8601String() : null}, where: 'id = ?', whereArgs: [notificationId]);
  }

  Future<void> updateNotificationAction(String notificationId, String action) async {
    final d = await db;
    await d.update('notifications', {'action': action, 'status': 'read'}, where: 'id = ?', whereArgs: [notificationId]);
  }

  Future<void> deleteNotification(String notificationId) async {
    final d = await db;
    await d.delete('notifications', where: 'id = ?', whereArgs: [notificationId]);
  }

  Future<List<NotificationRecord>> getAllNotifications() async {
    final d = await db;
    final rows = await d.query('notifications', orderBy: 'created_at DESC', limit: 50);
    return rows.map(NotificationRecord.fromMap).toList();
  }

  Future<Map<String, dynamic>> exportAllData({String userId = ''}) async {
    final sessions = await getAllSessions();
    final itineraries = await getAllItineraries(userId: userId);
    final deletedIds = await getDeletedIds(userId: userId);

    final sessionData = <Map<String, dynamic>>[];
    for (final s in sessions) {
      final msgs = await getMessagesForSession(s.id);
      sessionData.add({'session': s.toMap(), 'messages': msgs.map((m) => m.toMap()).toList()});
    }

    final budgetData = <Map<String, dynamic>>[];
    for (final it in itineraries) {
      final records = await getBudgetRecords(it.id, userId: userId);
      final config = await getBudgetConfig(it.id, userId: userId);
      budgetData.add({'itinerary_id': it.id, 'records': records.map((r) => r.toMap()).toList(), 'config': config.toMap()});
    }

    final notifications = await getAllNotifications();
    return {'sessions': sessionData, 'itineraries': itineraries.map((i) => i.toMap()).toList(), 'deleted_itinerary_ids': deletedIds, 'budget_data': budgetData, 'notifications': notifications.map((n) => n.toMap()).toList(), 'exported_at': DateTime.now().toIso8601String()};
  }

  Future<void> importFromFirebase(Map<String, dynamic> data, {String userId = ''}) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('chat_messages');
      await txn.delete('chat_sessions');

      for (final sd in (data['sessions'] as List<dynamic>? ?? [])) {
        final sessionMap = sd['session'] as Map<String, dynamic>;
        await txn.insert('chat_sessions', sessionMap, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final msgMap in (sd['messages'] as List<dynamic>? ?? [])) {
          await txn.insert('chat_messages', msgMap as Map<String, dynamic>, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      final now = DateTime.now().toIso8601String();
      for (final delId in (data['deleted_itinerary_ids'] as List<dynamic>? ?? [])) {
        await txn.insert('deleted_itinerary_ids', {'id': delId.toString(), 'user_id': userId, 'deleted_at': now}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });

    for (final bd in (data['budget_data'] as List<dynamic>? ?? [])) {
      try {
        for (final r in (bd['records'] as List<dynamic>? ?? [])) {
          await insertBudgetRecord(BudgetRecord.fromMap(r as Map<String, dynamic>));
        }
        if (bd['config'] != null) {
          await saveBudgetConfig(ItineraryBudgetConfig.fromMap(bd['config'] as Map<String, dynamic>));
        }
      } catch (_) {}
    }

    for (final n in (data['notifications'] as List<dynamic>? ?? [])) {
      try {
        await insertNotification(NotificationRecord.fromMap(n as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  // ★ Merge 策略：只補入雲端有但本地沒有的 session，不刪本地現有資料
  Future<void> importFromFirebaseMerge(Map<String, dynamic> data, {String userId = ''}) async {
    final d = await db;

    for (final sd in (data['sessions'] as List<dynamic>? ?? [])) {
      try {
        final sessionMap = Map<String, dynamic>.from(sd['session'] as Map<String, dynamic>);
        final sessionId = sessionMap['id'] as String?;
        if (sessionId == null) continue;

        // 本地已存在就跳過（保留本地最新）
        final existing = await d.query('chat_sessions', where: 'id = ?', whereArgs: [sessionId]);
        if (existing.isNotEmpty) continue;

        await d.insert('chat_sessions', sessionMap, conflictAlgorithm: ConflictAlgorithm.ignore);
        for (final msgMap in (sd['messages'] as List<dynamic>? ?? [])) {
          await d.insert('chat_messages', msgMap as Map<String, dynamic>, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      } catch (_) {}
    }

    // notifications 也 merge
    for (final n in (data['notifications'] as List<dynamic>? ?? [])) {
      try {
        await insertNotification(NotificationRecord.fromMap(n as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  Future<void> clearAllData() async {
    final d = await db;
    await d.delete('chat_messages');
    await d.delete('chat_sessions');
  }

  // ★ Bug 2 核心修復：登出清除特定帳號數據時，嚴格進行 (itinerary_id + user_id) 級別清理，不跨帳號誤傷同行旅伴的 SQLite 設定
  Future<void> clearItinerariesForUser(String userId) async {
    final d = await db;
    final rows = await d.query('saved_itineraries', columns: ['id'], where: 'user_id = ?', whereArgs: [userId]);
    for (final row in rows) {
      final id = row['id'] as String;
      await d.delete('budget_records', where: 'itinerary_id = ? AND user_id = ?', whereArgs: [id, userId]);
      await d.delete('itinerary_budget_configs', where: 'itinerary_id = ? AND user_id = ?', whereArgs: [id, userId]);
      await d.delete('deleted_itinerary_ids', where: 'id = ? AND user_id = ?', whereArgs: [id, userId]);
    }
    await d.delete('saved_itineraries', where: 'user_id = ?', whereArgs: [userId]);
  }

  Future<void> clearBudgetDataForItinerary(String itineraryId) async {
    final d = await db;
    await d.delete('budget_records', where: 'itinerary_id = ?', whereArgs: [itineraryId]);
    await d.delete('itinerary_budget_configs', where: 'itinerary_id = ?', whereArgs: [itineraryId]);
    await d.delete('saved_itineraries', where: 'id = ?', whereArgs: [itineraryId]);
    debugPrint('🧹 [DB] 已徹底清理本地行程 $itineraryId 的所有預算與主表骨架');
  }

  Future<void> clearCommunityPostSessions() async {
    final d = await db;
    final sessions = await d.query('chat_sessions', where: 'mode = ?', whereArgs: ['community_post'], columns: ['id']);
    for (final s in sessions) {
      final sid = s['id'] as String;
      await d.delete('chat_messages', where: 'session_id = ?', whereArgs: [sid]);
      await d.delete('chat_sessions', where: 'id = ?', whereArgs: [sid]);
    }
  }
}