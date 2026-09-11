// ═══════════════════════════════════════════════════════════════
//  budget_screen.dart  ★ 修正版 v3
//
//  修正清單（相較 v2）：
//  [Fix-8] _buildSharedDashboard StreamBuilder：
//          加入 error state 顯示（stream 出錯不再靜默失敗）
//          加入 loading state 顯示（waiting 時顯示 spinner）
//  [Fix-8] _selectSharedBudget：
//          強制先清空 _recordsStream = null，下一幀再重建
//          → 確保 StreamBuilder 重置，無論是否重複點同一 budget
//          → 每次進入都觸發新的 Firestore stream 訂閱
//
//  原有功能：
//  1. 多人共享模式 → 建立 Firestore shared_budgets 房間
//  2. 邀請帳號加入（輸入 email → 搜尋 → 發送邀請）
//  3. 即時監聽消費紀錄（StreamBuilder，所有人即時看到更新）
//  4. 收到邀請通知 → 接受 / 拒絕
//  5. 結算建議顯示每個人的 uid / 顯示名稱
//  6. 保留原本單人本地記帳模式不動
//
//  Firestore 架構：
//    shared_budgets/{budgetId}/records/{recordId}
//    users/{uid}/shared_budget_invites/{budgetId}
//
//  配色：抹茶綠 #8BAA88 / 深咖啡 #7D6E5D / 淡咖啡 #BCAAA4 / 米白 #FDFCF5
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
// ★ 修正：加 prefix 區分 local_db_service.BudgetRecord（DB 資料層）
//   與此檔案的 BudgetRecord（UI 顯示層）
import 'local_db_service.dart' as local_db_service;
import 'local_db_service.dart' show SavedItinerary, ItineraryBudgetConfig, NotificationRecord;
import 'firebase_sync_service.dart';
import 'itinerary_save_service.dart';
import 'shared_budget_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // [Fix-C]
// 請在 budget_screen.dart 頂部補上這一行引用：
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:shared_preferences/shared_preferences.dart';
// ★ 側邊欄跳頁所需：使用專案共用的 AppStateManager
import 'app_state.dart';
import 'help_support_screen.dart';
import 'system_settings_screen.dart';
import 'community_screen.dart' show MyPostsScreen;
import 'profile_screen.dart' show UserLogsPage;
import 'login_screen.dart';
import 'home_screen.dart' show UserAvatar;
// ──────────────────────────────────────────────────────────────
//  本地記帳資料模型（單人模式保留，不動）
// ──────────────────────────────────────────────────────────────
class BudgetRecord {
  String title;
  String category;
  int amount;
  String payer;
  final DateTime createdAt;
  // ★ 新增：參與分攤的人名稱列表（空 = 全員分攤）
  List<String> splitParticipants;

  BudgetRecord({
    required this.title,
    required this.category,
    required this.amount,
    required this.payer,
    DateTime? createdAt,
    List<String>? splitParticipants,
  })  : createdAt = createdAt ?? DateTime.now(),
        splitParticipants = splitParticipants ?? [];

  Map<String, dynamic> toJson() => {
    'title': title,
    'category': category,
    'amount': amount,
    'payer': payer,
    'createdAt': createdAt.toIso8601String(),
    'splitParticipants': splitParticipants,
  };

  factory BudgetRecord.fromJson(Map<String, dynamic> j) => BudgetRecord(
    title: j['title'] ?? '',
    category: j['category'] ?? '其他',
    amount: j['amount'] ?? 0,
    payer: j['payer'] ?? '自己',
    createdAt: j['createdAt'] != null
        ? DateTime.parse(j['createdAt'])
        : DateTime.now(),
    splitParticipants: j['splitParticipants'] != null
        ? List<String>.from(j['splitParticipants'])
        : [],
  );
}

// ──────────────────────────────────────────────────────────────
//  BudgetTrip（本地行程預算，單人 / 多人切換入口）
// ──────────────────────────────────────────────────────────────
class BudgetTrip {
  final String itineraryId;
  String name;
  IconData icon;
  int budget;
  bool isMultiMode;
  List<String> members;
  List<BudgetRecord> records;
  // ★ 新增：若已建立雲端共享房間，存 budgetId
  String? sharedBudgetId;

  BudgetTrip({
    required this.itineraryId,
    required this.name,
    this.icon = Icons.map_rounded,
    required this.budget,
    this.isMultiMode = false,
    List<String>? members,
    List<BudgetRecord>? records,
    this.sharedBudgetId,
  })  : members = members ?? ['自己'],
        records = records ?? [];

  int get totalSpent => records.fold(0, (s, r) => s + r.amount);

  Map<String, int> get memberPayments {
    final Map<String, int> mp = {for (var m in members) m: 0};
    for (var r in records) {
      if (mp.containsKey(r.payer)) {
        mp[r.payer] = mp[r.payer]! + r.amount;
      } else {
        mp['自己'] = (mp['自己'] ?? 0) + r.amount;
      }
    }
    return mp;
  }

  Map<String, int> get catTotals {
    final Map<String, int> ct = {
      '美食': 0,
      '住宿': 0,
      '交通': 0,
      '購物': 0,
      '其他': 0
    };
    for (var r in records) {
      if (ct.containsKey(r.category))
        ct[r.category] = ct[r.category]! + r.amount;
    }
    return ct;
  }

  List<Map<String, dynamic>> get settlementSuggestions {
    if (members.length < 2 || records.isEmpty) return [];
    final mp = memberPayments;

    // ★ 新邏輯：按每筆紀錄的 splitParticipants 算各人應付金額
    final Map<String, int> shouldPay = {for (var m in members) m: 0};
    for (final r in records) {
      final participants = r.splitParticipants.isEmpty
          ? members // 空 = 全員分攤
          : r.splitParticipants.where((p) => members.contains(p)).toList();
      if (participants.isEmpty) continue;
      final share = r.amount ~/ participants.length;
      for (final p in participants) {
        shouldPay[p] = (shouldPay[p] ?? 0) + share;
      }
    }

    final Map<String, int> net = {
      for (var m in members) m: (mp[m] ?? 0) - (shouldPay[m] ?? 0)
    };

    final List<Map<String, dynamic>> result = [];
    final creditors = net.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final debtors = net.entries.where((e) => e.value < 0).toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    int ci = 0, di = 0;
    final credAmts = creditors.map((e) => e.value).toList();
    final debtAmts = debtors.map((e) => e.value.abs()).toList();

    while (ci < creditors.length && di < debtors.length) {
      final pay = min(credAmts[ci], debtAmts[di]);
      if (pay > 0) {
        result.add({
          'from': debtors[di].key,
          'to': creditors[ci].key,
          'amount': pay,
        });
      }
      credAmts[ci] -= pay;
      debtAmts[di] -= pay;
      if (credAmts[ci] == 0) ci++;
      if (debtAmts[di] == 0) di++;
    }
    return result;
  }
}

// ══════════════════════════════════════════════════════════════
//  BudgetScreen 主 Widget
// ══════════════════════════════════════════════════════════════
class BudgetScreen extends StatefulWidget {
  final String? initialItineraryId;
  const BudgetScreen({super.key, this.initialItineraryId});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}



class _BudgetScreenState extends State<BudgetScreen>
    with TickerProviderStateMixin {
  int? _hoveredIndex;       // 追蹤滑過哪一個本地卡片
  String? _hoveredOrphanId; // 追蹤滑過哪一個雲端卡片
  int? _pressedIndex;       // 追蹤按壓哪一個本地卡片（scale-pop）
  String? _pressedOrphanId; // 追蹤按壓哪一個雲端卡片（scale-pop）

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // ── Tab controller 保留供共享預算功能使用（若日後需要）
  late TabController _tabCtrl;

  // ★ 修正：改用 itineraryId 字串定位，避免 _loadData() reload 後 index 偏移導致顯示錯誤行程
  String? _selectedLocalItineraryId;
  String? _selectedSharedId;
  // ★ 被邀請人切換單人模式時，_loadData() 還沒完成前暫存目標 id，
  //    防止 build() 因找不到 trip 而把 _selectedLocalItineraryId 提早清掉。
  String? _pendingSoloItineraryId;

  final List<BudgetTrip> _trips = [];
  List<SharedBudget> _sharedBudgets = [];
  List<SharedBudgetInvite> _pendingInvites = [];
  bool _isLoading = true;

  // ── 顏色常數 ──────────────────────────────────────────────
  static const _green = Color(0xFF8BAA88);
  static const _brown = Color(0xFF7D6E5D);
  static const _tan   = Color(0xFFBCAAA4);
  static const _cream = Color(0xFFFDFCF5);

  static const Map<String, Color> _catColors = {
    '美食': _brown,
    '住宿': _green,
    '交通': _tan,
    '購物': Color(0xFFA0A0A0),
    '其他': Color(0xFFCCCCCC),
  };
  static const Map<String, IconData> _catIcons = {
    '美食': Icons.restaurant_rounded,
    '住宿': Icons.hotel_rounded,
    '交通': Icons.directions_transit_rounded,
    '購物': Icons.shopping_bag_rounded,
    '其他': Icons.receipt_long_rounded,
  };

  // ── Streams ────────────────────────────────────────────────
  // 儲存目前展開的共享預算 Stream（避免每次 build 重建）
  String? _watchingBudgetId;
  Stream<List<SharedBudgetRecord>>? _recordsStream;

  // ★ 新增：目前展開的共享預算本體 stream（監聽成員變更、被踢等）
  StreamSubscription<SharedBudget?>? _budgetDetailSub;
  SharedBudget? _watchingBudgetDetail;

  // ★ 共享預算即時 stream 訂閱
  StreamSubscription<List<SharedBudget>>? _sharedBudgetsSub;
  bool _isRefreshing = false;
  // ★ 快取最後一次 watchRecords 推送的資料（解決 Navigator.push/pop 後 broadcast stream 不重播的問題）
  List<SharedBudgetRecord> _cachedRecords = [];

  // ★【Fix-進度條】各共享預算的即時花費快取（budgetId → totalSpent）
  // 使 _buildTripCard 的進度條在多人模式下顯示雲端實際花費
  final Map<String, int> _sharedSpentCache = {};
  final Map<String, StreamSubscription<List<SharedBudgetRecord>>> _spentSubs = {};

  // ★ 已顯示過「首次同步提示」的行程 ID（按 uid+itineraryId 組合存入 SharedPreferences）
  final Set<String> _promptedSyncIds = {};
  // ★ 首頁搜尋
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isSearching = false;
  // ★ 分類標籤過濾（全部 / 充足 / 快爆了 / 超預算 / 單人 / 多人）
  String _filterTag = '全部';
  // ★ 進入 Dashboard 的計數器（確保每次進入都有不同的 key，讓 TweenAnimationBuilder 重新觸發動畫）
  int _dashboardEnterCount = 0;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);

    _loadData().then((_) {
      // ★ loadData 完成後，延一幀再檢查首次同步（確保 _trips 已填入）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkFirstSyncNeeded();
      });
      // ★ Fix-Bug3：確保多人預算在 loadData 後立即補抓，不依賴 stream 延遲
      SharedBudgetService.instance.getMySharedBudgets().then((budgets) {
        if (!mounted || budgets.isEmpty) return;
        setState(() => _sharedBudgets = budgets);
        bool needRebuild = false;
        for (final trip in _trips) {
          if (trip.sharedBudgetId == null || trip.sharedBudgetId!.isEmpty) {
            final match = budgets.where((b) => b.itineraryId == trip.itineraryId).firstOrNull;
            if (match != null) {
              trip.sharedBudgetId = match.id;
              trip.isMultiMode = true;
              needRebuild = true;
            }
          }
        }
        if (needRebuild && mounted) setState(() {});
      });
    });
    _listenInvites();
    _listenSharedBudgets(); // ★ 即時監聽共享預算變化（多人同步）
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    _sharedBudgetsSub?.cancel();
    _budgetDetailSub?.cancel(); // ★ 新增
    for (final sub in _spentSubs.values) { sub.cancel(); }
    _spentSubs.clear();
    super.dispose();
  }

  // ★ 補上遺失的清理 Stream 訂閱的輔助方法 (放在 dispose() 下方)
  void _cleanupBudgetDetailSub() {
    _budgetDetailSub?.cancel();
    _budgetDetailSub = null;
  }

  // ★ 補上根據 ItineraryId 獲取行程名稱的輔助方法 (放在 dispose() 下方)
  String _getTripNameByItineraryId(String? itineraryId) {
    if (itineraryId == null) return "未知行程";
    final match = _trips.where((t) => t.itineraryId == itineraryId).firstOrNull;
    return match?.name ?? "我的行程";
  }
  // ★ 即時監聽共享預算列表（任一成員新增/修改消費後畫面自動更新）
  void _listenSharedBudgets() {
    _sharedBudgetsSub?.cancel();
    _sharedBudgetsSub = SharedBudgetService.instance
        .watchMySharedBudgets()
        .listen((budgets) {
      if (!mounted) return;
      setState(() => _sharedBudgets = budgets);

      // ★ stream 更新時同步補回 _trips 的 sharedBudgetId，
      //   防止 Firebase 同步後 stream 先到、_loadData 後到，造成重複顯示。
      bool tripNeedsRebuild = false;
      for (final trip in _trips) {
        if (trip.itineraryId == _pendingSoloItineraryId) continue; // ★ 跳過正在切單人的行程
        if (trip.sharedBudgetId == null || trip.sharedBudgetId!.isEmpty) {
          final match = budgets.where((b) => b.itineraryId == trip.itineraryId).firstOrNull;
          if (match != null) {
            trip.sharedBudgetId = match.id;
            trip.isMultiMode = true;
            tripNeedsRebuild = true;
          }
        }
      }
      if (tripNeedsRebuild && mounted) setState(() {});

      // ──【Fix-進度條】同步訂閱每個共享預算的 records，維護花費快取 ──
      final currentIds = budgets.map((b) => b.id).toSet();
      // 取消已不存在的訂閱
      for (final id in _spentSubs.keys.toList()) {
        if (!currentIds.contains(id)) {
          _spentSubs[id]?.cancel();
          _spentSubs.remove(id);
        }
      }
      // 新增尚未訂閱的
      for (final b in budgets) {
        if (!_spentSubs.containsKey(b.id)) {
          _spentSubs[b.id] = SharedBudgetService.instance
              .watchRecords(b.id)
              .listen((recs) {
            if (!mounted) return;
            final total = recs.fold<int>(0, (s, r) => s + r.amount);
            setState(() => _sharedSpentCache[b.id] = total);
          });
        }
      }

      // 若正在查看某個共享預算 Dashboard，同步更新
      // ★ 關鍵修復：只有在確認完全找不到 AND _budgetDetailSub 已確認 budget 為 null
      //   才退出 Dashboard。避免 watchMySharedBudgets 因 Firestore 短暫快照不一致
      //   （例如 addRecord 觸發 updatedAt 更新時）誤判為「被踢出」，
      //   導致 _recordsStream 歸零、記錄消失。
      if (_selectedSharedId != null &&
          budgets.isNotEmpty &&  // 如果 budgets 完全為空，可能是網路暫斷，不做任何判斷
          !budgets.any((b) => b.id == _selectedSharedId) &&
          _watchingBudgetDetail == null) {  // 只有 _budgetDetailSub 也確認 null 才退出
        // 被踢出或刪除了，退回列表
        setState(() {
          _selectedSharedId = null;
          _watchingBudgetId = null;
          _watchingBudgetDetail = null;
          _recordsStream = null;
          _cachedRecords = []; // 被踢出才清空快取
        });
      }
    });
  }

  // ★ 手動刷新（共享預算成員端）
  Future<void> _manualRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final itineraries =
      await local_db_service.LocalDbService.instance.getAllItineraries(userId: uid);
      final loaded = itineraries.map((it) => _itineraryToBudgetTrip(it)).toList();

      // ★ 修正：同樣從獨立資料表撈消費紀錄
      for (final trip in loaded) {
        try {
          final dbRecords = await local_db_service.LocalDbService.instance
              .getBudgetRecords(trip.itineraryId, userId: uid);
          trip.records.addAll(dbRecords.map((r) => BudgetRecord(
            title: r.title,
            category: r.category,
            amount: r.amount,
            payer: r.payer,
            createdAt: r.createdAt,
          )));
        } catch (_) {}
      }

      final shared = await SharedBudgetService.instance.getMySharedBudgets();
      if (mounted) {
        setState(() {
          _trips..clear()..addAll(loaded);
          _sharedBudgets = shared;
        });
        // ★ 同步補回 sharedBudgetId（與 _loadData 相同邏輯）
        bool needRebuild = false;
        for (final trip in _trips) {
          if (trip.itineraryId == _pendingSoloItineraryId) continue; // ★ 跳過
          if (trip.isMultiMode && (trip.sharedBudgetId == null || trip.sharedBudgetId!.isEmpty)) {
            final match = shared.where((b) => b.itineraryId == trip.itineraryId).firstOrNull;
            if (match != null) { trip.sharedBudgetId = match.id; needRebuild = true; }
          }
        }
        if (needRebuild && mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('⚠️ [Budget] 手動刷新失敗：$e');
    }
    if (mounted) setState(() => _isRefreshing = false);
  }

  // ── 載入本地行程 ───────────────────────────────────────────
  Future<void> _loadData() async {
    // ★ 若正在查看共享 Dashboard，不設 _isLoading = true（避免 build() 返回 loading 畫面，
    //   打斷 StreamBuilder 的 _recordsStream，導致記錄消失）
    // ★ Bug 2 修復：同時保護「_watchingBudgetId 不為 null」的情況，防止背景 _loadData
    //   觸發 loading 狀態清空 StreamBuilder。
    if (_selectedSharedId == null && _selectedLocalItineraryId == null && _watchingBudgetId == null) {
      setState(() => _isLoading = true);
    }
    try {
      final uid =
          FirebaseAuth.instance.currentUser?.uid ?? '';
      final itineraries =
      await local_db_service.LocalDbService.instance.getAllItineraries(userId: uid);

      final loaded = itineraries
          .map((it) => _itineraryToBudgetTrip(it))
          .toList();

      // ★ 修正：從獨立資料表撈消費紀錄（按 userId 隔離，不再嵌在 plansJson）
      for (final trip in loaded) {
        try {
          final dbRecords = await local_db_service.LocalDbService.instance
              .getBudgetRecords(trip.itineraryId, userId: uid);
          trip.records.addAll(dbRecords.map((r) => BudgetRecord(
            title: r.title,
            category: r.category,
            amount: r.amount,
            payer: r.payer,
            createdAt: r.createdAt,
          )));
        } catch (e) {
          debugPrint('⚠️ [Budget] 載入消費紀錄失敗 ${trip.itineraryId}：$e');
        }
      }

      // 也載入共享預算列表
      final shared =
      await SharedBudgetService.instance.getMySharedBudgets();

      // 🌟 使用 Map 進行 unique 去重處理，徹底解決重複跑出三個一模一樣卡片的殘影 Bug！
      final Map<String, BudgetTrip> uniqueMap = {};
      for (var item in loaded) {
        uniqueMap[item.itineraryId] = item;
      }
      final dedupedTrips = uniqueMap.values.toList();

      // ★ 修正：在 setState 之前就完成 sharedBudgetId 回填，
      //   避免「第一幀 _trips 沒有 sharedBudgetId → orphan 重複顯示 → 第二幀才消失」的閃爍/重複 Bug。
      for (final trip in dedupedTrips) {
        // ★ 若這筆行程正在被切換成單人模式（_pendingSoloItineraryId），
        //   跳過 sharedBudgetId 回填，否則 isMultiMode 會被強制改回 true，
        //   導致被邀請人切換單人後立刻被打回多人 orphan 狀態。
        if (trip.itineraryId == _pendingSoloItineraryId) continue;
        if (trip.sharedBudgetId == null || trip.sharedBudgetId!.isEmpty) {
          final match = shared.where((b) => b.itineraryId == trip.itineraryId).firstOrNull;
          if (match != null) {
            trip.sharedBudgetId = match.id;
            trip.isMultiMode = true;
            debugPrint('🔗 [LoadData-Pre] 預先回填 sharedBudgetId: ${trip.itineraryId} → ${match.id}');
          }
        }
      }

      setState(() {
        _trips.clear();
        _trips.addAll(dedupedTrips); // 只把去重 + 已回填的乾淨資料放進去
        _sharedBudgets = shared;
        _isLoading = false;
      });

      // ★ 二次補強：針對「isMultiMode=true 但 sharedBudgetId 仍為 null」的行程再嘗試配對
      //   （理論上預先回填已處理，此處作為保險）
      bool needRebuild = false;
      for (final trip in _trips) {
        if (trip.itineraryId == _pendingSoloItineraryId) continue; // ★ 同樣跳過
        if (trip.isMultiMode && (trip.sharedBudgetId == null || trip.sharedBudgetId!.isEmpty)) {
          final match = shared.where((b) => b.itineraryId == trip.itineraryId).firstOrNull;
          if (match != null) {
            trip.sharedBudgetId = match.id;
            needRebuild = true;
            debugPrint('🔗 [LoadData] 補充回填 sharedBudgetId: ${trip.itineraryId} → ${match.id}');
          }
        }
      }
      if (needRebuild && mounted) setState(() {});

      if (widget.initialItineraryId != null) {
        final exists = _trips.any((t) => t.itineraryId == widget.initialItineraryId);
        if (exists) {
          WidgetsBinding.instance.addPostFrameCallback(
                  (_) => setState(() => _selectedLocalItineraryId = widget.initialItineraryId));
        }
      }
    } catch (e) {
      debugPrint('⚠️ [Budget] 載入失敗：$e');
      setState(() => _isLoading = false);
    }
  }

  // ── 監聽 pending 邀請（badge 通知）─────────────────────────
  void _listenInvites() {
    SharedBudgetService.instance
        .watchPendingInvites()
        .listen((invites) {
      if (mounted) setState(() => _pendingInvites = invites);
    });
  }

  // ── 當選擇某個共享預算時，建立 Stream ─────────────────────
  // ★ 完整改寫：移除舊 guard，改用 watchBudget stream 監聽單一預算
  void _selectSharedBudget(SharedBudget budget) async {
    // ✦ 修正 1：每次進入都強制取消並重置舊訂閱
    _cleanupBudgetDetailSub();

    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final myMember = budget.members.where((m) => m.uid == myUid).firstOrNull;
    final myName = myMember?.displayName ?? '未知使用者';

    // ★ 核心修復：先同步拉取既有紀錄，填入快取後再 setState，
    //   確保 StreamBuilder 的 initialData 第一幀就有資料，不會出現「進入後瞬間歸零」。
    //   不使用 .then() 非同步，改用 await 確保順序正確。
    List<SharedBudgetRecord> prefetchedRecords = _cachedRecords.isNotEmpty &&
        _watchingBudgetId == budget.id
        ? _cachedRecords  // 同一個 budget 重進，沿用現有快取
        : [];
    if (prefetchedRecords.isEmpty) {
      try {
        prefetchedRecords = await SharedBudgetService.instance.getRecords(budget.id);
      } catch (_) {}
    }

    if (!mounted) return;

    // ★ 關鍵順序修正：先 setState 設定所有狀態變數（含已預取的快取），
    //   再 await logOpenAction（logOpenAction 會寫 Firestore，觸發 watchMySharedBudgets 推送，
    //   若此時 _selectedSharedId 還是 null，_listenSharedBudgets 會誤判為被踢出並清空 stream）
    setState(() {
      _watchingBudgetId = budget.id;
      _selectedSharedId = budget.id;
      _watchingBudgetDetail = budget;
      _selectedLocalItineraryId = null;
      _dashboardEnterCount++;  // 每次進入遞增，確保 TweenAnimationBuilder key 唯一
      // ★ 用預取結果填充快取，StreamBuilder initialData 第一幀就有資料
      _cachedRecords = prefetchedRecords;
      _recordsStream = SharedBudgetService.instance.watchRecords(budget.id).map((recs) {
        _cachedRecords = recs; // 每次推送都更新快取
        return recs;
      });
    });

    // 非同步寫入紀錄（不影響 UI 狀態）
    SharedBudgetService.instance.logOpenAction(budget.id, myName).catchError((e) {
      debugPrint('⚠️ [SelectBudget] logOpenAction failed: \$e');
    });

    // ★ 監聽這個預算房間本體的雲端變化
    _budgetDetailSub = SharedBudgetService.instance
        .watchBudget(budget.id)
        .listen(
          (updatedBudget) async {
        if (!mounted) return;

        // 檢查自己是否還在雲端成員清單內
        final isStillMember = updatedBudget?.members.any((m) => m.uid == myUid) ?? false;

        // ★【修正】只有「房間被解散（null）」或「被創立者踢出（isStillMember == false）」
        //         才執行清除本地資料。主動按返回鍵只是 UI 退出，不觸發此路徑。
        if (updatedBudget == null || !isStillMember) {
          _cleanupBudgetDetailSub();

          final targetItineraryId = budget.itineraryId;

          if (updatedBudget == null) {
            // 房間被解散：完整清除本地快取
            if (targetItineraryId != null && targetItineraryId.isNotEmpty) {
              await local_db_service.LocalDbService.instance
                  .clearBudgetDataForItinerary(targetItineraryId);
            }
            setState(() {
              _trips.removeWhere((t) => t.itineraryId == targetItineraryId);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('該共享房間已被創立者徹底解散',
                    style: TextStyle(fontFamily: 'MyCustomFont')),
                backgroundColor: const Color(0xFFA5CBD4),
              ),
            );
          } else {
            // 被踢出：僅清除消費紀錄快取，保留行程骨架（讓首頁仍顯示卡片，但為單人模式）
            if (targetItineraryId != null && targetItineraryId.isNotEmpty) {
              await local_db_service.LocalDbService.instance
                  .clearBudgetDataForItinerary(targetItineraryId);
            }
            // 將行程切回單人模式（保留卡片，不消失）
            setState(() {
              for (final t in _trips) {
                if (t.itineraryId == targetItineraryId) {
                  t.isMultiMode = false;
                  t.sharedBudgetId = null;
                }
              }
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('您已被移出此共享行程，已自動切換為單人模式',
                    style: TextStyle(fontFamily: 'MyCustomFont')),
                backgroundColor: const Color(0xFFA5CBD4),
              ),
            );
          }

          setState(() {
            _selectedSharedId = null;
            _watchingBudgetId = null;
            _watchingBudgetDetail = null;
            _recordsStream = null;
            _cachedRecords = []; // 清空快取
          });

          _loadData();
        } else {
          // 正常同步：即時更新物件
          setState(() => _watchingBudgetDetail = updatedBudget);
        }
      },
      onError: (e) async {
        // ★ stream error 只記錄 log，不清空狀態（避免短暫網路問題導致記錄消失）
        // 真正的「被踢出」由 updatedBudget == null 判斷
        debugPrint('⚠️ [BudgetDetailSub] stream error (ignored): $e');
      },
    );

    // ★ 已移除 _showWelcomePopup（它的 barrierDismissible: false 加上 historyLog 寫入
    //   造成與 _listenSharedBudgets stream 的時序競態，導致記錄消失。改成 SnackBar 輕提示）
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📊 已進入「${budget.title}」多人分帳', style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: _green,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  // ★ 打開頁面時的彈跳式通知（含近期開啟紀錄）
  void _showWelcomePopup(SharedBudget budget) {
    // 從 historyLogs 取最近 5 筆「打開了管理頁面」或其他動作的紀錄
    final logs = List<Map<String, dynamic>>.from(
      (budget.historyLogs)
          .whereType<Map<String, dynamic>>()
          .toList(),
    );
    // 依 timestamp 降序排列，取最近 5 筆
    logs.sort((a, b) {
      final ta = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime(0);
      final tb = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime(0);
      return tb.compareTo(ta);
    });
    final recentLogs = logs.take(5).toList();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.playlist_add_check_circle_rounded, color: Color(0xFF8BAA88), size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text('共享分帳房間已開啟',
                  style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('您已成功開啟「${budget.title}」的管理頁面。',
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 12),
                // 房間資訊
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFF8BAA88).withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.star_rounded, size: 12, color: Color(0xFF7D6E5D)),
                        const SizedBox(width: 6),
                        Text('行程創立者：${budget.ownerName}',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.group_rounded, size: 12, color: Colors.grey),
                        const SizedBox(width: 6),
                        Text('當前成員：${budget.members.length} 人即時同步',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                      ]),
                    ],
                  ),
                ),
                // 近期動態紀錄
                if (recentLogs.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Row(children: [
                    Icon(Icons.history_rounded, size: 13, color: Color(0xFF8BAA88)),
                    SizedBox(width: 6),
                    Text('近期成員動態',
                        style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900)),
                  ]),
                  const SizedBox(height: 8),
                  ...recentLogs.map((log) {
                    final userName = log['userName'] ?? '成員';
                    final action   = log['action']   ?? '';
                    final ts       = DateTime.tryParse(log['timestamp'] ?? '');
                    final timeStr  = ts != null
                        ? '${ts.month}/${ts.day} ${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}'
                        : '';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15))),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 11,
                            backgroundColor: const Color(0xFF8BAA88).withOpacity(0.15),
                            child: Text(
                              userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 10, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('$userName $action',
                                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF7D6E5D))),
                          ),
                          if (timeStr.isNotEmpty)
                            Text(timeStr,
                                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 10),
                const Text('💡 創立者可直接點擊成員頭像右上角的 ✕ 移出成員。',
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8BAA88), height: 1.5)),
              ],
            ),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8BAA88),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('開始管理', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
  // ──────────────────────────────────────────────────────────
  //  本地行程 → BudgetTrip 轉換（保留原邏輯）
  // ──────────────────────────────────────────────────────────
  // ★ 修正：只讀取 meta（isMultiMode / members / sharedBudgetId），
  //   消費紀錄不再從 plansJson 嵌入讀取，改由 _loadBudgetRecords 從獨立資料表載入
  // ── 千分位格式化 ─────────────────────────────────────────────
  String _fmtNum(int n) => n.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  BudgetTrip _itineraryToBudgetTrip(SavedItinerary it) {
    bool isMultiMode = false;
    List<String> members = ['自己'];
    String? sharedBudgetId;

    try {
      final decoded = jsonDecode(it.plansJson);
      if (decoded is Map && decoded.containsKey('_budget_meta')) {
        final meta = decoded['_budget_meta'] as Map<String, dynamic>;
        isMultiMode = meta['isMultiMode'] == true;
        if (meta['members'] is List) {
          members = List<String>.from(meta['members']);
        }
        sharedBudgetId = meta['sharedBudgetId'] as String?;
        // ★ 不再從 meta['records'] 讀取消費紀錄（已改存獨立資料表）
      }
    } catch (_) {}

    return BudgetTrip(
      itineraryId: it.id,
      name: it.title,
      icon: it.isFromAi
          ? Icons.auto_awesome_rounded
          : Icons.map_rounded,
      budget: it.estimatedBudget,
      isMultiMode: isMultiMode,
      members: members,
      records: [],  // ★ 由 _loadBudgetRecords 填入
      sharedBudgetId: sharedBudgetId,
    );
  }

  // ── 儲存預算 meta 回行程 ───────────────────────────────────
  Future<void> _saveBudgetMeta(BudgetTrip trip) async {
    final existing =
    await local_db_service.LocalDbService.instance.getItinerary(trip.itineraryId);
    if (existing == null) return;

    // ★ 修正：確認行程屬於目前登入帳號，避免跨帳號寫入
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (existing.userId.isNotEmpty && currentUid.isNotEmpty &&
        existing.userId != currentUid) {
      debugPrint('⚠️ [Budget] _saveBudgetMeta 跳過：行程 userId 不符（${existing.userId} != $currentUid）');
      return;
    }

    dynamic originalPlans;
    try {
      final decoded = jsonDecode(existing.plansJson);
      originalPlans = decoded is Map && decoded.containsKey('_budget_meta')
          ? decoded['plans']
          : decoded;
    } catch (_) {
      originalPlans = [];
    }

    // ★ 修正：不再將消費紀錄嵌入 plansJson（改存獨立 budget_records 資料表）
    //   只保留 isMultiMode / members / sharedBudgetId 等設定資訊
    final newJson = jsonEncode({
      'plans': originalPlans,
      '_budget_meta': {
        'isMultiMode': trip.isMultiMode,
        'members': trip.members,
        'sharedBudgetId': trip.sharedBudgetId,
        // ★ 已移除 'records'，不再嵌入，避免跨帳號同步時洩漏消費紀錄
      },
    });

    final updated = SavedItinerary(
      id: existing.id,
      userId: existing.userId,
      title: existing.title,
      estimatedBudget: trip.budget,
      startDate: existing.startDate,
      endDate: existing.endDate,
      plansJson: newJson,
      isFromAi: existing.isFromAi,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await FirebaseSyncService.instance.updateItinerary(updated);

    // ★ Bug 2 修復：同步將模式設定存入 itinerary_budget_configs 表，且必須帶入 userId
    //   確保各帳號的 isMultiMode 設定完全隔離，不互相汙染。
    final effectiveUid = existing.userId.isNotEmpty ? existing.userId : currentUid;
    if (effectiveUid.isNotEmpty) {
      final config = ItineraryBudgetConfig(
        itineraryId: trip.itineraryId,
        userId: effectiveUid,
        budgetLimit: trip.budget,
        isMultiMode: trip.isMultiMode,
        membersJson: jsonEncode(trip.members),
        updatedAt: DateTime.now(),
      );
      await FirebaseSyncService.instance.saveBudgetConfig(config);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  Build
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: _cream,
        body: Center(
            child: CircularProgressIndicator(color: _green)),
      );
    }

    // 若展開本地行程 Dashboard
    if (_selectedLocalItineraryId != null) {
      final idx = _trips.indexWhere((t) => t.itineraryId == _selectedLocalItineraryId);
      if (idx >= 0) {
        return TweenAnimationBuilder<double>(
          key: ValueKey('local_$_selectedLocalItineraryId'),
          tween: Tween(begin: 0.88, end: 1.0),
          duration: const Duration(milliseconds: 380),
          curve: Curves.elasticOut,
          builder: (_, scale, child) => Transform.scale(scale: scale, child: Opacity(opacity: ((scale - 0.88) / 0.12).clamp(0.0, 1.0), child: child)),
          child: _buildLocalDashboard(idx),
        );
      }
      // 若 reload 後找不到（行程被刪），自動回首頁
      // ★ 但若 _pendingSoloItineraryId 有值，代表 _loadData 還在進行中，先顯示 loading 等待
      if (_pendingSoloItineraryId != null) {
        return const Scaffold(
          backgroundColor: _cream,
          body: Center(child: CircularProgressIndicator(color: _green)),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback(
              (_) => setState(() => _selectedLocalItineraryId = null));
    }

    // 若展開共享預算 Dashboard
    if (_selectedSharedId != null) {
      // ★ 優先使用即時 stream 更新的 budget 物件，fallback 到列表快照
      final budget = _watchingBudgetDetail ??
          _sharedBudgets
              .where((b) => b.id == _selectedSharedId)
              .firstOrNull;
      if (budget != null) {
        return TweenAnimationBuilder<double>(
          key: ValueKey('shared_${_selectedSharedId}_$_dashboardEnterCount'),
          tween: Tween(begin: 0.88, end: 1.0),
          duration: const Duration(milliseconds: 380),
          curve: Curves.elasticOut,
          builder: (_, scale, child) => Transform.scale(scale: scale, child: Opacity(opacity: ((scale - 0.88) / 0.12).clamp(0.0, 1.0), child: child)),
          child: _buildSharedDashboard(budget),
        );
      }
    }

    // 首頁：行程記帳列表（已移除共享多人分帳 Tab，直接顯示本地行程）
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _cream,
      drawer: const _HomeStyleDrawer(),
      body: NestedScrollView(
        headerSliverBuilder: (ctx, _) => [
          SliverToBoxAdapter(
            child: _buildTopHeader(
              'MY BUDGET',
              '旅遊記帳與多人分帳系統',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ★ 刷新按鈕（本地行程列表同步更新）
                  GestureDetector(
                    onTap: _manualRefresh,
                    child: AnimatedRotation(
                      turns: _isRefreshing ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 600),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _isRefreshing
                              ? _green.withOpacity(0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.sync_rounded,
                          size: 20,
                          color: _isRefreshing ? _green : _brown.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ),
                  // ★ 更多選單（清除所有記錄）
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded, size: 20, color: _brown.withOpacity(0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (v) async {
                      if (v == 'clear_all') await _showDeleteTripsDialog();
                      if (v == 'sync_check') {
                        _promptedSyncIds.clear();
                        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                        if (uid.isNotEmpty) {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.remove('budget_sync_prompted_$uid');
                        }
                        await _checkFirstSyncNeeded();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'sync_check',
                        child: Row(children: [
                          Icon(Icons.sync_rounded, size: 18, color: Color(0xFF8BAA88)),
                          SizedBox(width: 8),
                          Text('重新同步行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'clear_all',
                        child: Row(children: [
                          Icon(Icons.delete_sweep_rounded, size: 18, color: const Color(0xFFA5CBD4)),
                          SizedBox(width: 8),
                          Text('清除所有消費記錄', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFA5CBD4), fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    ],
                  ),
                  if (_pendingInvites.isNotEmpty) _inviteBadge(),
                ],
              ),
            ),
          ),
          // ★ 新增：總覽統計摘要卡
          SliverToBoxAdapter(child: _buildSummaryCard()),
        ],
        body: _buildLocalTripList(),
      ),
    );
  }

  // ── 統計摘要卡（新增）────────────────────────────────────────
  Widget _buildSummaryCard() {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final totalTrips = _trips.length;
    int totalBudget = 0;
    int totalSpent = 0;
    int overCount = 0;

    for (final t in _trips) {
      final isMultiActive = t.isMultiMode && t.sharedBudgetId != null && t.sharedBudgetId!.isNotEmpty;
      final spent = isMultiActive ? (_sharedSpentCache[t.sharedBudgetId] ?? 0) : t.totalSpent;
      final linked = isMultiActive ? _sharedBudgets.where((b) => b.id == t.sharedBudgetId).firstOrNull : null;
      final budget = isMultiActive && linked != null ? linked.totalBudget : t.budget;
      totalBudget += budget;
      totalSpent  += spent;
      if (spent > budget && budget > 0) overCount++;
    }

    final remaining = totalBudget - totalSpent;
    final ratio = totalBudget > 0 ? (totalSpent / totalBudget).clamp(0.0, 1.0) : 0.0;
    final isOver = remaining < 0;

    if (totalTrips == 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: isOver
              ? [const Color(0xFFA5CBD4).withOpacity(0.15), const Color(0xFFA5CBD4).withOpacity(0.05)]
              : [_green.withOpacity(0.13), _green.withOpacity(0.04)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isOver ? const Color(0xFFA5CBD4).withOpacity(0.4) : _green.withOpacity(0.3)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.025), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isOver ? const Color(0xFFA5CBD4).withOpacity(0.15) : _green.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.account_balance_wallet_rounded, size: 18, color: isOver ? const Color(0xFFA5CBD4) : _green),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('所有行程總覽', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: _brown)),
              Text('共 $totalTrips 筆行程${overCount > 0 ? "，$overCount 筆超預算" : ""}',
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: overCount > 0 ? const Color(0xFFA5CBD4) : Colors.grey)),
            ]),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(isOver ? '超出 NT\$${(-remaining).toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}' : '剩餘 NT\$${remaining.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}',
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900,
                      color: isOver ? const Color(0xFFA5CBD4) : _green)),
              Text('總預算 NT\$${totalBudget.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
            ]),
          ]),
          const SizedBox(height: 14),
          // 進度條
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: Colors.white.withOpacity(0.6),
              valueColor: AlwaysStoppedAnimation(isOver ? const Color(0xFFA5CBD4) : (ratio > 0.8 ? const Color(0xFFE8A87C) : _green)),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            _summaryChip(Icons.payments_rounded, 'NT\$${totalSpent.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}', '已花費'),
            const SizedBox(width: 8),
            _summaryChip(Icons.person_rounded, _trips.where((t) => !t.isMultiMode).length.toString(), '單人行程'),
            const SizedBox(width: 8),
            _summaryChip(Icons.group_rounded, _trips.where((t) => t.isMultiMode).length.toString(), '多人行程'),
          ]),
        ],
      ),
    );
  }

  Widget _summaryChip(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.65),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 12, color: _green),
            const SizedBox(width: 4),
            Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900, color: _brown)),
          ]),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
        ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  Tab 0：本地行程列表
  // ══════════════════════════════════════════════════════════

  // ★ 完整覆蓋整段 _buildLocalTripList 函數，保障每個帳戶在首頁都能看見右下角新增預算行程按鈕！
  Widget _buildLocalTripList() {
    // ★【核心修正】：合併本地行程 + 未在 _trips 出現的共享預算，統一在首頁呈現
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final boundSharedIds = _trips
        .where((t) => t.sharedBudgetId != null && t.sharedBudgetId!.isNotEmpty)
        .map((t) => t.sharedBudgetId!)
        .toSet();

    final boundItineraryIds = _trips.map((t) => t.itineraryId).toSet();

    final orphanShared = _sharedBudgets
        .where((b) =>
    !boundSharedIds.contains(b.id) &&
        !(b.itineraryId != null && boundItineraryIds.contains(b.itineraryId)))
        .toList();

    // ── 搜尋過濾 ──
    final searchLower = _searchQuery.toLowerCase();
    var filteredTrips = _searchQuery.isEmpty
        ? List<BudgetTrip>.from(_trips)
        : _trips.where((t) => t.name.toLowerCase().contains(searchLower)).toList();
    var filteredOrphan = _searchQuery.isEmpty
        ? orphanShared
        : orphanShared.where((b) => b.title.toLowerCase().contains(searchLower)).toList();

    // ── 分類標籤過濾 ──
    if (_filterTag != '全部') {
      filteredTrips = filteredTrips.where((t) {
        final isMultiActive = t.isMultiMode && t.sharedBudgetId != null && t.sharedBudgetId!.isNotEmpty;
        final spent = isMultiActive ? (_sharedSpentCache[t.sharedBudgetId] ?? 0) : t.totalSpent;
        final linked = isMultiActive ? _sharedBudgets.where((b) => b.id == t.sharedBudgetId).firstOrNull : null;
        final budget = isMultiActive && linked != null ? linked.totalBudget : t.budget;
        final ratio = budget > 0 ? spent / budget : 0.0;
        switch (_filterTag) {
          case '充足': return ratio < 0.8 && spent <= budget;
          case '快爆了': return ratio >= 0.8 && spent <= budget;
          case '超預算': return spent > budget && budget > 0;
          case '單人': return !t.isMultiMode;
          case '多人': return t.isMultiMode;
          default: return true;
        }
      }).toList();

      filteredOrphan = filteredOrphan.where((b) {
        final spent = _sharedSpentCache[b.id] ?? 0;
        final ratio = b.totalBudget > 0 ? spent / b.totalBudget : 0.0;
        switch (_filterTag) {
          case '充足': return ratio < 0.8 && spent <= b.totalBudget;
          case '快爆了': return ratio >= 0.8 && spent <= b.totalBudget;
          case '超預算': return spent > b.totalBudget && b.totalBudget > 0;
          case '單人': return false; // orphan 全是多人
          case '多人': return true;
          default: return true;
        }
      }).toList();
    }

    final filteredTotal = filteredTrips.length + filteredOrphan.length;

    // ── 各標籤計數 ──
    int countAll = _trips.length + orphanShared.length;
    int countSolo = _trips.where((t) => !t.isMultiMode).length;
    int countMulti = _trips.where((t) => t.isMultiMode).length + orphanShared.length;
    int countOver = _trips.where((t) {
      final isMultiActive = t.isMultiMode && t.sharedBudgetId != null;
      final spent = isMultiActive ? (_sharedSpentCache[t.sharedBudgetId] ?? 0) : t.totalSpent;
      final budget = t.budget;
      return spent > budget && budget > 0;
    }).length + orphanShared.where((b) {
      final spent = _sharedSpentCache[b.id] ?? 0;
      return spent > b.totalBudget && b.totalBudget > 0;
    }).length;

    final filterTags = [
      ('全部', countAll, Icons.grid_view_rounded),
      ('充足', null, Icons.check_circle_outline_rounded),
      ('快爆了', null, Icons.trending_up_rounded),
      ('超預算', countOver > 0 ? countOver : null, Icons.warning_amber_rounded),
      ('單人', countSolo, Icons.person_rounded),
      ('多人', countMulti, Icons.group_rounded),
    ];

    return Stack(
      children: [
        Column(
          children: [
            // ── 搜尋列 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _isSearching ? _green : Colors.grey.withOpacity(0.2)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8)],
                ),
                child: Row(children: [
                  const SizedBox(width: 12),
                  Icon(Icons.search_rounded, color: _isSearching ? _green : Colors.grey, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() { _searchQuery = v; _isSearching = v.isNotEmpty; }),
                      onTap: () => setState(() => _isSearching = true),
                      onTapOutside: (_) { if (_searchQuery.isEmpty) setState(() => _isSearching = false); },
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜尋行程名稱…',
                        hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey[400], fontSize: 13),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    GestureDetector(
                      onTap: () { _searchCtrl.clear(); FocusScope.of(context).unfocus(); setState(() { _searchQuery = ''; _isSearching = false; }); },
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.close_rounded, color: Colors.grey[400], size: 16),
                      ),
                    ),
                  GestureDetector(
                    onTap: () => FocusScope.of(context).unfocus(),
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: _isSearching ? _green.withOpacity(0.12) : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: _isSearching ? _green : Colors.grey.withOpacity(0.4),
                      ),
                    ),
                  ),
                ]),
              ),
            ),

            // ── 分類標籤列 ──
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                itemCount: filterTags.length,
                itemBuilder: (_, i) {
                  final (label, count, icon) = filterTags[i];
                  final isActive = _filterTag == label;
                  return GestureDetector(
                    onTap: () => setState(() => _filterTag = label),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      decoration: BoxDecoration(
                        color: isActive ? _green : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isActive ? _green : Colors.grey.withOpacity(0.25),
                          width: isActive ? 1.5 : 1,
                        ),
                        boxShadow: isActive ? [BoxShadow(color: _green.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 2))] : [],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 12, color: isActive ? Colors.white : Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text(label,
                              style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isActive ? Colors.white : Colors.grey[600],
                              )),
                          if (count != null) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: isActive ? Colors.white.withOpacity(0.25) : _green.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('$count',
                                  style: TextStyle(
                                    fontFamily: 'MyCustomFont',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: isActive ? Colors.white : _green,
                                  )),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // 待回覆邀請橫幅
            if (_pendingInvites.isNotEmpty) _buildInviteBanner(),

            Expanded(
              child: filteredTotal == 0
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.account_balance_wallet_outlined, size: 64, color: _green.withOpacity(0.4)),
                    const SizedBox(height: 16),
                    Text(
                      _filterTag == '全部' ? '尚無行程預算' : '沒有「$_filterTag」的行程',
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _filterTag == '全部' ? '點擊右下角「+」即可手動新增行程！' : '試試切換其他分類標籤',
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                itemCount: filteredTotal,
                itemBuilder: (_, i) {
                  if (i < filteredTrips.length) {
                    final tripIndex = _trips.indexOf(filteredTrips[i]);
                    return _buildTripCard(tripIndex >= 0 ? tripIndex : i);
                  } else {
                    final shared = filteredOrphan[i - filteredTrips.length];
                    return _buildOrphanSharedCard(shared, myUid);
                  }
                },
              ),
            ),
          ],
        ),
        // ★ 核心修復：將 FAB 移出條件分支，確保每個帳號的首頁都擁有最高權限建立獨立行程
        Positioned(
          bottom: 24,
          right: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 小提示文字（有行程時才顯示）
              if (_trips.isNotEmpty || orphanShared.isNotEmpty) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _brown.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '共 ${_trips.length + orphanShared.length} 筆',
                    style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              FloatingActionButton(
                onPressed: _showAddTripDialog,
                backgroundColor: _green,
                elevation: 6,
                child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ★ 被邀請加入的共享行程卡片（沒有本地骨架，直接由 _sharedBudgets stream 驅動）
  Widget _buildOrphanSharedCard(SharedBudget budget, String myUid) {
    final spent = _sharedSpentCache[budget.id] ?? 0;
    final ratio = budget.totalBudget > 0
        ? (spent / budget.totalBudget).clamp(0.0, 1.0)
        : 0.0;
    final overBudget = spent > budget.totalBudget && budget.totalBudget > 0;
    final isOwner = budget.ownerUid == myUid;
    final isPressed = _pressedOrphanId == budget.id;

    return TweenAnimationBuilder<double>(
      key: ValueKey('orphan_enter_${budget.id}'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: child),
      ),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressedOrphanId = budget.id),
        onTapCancel: () => setState(() => _pressedOrphanId = null),
        onTapUp: (_) => Future.delayed(const Duration(milliseconds: 150), () { if (mounted) setState(() => _pressedOrphanId = null); }),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 1.0, end: isPressed ? 0.93 : 1.0),
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeInOut,
          builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: overBudget
                      ? const Color(0xFFA5CBD4).withOpacity(0.4)
                      : _green.withOpacity(0.2)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 標題列
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.group_rounded, color: _green, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(budget.title,
                                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.bold, color: _brown),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(
                              isOwner ? '我建立 · 多人分帳模式' : '${budget.ownerName} 建立 · 多人分帳模式',
                              style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      // ★ 新增：離開/刪除選單，讓使用者可以移除此卡片
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded, color: Colors.grey, size: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        onSelected: (v) async {
                          if (v == 'leave_or_delete') {
                            await _leaveOrDelete(budget);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'leave_or_delete',
                            child: Row(children: [
                              Icon(isOwner ? Icons.delete_outline_rounded : Icons.exit_to_app_rounded,
                                  size: 18, color: const Color(0xFFA5CBD4)),
                              const SizedBox(width: 8),
                              Text(isOwner ? '刪除共享預算' : '離開共享預算',
                                  style: const TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFA5CBD4), fontWeight: FontWeight.bold)),
                            ]),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // 進度條（雲端即時花費）
                  Stack(
                    children: [
                      Container(height: 10, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.12), borderRadius: BorderRadius.circular(8))),
                      AnimatedFractionallySizedBox(
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOutCubic,
                        widthFactor: ratio.toDouble(),
                        child: Container(
                          height: 10,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: LinearGradient(
                              colors: overBudget
                                  ? [const Color(0xFFA5CBD4).withOpacity(0.8), const Color(0xFFA5CBD4)]
                                  : [_green.withOpacity(0.7), _green],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 數據列
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('預算: NT\$ ${budget.totalBudget}',
                          style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                      Text('支出: NT\$ $spent',
                          style: TextStyle(fontFamily: 'MyCustomFont', color: overBudget ? const Color(0xFFA5CBD4) : _brown, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // ★ 單人/多人 Segmented 切換（orphan 卡片，預設多人但也可切單人）
                  Row(
                    children: [
                      // 單人按鈕（目前 orphan 卡片沒有本地 trip，點單人時建立骨架並切換）
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            // orphan 卡片切單人：建立本地骨架 + 切換
                            final ok = await _showModeConfirmSheet(
                              title: '切換到單人模式？',
                              subtitle: '切換後進入本地單人帳本，多人帳本資料仍保留在雲端。',
                              confirmLabel: '確定切換',
                            );
                            if (ok != true || !mounted) return;
                            final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                            final targetItineraryId = budget.itineraryId ?? const Uuid().v4();

                            // 建立本地骨架（若不存在）
                            final existing = await local_db_service.LocalDbService.instance
                                .getItinerary(targetItineraryId);
                            if (existing == null) {
                              final nowStr = DateTime.now().toIso8601String();
                              final d = await local_db_service.LocalDbService.instance.db;
                              await d.insert('saved_itineraries', {
                                'id': targetItineraryId,
                                'user_id': uid,
                                'title': budget.title,
                                'estimated_budget': budget.totalBudget,
                                'start_date': nowStr, 'end_date': nowStr,
                                'plans_json': '[]',
                                'is_from_ai': 0,
                                'created_at': nowStr, 'updated_at': nowStr,
                              }, conflictAlgorithm: ConflictAlgorithm.ignore);
                            }
                            if (!mounted) return;

                            // ★ 問題2最終修法：完全不呼叫 _loadData()，
                            // 避免 _loadData 回填邏輯與 _listenSharedBudgets stream
                            // 把 isMultiMode 強制打回 true 的所有競態問題。
                            // 直接手動建立 BudgetTrip 並插入 _trips，然後設定目標 id 進入 Dashboard。
                            final newTrip = BudgetTrip(
                              itineraryId: targetItineraryId,
                              name: budget.title,
                              budget: budget.totalBudget,
                              isMultiMode: false,   // ← 明確單人
                              sharedBudgetId: null, // ← 不綁雲端
                            );

                            setState(() {
                              // 若 _trips 已有這筆（前次切換殘留），先移除
                              _trips.removeWhere((t) => t.itineraryId == targetItineraryId);
                              _trips.insert(0, newTrip);
                              _pendingSoloItineraryId = targetItineraryId; // 保護鎖
                              _selectedLocalItineraryId = targetItineraryId;
                            });

                            // 背景儲存 meta（不 await，不阻塞 UI）
                            _saveBudgetMeta(newTrip).then((_) async {
                              // meta 寫完後等 stream 消化，再清旗標
                              await Future.delayed(const Duration(milliseconds: 800));
                              if (mounted) setState(() => _pendingSoloItineraryId = null);
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              // ★ orphan 卡片永遠是「多人」active，單人為非 active 樣式（與 _buildTripCard 一致）
                              color: Colors.grey.withOpacity(0.08),
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                              border: Border.all(color: Colors.grey.withOpacity(0.2)),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.person_rounded, size: 14, color: Colors.grey),
                                SizedBox(width: 5),
                                Text('單人記帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 多人按鈕（已是多人，點擊直接進 dashboard）
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _selectSharedBudget(budget),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              // ★ 多人 active → 用 _brown 填充（與 _buildTripCard 一致）
                              color: _brown,
                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
                              border: Border.all(color: _brown),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.group_rounded, size: 14, color: Colors.white),
                                SizedBox(width: 5),
                                Text('多人分帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),   // ← Container 結束
          ),   // ← scale TweenAnimationBuilder 結束
        ),   // ← GestureDetector 結束
      ),   // ← 入場 TweenAnimationBuilder 結束
    );
  }
  // ══════════════════════════════════════════════════════════
  //  Tab 1：共享預算列表
  // ══════════════════════════════════════════════════════════

  Widget _buildSharedBudgetList() {
    return Stack(
      children: [
        // pending 邀請橫幅
        Column(
          children: [
            if (_pendingInvites.isNotEmpty)
              _buildInviteBanner(),
            Expanded(
              child: _sharedBudgets.isEmpty
                  ? _buildSharedEmptyState()
                  : ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 100),
                itemCount: _sharedBudgets.length,
                itemBuilder: (_, i) =>
                    _buildSharedBudgetCard(_sharedBudgets[i]),
              ),
            ),
          ],
        ),
        Positioned(
          bottom: 24,
          right: 24,
          child: FloatingActionButton.extended(
            onPressed: _showCreateSharedBudgetDialog,
            backgroundColor: _green,
            icon: const Icon(Icons.group_add_rounded,
                color: Colors.white),
            label: const Text('建立共享記帳',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildSharedEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.group_outlined,
              size: 64, color: _green.withOpacity(0.4)),
          const SizedBox(height: 16),
          const Text('尚無共享記帳',
              style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: Colors.grey,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('點擊右下角建立，邀請旅伴一起記帳',
              style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: Colors.grey,
                  fontSize: 13)),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  邀請通知橫幅
  // ──────────────────────────────────────────────────────────

  Widget _buildInviteBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _brown.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _brown.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.mail_outline_rounded,
                  color: _brown, size: 16),
              const SizedBox(width: 6),
              Text('你有 ${_pendingInvites.length} 則待回覆邀請',
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: _brown,
                      fontWeight: FontWeight.w900,
                      fontSize: 13)),
            ],
          ),
          ..._pendingInvites.map((inv) => _buildInviteRow(inv)),
        ],
      ),
    );
  }

  Widget _buildInviteRow(SharedBudgetInvite inv) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border:
        Border.all(color: _green.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(inv.title,
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: _brown,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                Text('${inv.ownerName} 邀請你加入',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.grey,
                        fontSize: 11)),
              ],
            ),
          ),
          // 接受按鈕
          // ★ 核心架構修正：完美注入本地行程主表骨架建立，徹底解決成員跳出後紀錄走失的 Bug！
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: () async {
                // 1. 呼叫底層雲端服務接受邀請，取得最新共享房間狀態
                final joined = await SharedBudgetService.instance.acceptInvite(inv.budgetId);
                if (!mounted) return;

                if (joined == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('⚠️ 加入失敗，你可能已被移出或房間已刪除',
                          style: TextStyle(fontFamily: 'MyCustomFont')),
                      backgroundColor: const Color(0xFFA5CBD4),
                    ),
                  );
                  return;
                }

                final myUid = FirebaseAuth.instance.currentUser?.uid ?? "";
                if (myUid.isNotEmpty && joined.itineraryId != null) {
                  // 2. 完美歷史繼承：主動同步多人房間設定至本地 SQLite 獨立預算設定表
                  await FirebaseSyncService.instance.syncBudgetForItinerary(
                    itineraryId: joined.itineraryId!,
                    budgetLimit: joined.totalBudget,
                    uid: myUid,
                  );

                  // 3. ★【核心架構修復：解決阿里郎退出後不顯示、走失的關鍵核心】★
                  // 新成員阿里郎接受邀請時，本地 SQLite 主表根本沒有這筆行程骨架（因為行程是王萱萱自建的）
                  // 我們在此處直接往 SQLite 主表 insert 這筆行程骨架與多人 Meta，確保首頁 _loadData() 隨時撈得到這張卡片入口！
                  try {
                    final nowStr = DateTime.now().toIso8601String();
                    final d = await local_db_service.LocalDbService.instance.db;

                    // 檢查是否已存在，防重複寫入
                    final existingIt = await local_db_service.LocalDbService.instance.getItinerary(joined.itineraryId!);
                    if (existingIt == null) {
                      final metaJson = jsonEncode({
                        'plans': [],
                        '_budget_meta': {
                          'isMultiMode': true,
                          'members': joined.members.map((m) => m.displayName).toList(),
                          'sharedBudgetId': joined.id,
                        },
                      });

                      // ── 🎯 請精準修改這段的最後一行 ──
                      await d.insert('saved_itineraries', {
                        'id': joined.itineraryId,
                        'user_id': myUid,
                        'title': joined.title,
                        'estimated_budget': joined.totalBudget,
                        'start_date': nowStr,
                        'end_date': nowStr,
                        'plans_json': metaJson,
                        'is_from_ai': 0,
                        'created_at': nowStr,
                        'updated_at': nowStr,
                      }, conflictAlgorithm: ConflictAlgorithm.replace); // ✅ 修正：直接呼叫即可！
                    }
                  } catch (e) {
                    debugPrint('⚠️ [Invite] 建立新成員本地主表骨架失敗：$e');
                  }
                }

                // ✦ 保留你原本的所有 SnackBar 提示與客製化字體設計
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('✅ 已成功加入「${inv.title}」！',
                        style: const TextStyle(fontFamily: 'MyCustomFont')),
                    backgroundColor: _green,
                    duration: const Duration(seconds: 2),
                  ),
                );

                // 4. 先把新 budget 加到本地列表快照
                setState(() {
                  if (!_sharedBudgets.any((b) => b.id == joined.id)) {
                    _sharedBudgets = [joined, ..._sharedBudgets];
                  }
                });

                // 5. 強制通知本地全域重載，讓首頁立刻渲染出這張剛加入的多人共享行程卡片！
                await _loadData();

                // 6. 順暢切換進入多人房間即時 Dashboard
                _selectSharedBudget(joined);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: const Text('接受',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 6),
          // 拒絕按鈕
          SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: () async {
                await SharedBudgetService.instance
                    .declineInvite(inv.budgetId);
              },
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.grey),
                  padding:
                  const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: const Text('拒絕',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _inviteBadge() {
    return Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_outlined,
              color: _brown),
          onPressed: _showInviteBottomSheet,
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(
                color: const Color(0xFFA5CBD4),
                shape: BoxShape.circle),
            child: Text(
              '${_pendingInvites.length}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  // ★ 邀請通知 BottomSheet（通知鈴鐺點擊後顯示，接受/拒絕後即時更新）
  void _showInviteBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          // 監聽外層 state 的 _pendingInvites 變化
          // 用 addPostFrameCallback 實現：每次外層 rebuild 後同步
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (sheetCtx.mounted) setSheetState(() {});
          });

          final invites = _pendingInvites;
          return Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拉桿
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.notifications_active_rounded,
                        color: _green, size: 22),
                    const SizedBox(width: 8),
                    Text('待回覆邀請（${invites.length}）',
                        style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: _brown,
                            fontWeight: FontWeight.w900,
                            fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 16),
                if (invites.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.check_circle_outline_rounded,
                              color: _green, size: 40),
                          SizedBox(height: 8),
                          Text('所有邀請都已處理完畢！',
                              style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  )
                else
                  ..._pendingInvites.map((inv) => _buildInviteRowInSheet(inv, sheetCtx)),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  // ★ 在 BottomSheet 內使用的邀請列，接受後自動關閉 sheet 並跳入行程
  Widget _buildInviteRowInSheet(SharedBudgetInvite inv, BuildContext sheetCtx) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _green.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(inv.title,
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: _brown,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                Text('${inv.ownerName} 邀請你加入',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.grey,
                        fontSize: 11)),
              ],
            ),
          ),
          // ★ 核心架構修正：完整 SizedBox 區塊，解決新成員阿里郎退出預算畫面就走失消失的重大 Bug！
          // ★ 完整覆蓋此整段 SizedBox，徹底根除阿里郎退出後紀錄從首頁走失消失的 Bug！
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: () async {
                final joined = await SharedBudgetService.instance.acceptInvite(inv.budgetId);
                if (!mounted) return;

                if (joined == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('⚠️ 加入失敗，你可能已被移出或房間已刪除', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFA5CBD4)),
                  );
                  return;
                }

                final myUid = FirebaseAuth.instance.currentUser?.uid ?? "";
                if (myUid.isNotEmpty && joined.itineraryId != null) {
                  await FirebaseSyncService.instance.syncBudgetForItinerary(itineraryId: joined.itineraryId!, budgetLimit: joined.totalBudget, uid: myUid);

                  // ★【核心架構修復】：直接在本地 SQLite 主表寫入完整的行程主鍵骨架
                  try {
                    final nowStr = DateTime.now().toIso8601String();
                    final d = await local_db_service.LocalDbService.instance.db;

                    final metaJson = jsonEncode({
                      'plans': [],
                      '_budget_meta': {
                        'isMultiMode': true,
                        'members': joined.members.map((m) => m.displayName).toList(),
                        'sharedBudgetId': joined.id, // 核心雲端房間 doc_id 綁定
                      },
                    });

                    // 檢查防重複
                    final existingIt = await local_db_service.LocalDbService.instance.getItinerary(joined.itineraryId!);
                    if (existingIt == null) {
                      // 完美修復 ConflictAlgorithm 列舉紅線
                      await d.insert('saved_itineraries', {
                        'id': joined.itineraryId, 'user_id': myUid, 'title': joined.title, 'estimated_budget': joined.totalBudget,
                        'start_date': nowStr, 'end_date': nowStr, 'plans_json': metaJson, 'is_from_ai': 0, 'created_at': nowStr, 'updated_at': nowStr,
                      }, conflictAlgorithm: ConflictAlgorithm.replace);
                    } else {
                      await d.update('saved_itineraries', {'plans_json': metaJson}, where: 'id = ?', whereArgs: [joined.itineraryId]);
                    }
                  } catch (e) {
                    debugPrint('⚠️ [Invite] 建立阿里郎本地主表骨架失敗：$e');
                  }
                }

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ 已成功加入「${inv.title}」！', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _green, duration: const Duration(seconds: 2)),
                );

                // ★ 同步塞入快取變數，防返回首頁列表斷流
                final mockTrip = BudgetTrip(
                  itineraryId: joined.itineraryId ?? const Uuid().v4(),
                  name: joined.title, budget: joined.totalBudget, isMultiMode: true, sharedBudgetId: joined.id,
                );
                setState(() {
                  _trips.removeWhere((t) => t.itineraryId == joined.itineraryId || t.sharedBudgetId == joined.id);
                  _trips.insert(0, mockTrip);
                });

                // 強制全域數據流重載，讓首頁立刻刷出卡片入口！
                await _loadData();
                _selectSharedBudget(joined);
              },
              style: ElevatedButton.styleFrom(backgroundColor: _green, padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: const Text('接受', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 6),
          // ✦ 下方原有的「拒絕」按鈕代碼保持不變...
          SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: () async {
                await SharedBudgetService.instance.declineInvite(inv.budgetId);
                // _listenInvites stream 會自動更新，外層 setState 觸發 sheet rebuild
              },
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.grey),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: const Text('拒絕',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  共享預算卡片
  // ──────────────────────────────────────────────────────────

  Widget _buildSharedBudgetCard(SharedBudget budget) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isOwner = budget.ownerUid == myUid;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _green.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題列
          Row(
            children: [
              const Icon(Icons.group_rounded, color: _green, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(budget.title,
                        style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _brown)),
                    Text(
                        '${budget.members.length} 位成員 ·'
                            ' ${isOwner ? '我建立的' : '${budget.ownerName} 建立'}',
                        style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 11,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              // 更多選項
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded,
                    color: Colors.grey),
                onSelected: (v) async {
                  if (v == 'invite') {
                    _showInviteDialog(budget);
                  } else if (v == 'budget') {
                    _showChangeBudgetDialog(budget);
                  } else if (v == 'leave') {
                    await _leaveOrDelete(budget);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'invite',
                      child: Row(children: [
                        Icon(Icons.person_add_outlined,
                            size: 18, color: _green),
                        SizedBox(width: 8),
                        Text('邀請成員加入',
                            style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: _brown,
                                fontWeight: FontWeight.bold))
                      ])),
                  const PopupMenuItem(
                      value: 'budget',
                      child: Row(children: [
                        Icon(Icons.edit_outlined,
                            size: 18, color: _brown),
                        SizedBox(width: 8),
                        Text('修改預算上限',
                            style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: _brown,
                                fontWeight: FontWeight.bold))
                      ])),
                  PopupMenuItem(
                      value: 'leave',
                      child: Row(children: [
                        Icon(
                            isOwner
                                ? Icons.delete_outline_rounded
                                : Icons.exit_to_app_rounded,
                            size: 18,
                            color: const Color(0xFFA5CBD4)),
                        const SizedBox(width: 8),
                        Text(isOwner ? '刪除共享預算' : '離開共享預算',
                            style: const TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: const Color(0xFFA5CBD4),
                                fontWeight: FontWeight.bold))
                      ])),
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),

          // 成員頭像列
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: budget.members.map((m) {
                final initial = m.displayName.isNotEmpty
                    ? m.displayName[0].toUpperCase()
                    : '?';
                return Tooltip(
                  message: m.displayName,
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: m.isOwner
                          ? _green.withOpacity(0.2)
                          : _cream,
                      child: Text(initial,
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: m.isOwner ? _green : _brown)),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 14),

          // 預算資訊列
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                    '預算上限 NT\$ ${budget.totalBudget}',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: _green,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
              const Spacer(),
              // 進入按鈕
              // 找到 _buildSharedBudgetCard 中的進入按鈕修改如下：
              // 找到外層卡片「進入按鈕」修改為：
              SizedBox(
                height: 36,
                child: ElevatedButton(
                  onPressed: () {
                    _selectSharedBudget(budget); // ✦ 改為傳入完整的 budget 物件，才能觸發日誌和彈窗
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 16)),
                  child: const Text('進入管理頁面',
                      style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  共享預算 Dashboard（StreamBuilder 即時更新）
  // ══════════════════════════════════════════════════════════

  Widget _buildSharedDashboard(SharedBudget budget) {
    return Scaffold(
      backgroundColor: _cream,
      body: StreamBuilder<List<SharedBudgetRecord>>(
        stream: _recordsStream,
        // ★ initialData：StreamBuilder 重建時（如 Navigator.pop 後）立刻顯示快取資料，
        //   不用等 Firestore 再次推送，徹底解決「多人記錄重新進入後消失」問題
        initialData: _cachedRecords.isNotEmpty ? _cachedRecords : null,
        builder: (ctx, snap) {
          // ── [Fix-8] error state：stream 出錯時顯示錯誤而非靜默空列表 ──
          if (snap.hasError) {
            debugPrint('⚠️ [StreamBuilder] records stream error: ${snap.error}');
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(
                      '載入消費紀錄失敗\n${snap.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.grey,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () {
                        // 重建 stream
                        setState(() {
                          _recordsStream = SharedBudgetService.instance
                              .watchRecords(_watchingBudgetId!);
                        });
                      },
                      icon: const Icon(Icons.refresh_rounded, color: Color(0xFF8BAA88)),
                      label: const Text('重試',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: Color(0xFF8BAA88))),
                    ),
                  ],
                ),
              ),
            );
          }
          // ── [Fix-8] loading state：首次等待時顯示骨架，而非空列表 ──
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF8BAA88),
                strokeWidth: 2,
              ),
            );
          }
          final records = snap.data ?? [];
          final totalSpent =
          records.fold<int>(0, (s, r) => s + r.amount);
          final overBudget =
              budget.totalBudget > 0 &&
                  totalSpent > budget.totalBudget;
          final ratio = budget.totalBudget > 0
              ? (totalSpent / budget.totalBudget).clamp(0.0, 1.0)
              : 0.0;

          // 分類合計
          final Map<String, int> catTotals = {
            '美食': 0,
            '住宿': 0,
            '交通': 0,
            '購物': 0,
            '其他': 0
          };
          for (final r in records) {
            if (catTotals.containsKey(r.category)) {
              catTotals[r.category] =
                  catTotals[r.category]! + r.amount;
            }
          }
          final activeCats = catTotals.entries
              .where((e) => e.value > 0)
              .toList();

          // 結算
          final settlements =
          SharedBudgetService.instance.calculateSettlement(
            members: budget.members,
            records: records,
          );

          return Stack(
            children: [
              CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  // ── 頂部 NavBar（雙行，避免溢出）─────────────────────
                  SliverToBoxAdapter(
                    child: SafeArea(
                      bottom: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── 第一行：返回 + 標題 ──
                            Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _brown, size: 20),
                                  padding: const EdgeInsets.all(8),
                                  constraints: const BoxConstraints(),
                                  onPressed: () {
                                    _cleanupBudgetDetailSub();
                                    setState(() {
                                      _selectedSharedId = null;
                                      _watchingBudgetId = null;
                                      _watchingBudgetDetail = null;
                                      _recordsStream = null;
                                      // ★ 返回時刻意保留 _cachedRecords，
                                      //   下次重進同一個 budget 時 initialData 仍有資料，不閃零。
                                      //   _cachedRecords 只在切換不同 budget 時才清空（在 setState 裡判斷）
                                    });
                                  },
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(budget.title,
                                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 17, fontWeight: FontWeight.w900, color: _brown),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                      Row(
                                        children: [
                                          const Icon(Icons.group_rounded, size: 11, color: _green),
                                          const SizedBox(width: 3),
                                          Text('${budget.members.length} 位成員即時同步',
                                              style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                                          if (snap.connectionState == ConnectionState.active)
                                            Container(margin: const EdgeInsets.only(left: 5), width: 5, height: 5,
                                                decoration: const BoxDecoration(color: _green, shape: BoxShape.circle)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            // ── 第二行：邀請 + 刷新 + 單人/多人切換 ──
                            Padding(
                              padding: const EdgeInsets.only(left: 12, right: 4, bottom: 6),
                              child: Row(
                                children: [
                                  // 邀請按鈕
                                  GestureDetector(
                                    onTap: () => _showInviteDialog(budget),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: _green.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(color: _green.withOpacity(0.4)),
                                      ),
                                      child: const Row(children: [
                                        Icon(Icons.person_add_outlined, size: 13, color: _green),
                                        SizedBox(width: 4),
                                        Text('邀請', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                                      ]),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // ★ 共同編輯行程景點按鈕
                                  if (budget.itineraryId != null && budget.itineraryId!.isNotEmpty)
                                    GestureDetector(
                                      onTap: () => _openSharedItinerary(budget),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: _brown.withOpacity(0.08),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: _brown.withOpacity(0.3)),
                                        ),
                                        child: const Row(children: [
                                          Icon(Icons.map_rounded, size: 13, color: _brown),
                                          SizedBox(width: 4),
                                          Text('共編行程', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
                                        ]),
                                      ),
                                    ),
                                  if (budget.itineraryId != null && budget.itineraryId!.isNotEmpty)
                                    const SizedBox(width: 8),
                                  // 刷新按鈕
                                  GestureDetector(
                                    onTap: _manualRefresh,
                                    child: AnimatedRotation(
                                      turns: _isRefreshing ? 1.0 : 0.0,
                                      duration: const Duration(milliseconds: 600),
                                      child: Container(
                                        padding: const EdgeInsets.all(7),
                                        decoration: BoxDecoration(
                                          color: _isRefreshing ? _green.withOpacity(0.15) : Colors.grey.withOpacity(0.08),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(Icons.refresh_rounded, size: 16, color: _isRefreshing ? _green : Colors.grey),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  // 單人/多人切換
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.grey.withOpacity(0.07),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.grey.withOpacity(0.15)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        GestureDetector(
                                          onTap: () async {
                                            final ok = await _showModeConfirmSheet(
                                              title: '切換到單人模式？',
                                              subtitle: '切換後進入本地單人帳本，多人帳本資料仍保留在雲端。',
                                              confirmLabel: '確定切換',
                                            );
                                            if (ok != true || !mounted) return;
                                            final tripIdx = _trips.indexWhere((t) => t.sharedBudgetId == budget.id || t.itineraryId == budget.itineraryId);
                                            _cleanupBudgetDetailSub();
                                            setState(() {
                                              _selectedSharedId = null;
                                              _watchingBudgetId = null;
                                              _watchingBudgetDetail = null;
                                              _recordsStream = null;
                                              _cachedRecords = []; // 清空快取
                                              if (tripIdx >= 0) {
                                                _trips[tripIdx].isMultiMode = false;
                                                _trips[tripIdx].sharedBudgetId = null;
                                                _selectedLocalItineraryId = _trips[tripIdx].itineraryId;
                                              }
                                            });
                                            if (tripIdx >= 0) await _saveBudgetMeta(_trips[tripIdx]);
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                            decoration: const BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.horizontal(left: Radius.circular(11))),
                                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                              Icon(Icons.person_rounded, size: 12, color: Colors.grey),
                                              SizedBox(width: 3),
                                              Text('單人', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                                            ]),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                          decoration: BoxDecoration(color: _brown, borderRadius: const BorderRadius.horizontal(right: Radius.circular(11))),
                                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                            Icon(Icons.group_rounded, size: 12, color: Colors.white),
                                            SizedBox(width: 3),
                                            Text('多人', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                                          ]),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── 預算進度卡片 ─────────────────────
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 8),
                    sliver: SliverToBoxAdapter(
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius:
                          BorderRadius.circular(28),
                          border: Border.all(
                              color: overBudget
                                  ? const Color(0xFFA5CBD4)
                                  .withOpacity(0.4)
                                  : _green.withOpacity(0.5),
                              width: 1.5),
                          boxShadow: [
                            BoxShadow(
                                color: _green.withOpacity(0.05),
                                blurRadius: 15,
                                offset: const Offset(0, 8))
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        'NT\$ $totalSpent',
                                        style: TextStyle(
                                            fontFamily:
                                            'MyCustomFont',
                                            fontSize: 32,
                                            fontWeight:
                                            FontWeight.w900,
                                            color: overBudget
                                                ? const Color(0xFFA5CBD4)
                                                : _brown)),
                                    Text(
                                        '預算上限 NT\$ ${budget.totalBudget}',
                                        style: const TextStyle(
                                            fontFamily:
                                            'MyCustomFont',
                                            fontSize: 13,
                                            color: Colors.grey,
                                            fontWeight:
                                            FontWeight.bold)),
                                  ],
                                ),
                                if (overBudget)
                                  Container(
                                    padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5),
                                    decoration: BoxDecoration(
                                      color: Colors.red
                                          .withOpacity(0.1),
                                      borderRadius:
                                      BorderRadius.circular(
                                          20),
                                    ),
                                    child: const Text('超出預算',
                                        style: TextStyle(
                                            fontFamily:
                                            'MyCustomFont',
                                            fontSize: 11,
                                            color:
                                            const Color(0xFFA5CBD4),
                                            fontWeight:
                                            FontWeight.bold)),
                                  )
                                else
                                  (() {
                                    final _isOwner = budget.ownerUid == FirebaseAuth.instance.currentUser?.uid;
                                    return GestureDetector(
                                      onTap: _isOwner ? () => _showChangeBudgetDialog(_watchingBudgetDetail ?? budget) : null,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Row(mainAxisSize: MainAxisSize.min, children: [
                                            Text(
                                              'NT\$ ${budget.totalBudget - totalSpent}',
                                              style: const TextStyle(fontFamily: 'MyCustomFont', color: _green, fontWeight: FontWeight.w900, fontSize: 18),
                                            ),
                                            if (_isOwner) ...[
                                              const SizedBox(width: 4),
                                              const Icon(Icons.edit_rounded, size: 12, color: _green),
                                            ],
                                          ]),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(color: _green.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                              Icon(Icons.savings_rounded, size: 11, color: _green),
                                              SizedBox(width: 3),
                                              Text('可用', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: _green, fontWeight: FontWeight.bold)),
                                            ]),
                                          ),
                                        ],
                                      ),
                                    );
                                  })(),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius:
                              BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: ratio.toDouble(),
                                backgroundColor: Colors.grey
                                    .withOpacity(0.15),
                                valueColor:
                                AlwaysStoppedAnimation<Color>(
                                    overBudget
                                        ? const Color(0xFFA5CBD4)
                                        : ratio >= 0.8
                                        ? const Color(0xFF9E8E83) // ★ 80% 深棕警示（配色統一）
                                        : _green),
                                minHeight: 10,
                              ),
                            ),
                            // ★ 80% 警示提示列
                            if (!overBudget && ratio >= 0.8)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.warning_amber_rounded, size: 13, color: Color(0xFF9E8E83)),
                                    const SizedBox(width: 5),
                                    Text(
                                      '已使用 ${(ratio * 100).toStringAsFixed(0)}%，即將接近預算上限！',
                                      style: const TextStyle(
                                          fontFamily: 'MyCustomFont',
                                          fontSize: 11,
                                          color: Color(0xFF9E8E83),
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── 成員付款統計 ─────────────────────
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 8),
                    sliver: SliverToBoxAdapter(
                      child: _buildMemberPaymentCard(
                          budget, records),
                    ),
                  ),

                  // ── 圓餅圖 ──────────────────────────
                  if (activeCats.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      sliver: SliverToBoxAdapter(
                        child: _buildDonutCard(
                            activeCats, totalSpent),
                      ),
                    ),

                  // ── 結算建議 ─────────────────────────
                  if (settlements.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 4),
                      sliver: SliverToBoxAdapter(
                        child: () {
                          // ★ 修正：依每筆紀錄實際參與人員計算各人應付金額（名稱對照）
                          final allUids = budget.members.map((m) => m.uid).toList();
                          final Map<String, int> shouldPayUid = {for (final uid in allUids) uid: 0};
                          for (final r in records) {
                            final parts = r.splitParticipants.isEmpty
                                ? allUids
                                : r.splitParticipants.where((uid) => shouldPayUid.containsKey(uid)).toList();
                            if (parts.isEmpty) continue;
                            final share = r.amount ~/ parts.length;
                            final remainder = r.amount - share * parts.length;
                            for (int i = 0; i < parts.length; i++) {
                              shouldPayUid[parts[i]] = (shouldPayUid[parts[i]] ?? 0) + share + (i == 0 ? remainder : 0);
                            }
                          }
                          // uid → displayName 對照
                          final Map<String, int> shouldPayByName = {};
                          for (final m in budget.members) {
                            shouldPayByName[m.displayName] = shouldPayUid[m.uid] ?? 0;
                          }
                          return _buildSharedSettlementCard(
                              settlements,
                              totalSpent,
                              budget.members.length,
                              shouldPayMap: shouldPayByName);
                        }(),
                      ),
                    ),

                  // ── 消費紀錄清單 ──────────────────────
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        24, 16, 24, 120),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                            (ctx, idx) {
                          if (idx == 0) {
                            return Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                const Text('消費明細紀錄',
                                    style: TextStyle(
                                        fontFamily:
                                        'MyCustomFont',
                                        fontSize: 16,
                                        fontWeight:
                                        FontWeight.w900,
                                        color: _brown)),
                                const SizedBox(height: 8),
                                Container(
                                    height: 1.5,
                                    color:
                                    _green.withOpacity(0.2),
                                    margin: const EdgeInsets.only(
                                        bottom: 12)),
                                if (records.isEmpty)
                                  Container(
                                    padding:
                                    const EdgeInsets.symmetric(
                                        vertical: 32),
                                    alignment: Alignment.center,
                                    child: Column(
                                      children: [
                                        Icon(
                                            Icons
                                                .receipt_long_outlined,
                                            size: 42,
                                            color: Colors.grey
                                                .withOpacity(0.4)),
                                        const SizedBox(height: 8),
                                        const Text(
                                            '尚無消費紀錄，點擊右下角「+」新增',
                                            style: TextStyle(
                                                fontFamily:
                                                'MyCustomFont',
                                                color: Colors.grey,
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                              ],
                            );
                          }
                          final r = records[idx - 1];
                          return _buildSharedRecordTile(
                              r, budget.id);
                        },
                        childCount: records.length + 1,
                      ),
                    ),
                  ),
                ],
              ),

              // ── FAB 新增 ─────────────────────────────
              Positioned(
                bottom: 24,
                right: 24,
                child: GestureDetector(
                  onTap: () =>
                      _openSharedAddExpensePage(budget),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: _green,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                            color: _green.withOpacity(0.4),
                            blurRadius: 15,
                            offset: const Offset(0, 6))
                      ],
                    ),
                    child: const Icon(Icons.add_rounded,
                        color: Colors.white, size: 36),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  成員付款統計卡片（共享模式）
  // ──────────────────────────────────────────────────────────

  // ── 修正：成員付款統計卡片（創立者看到 ✕，非創立者看不到；角色標示清楚）
  Widget _buildMemberPaymentCard(SharedBudget budget, List<SharedBudgetRecord> records) {
    final Map<String, int> paid = {for (var m in budget.members) m.uid: 0};
    for (final r in records) {
      paid[r.payerUid] = (paid[r.payerUid] ?? 0) + r.amount;
    }

    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isIOwner = budget.ownerUid == myUid;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_outline_rounded, size: 16, color: _brown),
              const SizedBox(width: 6),
              // ★ 根據身份顯示不同標題文字
              Expanded(
                child: Text(
                  isIOwner
                      ? '成員付款統計 · 點 ✕ 可移除成員'
                      : '成員付款統計',
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: _brown),
                ),
              ),
              // ★ 自己的身份標籤（創立者 / 成員）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isIOwner
                      ? _brown.withOpacity(0.10)
                      : _green.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: isIOwner
                          ? _brown.withOpacity(0.3)
                          : _green.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        isIOwner ? Icons.star_rounded : Icons.person_rounded,
                        size: 10,
                        color: isIOwner ? _brown : _green),
                    const SizedBox(width: 4),
                    Text(
                        isIOwner ? '我是創立者' : '我是成員',
                        style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 10,
                            color: isIOwner ? _brown : _green,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: budget.members.map((m) {
                final amount = paid[m.uid] ?? 0;
                final initial = m.displayName.isNotEmpty ? m.displayName[0].toUpperCase() : '?';
                final isMe = m.uid == myUid;

                return GestureDetector(
                  onLongPress: (isIOwner && !isMe) ? () {
                    _showKickMemberConfirmDialog(budget.id, m.uid, m.displayName);
                  } : null,
                  child: Container(
                    margin: const EdgeInsets.only(right: 20),
                    child: Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // ★ 頭像：創立者用金色邊框，我自己用綠色背景，一般成員用預設
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: m.isOwner
                                    ? Border.all(color: _brown.withOpacity(0.6), width: 2)
                                    : isMe
                                    ? Border.all(color: _green.withOpacity(0.6), width: 2)
                                    : null,
                              ),
                              child: CircleAvatar(
                                radius: 22,
                                backgroundColor: isMe
                                    ? _green.withOpacity(0.15)
                                    : m.isOwner
                                    ? _brown.withOpacity(0.10)
                                    : _cream,
                                child: Text(initial,
                                    style: TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        fontSize: 14,
                                        color: isMe ? _green : m.isOwner ? _brown : _brown,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                            // 創立者星星標記（右下角）
                            if (m.isOwner)
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: _brown.withOpacity(0.15),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 1),
                                  ),
                                  child: const Icon(Icons.star_rounded, size: 9, color: _brown),
                                ),
                              ),
                            // ★ 只有創立者（isIOwner）才能看到其他人頭像上的 ✕ 按鈕
                            if (isIOwner && !isMe)
                              Positioned(
                                right: -6,
                                top: -6,
                                child: GestureDetector(
                                  onTap: () => _showKickMemberConfirmDialog(budget.id, m.uid, m.displayName),
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: const BoxDecoration(
                                        color: const Color(0xFFA5CBD4),
                                        shape: BoxShape.circle),
                                    child: const Icon(Icons.close_rounded, size: 11, color: Colors.white),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // ★ 名字下方加小標籤（創立者 / 我 / 成員）
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isMe ? '我' : m.displayName,
                              style: const TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold),
                            ),
                            if (m.isOwner) ...[
                              const SizedBox(width: 3),
                              const Icon(Icons.star_rounded, size: 9, color: _brown),
                            ],
                          ],
                        ),
                        // ★ 角色膠囊：創立者 / 成員
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: m.isOwner
                                ? _brown.withOpacity(0.08)
                                : _green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            m.isOwner ? '創立者' : '成員',
                            style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                fontSize: 9,
                                color: m.isOwner ? _brown : _green,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text('NT\$ $amount',
                            style: const TextStyle(
                                fontFamily: 'MyCustomFont',
                                fontSize: 12,
                                color: _brown,
                                fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // ★ 說明文字：根據身份顯示不同提示
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  isIOwner ? Icons.info_outline_rounded : Icons.lock_outline_rounded,
                  size: 12,
                  color: Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  isIOwner
                      ? '作為創立者，你可以點擊成員頭像上的 ✕ 將其移出。'
                      : '只有行程創立者可以管理成員（加入 / 移除）。',
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 10,
                      color: Colors.grey,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ★ 新增功能：踢人確認對話框
  void _showKickMemberConfirmDialog(String budgetId, String targetUid, String targetName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('強制移出成員「$targetName」？', style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.w900)),
        content: const Text('確定要將該使用者踢出此共享記帳房間嗎？被移出後，他將失去此帳戶的管理與檢視權利。', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.grey, fontFamily: 'MyCustomFont'))
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final success = await SharedBudgetService.instance.kickMember(
                budgetId: budgetId,
                targetUid: targetUid,
                targetName: targetName,
              );
              if (success && mounted) {
                // ★ 不需要 _loadData()：_budgetDetailSub 的 stream 會自動更新成員卡片
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('已將「$targetName」移出，畫面將自動同步'),
                        backgroundColor: _brown)
                );
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('操作失敗，請確認你是否為創立者'),
                        backgroundColor: const Color(0xFFA5CBD4))
                );
              }
            },
            child: const Text('確定踢除', style: TextStyle(color: const Color(0xFFA5CBD4), fontWeight: FontWeight.bold, fontFamily: 'MyCustomFont')),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  共享結算建議卡片
  // ──────────────────────────────────────────────────────────

  Widget _buildSharedSettlementCard(
      List<SettlementEntry> settlements, int total, int count,
      {Map<String, int>? shouldPayMap}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _brown.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _brown.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_rounded,
                  color: _brown, size: 16),
              SizedBox(width: 6),
              Text('分帳結算建議',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: _brown)),
            ],
          ),
          const SizedBox(height: 8),
          Text('總消費 NT\$ $total',
              style: const TextStyle(
                  fontFamily: 'MyCustomFont',
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold)),
          // ★ 新增：各人應付金額（依實際參與筆數計算）
          if (shouldPayMap != null && shouldPayMap.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: shouldPayMap.entries.map((e) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _cream,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _brown.withOpacity(0.15)),
                ),
                child: Text('${e.key} 應付 NT\$ ${e.value}',
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
              )).toList(),
            ),
          ],
          const SizedBox(height: 10),
          ...settlements.map((s) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _green.withOpacity(0.3))),
            child: Row(
              children: [
                const Icon(Icons.arrow_forward_rounded,
                    size: 14, color: _green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      '${s.fromName} → ${s.toName}',
                      style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 13,
                          color: _brown,
                          fontWeight: FontWeight.bold)),
                ),
                Text('NT\$ ${s.amount}',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 13,
                        color: _green,
                        fontWeight: FontWeight.w900)),
              ],
            ),
          )),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  共享消費紀錄單列（可滑動刪除）
  // ──────────────────────────────────────────────────────────

  Widget _buildSharedRecordTile(
      SharedBudgetRecord r, String budgetId) {
    final color = _catColors[r.category] ?? Colors.grey;
    final icon = _catIcons[r.category] ?? Icons.receipt_long_rounded;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final canEdit = r.createdBy == myUid;

    final cardContent = Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 3))
          ]),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.title,
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: _brown)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(r.category,
                        style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 11,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: _cream,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _green.withOpacity(0.3))),
                      child: Text('付: ${r.payerName}',
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 10,
                              color: _brown,
                              fontWeight: FontWeight.bold)),
                    ),
                    if (r.splitParticipants.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _green.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _green.withOpacity(0.35)),
                        ),
                        child: Text(
                          '${r.splitParticipants.length}人分攤',
                          style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 10,
                            color: _green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text('by ${r.createdBy == myUid ? '我' : r.payerName}',
                        style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 10,
                            color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('-NT\$ ${r.amount}',
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: _brown)),
              // ★ 若是自己新增的，顯示可點擊的「編輯」膠囊按鈕
              if (canEdit)
                GestureDetector(
                  onTap: () => _showRecordActionSheet(r, budgetId),
                  child: Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _green.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _green.withOpacity(0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_rounded, size: 11, color: _green),
                        SizedBox(width: 3),
                        Text('編輯', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: _green, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    return cardContent;
  }

  // ★ 編輯/刪除選單（點擊「編輯」膠囊後跳出）
  void _showRecordActionSheet(SharedBudgetRecord r, String budgetId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: _cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
            Text(r.title,
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: _brown)),
            const SizedBox(height: 4),
            Text('-NT\$ ${r.amount}',
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: _green),
              title: const Text('修改這筆消費', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context);
                _showEditRecordDialog(r, budgetId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFA5CBD4)),
              title: const Text('刪除這筆消費', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFA5CBD4), fontWeight: FontWeight.bold)),
              onTap: () async {
                Navigator.pop(context);
                final ok = await SharedBudgetService.instance.deleteRecord(
                  budgetId: budgetId,
                  recordId: r.id,
                  createdBy: r.createdBy,
                );
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('刪除失敗', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _brown),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ★ 新增：編輯共享消費紀錄的 Dialog
  void _showEditRecordDialog(SharedBudgetRecord r, String budgetId) {
    final budget = _watchingBudgetDetail;
    if (budget == null) return;

    final titleCtrl = TextEditingController(text: r.title);
    final amountCtrl = TextEditingController(text: r.amount.toString());
    String selectedCategory = r.category;
    String selectedPayerName = r.payerName;
    final memberMap = {for (final m in budget.members) m.displayName: m.uid};

    // ★ 把既有 splitParticipants (UID) 轉回 displayName 清單
    final uidToName = {for (final m in budget.members) m.uid: m.displayName};
    List<String> splitParticipantNames = r.splitParticipants.isEmpty
        ? List<String>.from(budget.members.map((m) => m.displayName))
        : r.splitParticipants.map((uid) => uidToName[uid] ?? '').where((n) => n.isNotEmpty).toList();

    final categories = ['美食', '住宿', '交通', '購物', '其他'];
    final memberNames = budget.members.map((m) => m.displayName).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            decoration: const BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const Text('修改消費紀錄',
                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: _brown)),
                  const SizedBox(height: 16),

                  // 名稱
                  const Text('名稱', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown),
                    decoration: InputDecoration(
                      filled: true, fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _green, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 金額
                  const Text('金額', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown),
                    decoration: InputDecoration(
                      prefixText: 'NT\$ ',
                      prefixStyle: const TextStyle(color: _brown, fontWeight: FontWeight.bold),
                      filled: true, fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _green, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 類別
                  const Text('類別', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: categories.map((c) {
                      final sel = selectedCategory == c;
                      return GestureDetector(
                        onTap: () => setSheetState(() => selectedCategory = c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel ? _green.withOpacity(0.12) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: sel ? _green : const Color(0xFFE2E8F0), width: sel ? 1.5 : 1),
                          ),
                          child: Text(c, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: sel ? _green : Colors.grey[600], fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // 付款人
                  const Text('付款人', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: memberNames.map((name) {
                      final sel = selectedPayerName == name;
                      return GestureDetector(
                        onTap: () => setSheetState(() => selectedPayerName = name),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel ? _brown.withOpacity(0.10) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: sel ? _brown : const Color(0xFFE2E8F0), width: sel ? 1.5 : 1),
                          ),
                          child: Text(name, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: sel ? _brown : Colors.grey[600], fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // 參與分攤
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('參與分攤的人', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 13)),
                      GestureDetector(
                        onTap: () => setSheetState(() {
                          if (splitParticipantNames.length == memberNames.length) {
                            splitParticipantNames = [selectedPayerName];
                          } else {
                            splitParticipantNames = List<String>.from(memberNames);
                          }
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: _green.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: _green.withOpacity(0.3))),
                          child: Text(splitParticipantNames.length == memberNames.length ? '取消全選' : '全選',
                              style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _green, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: memberNames.map((m) {
                      final selected = splitParticipantNames.contains(m);
                      return GestureDetector(
                        onTap: () => setSheetState(() {
                          if (selected) {
                            if (splitParticipantNames.length > 1) splitParticipantNames.remove(m);
                          } else {
                            splitParticipantNames.add(m);
                          }
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: selected ? _green.withOpacity(0.12) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: selected ? _green : const Color(0xFFE2E8F0), width: selected ? 1.5 : 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 14, color: selected ? _green : Colors.grey[400]),
                              const SizedBox(width: 6),
                              Text(m, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: selected ? _green : Colors.grey[600], fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: _green, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                      onPressed: () async {
                        final newAmount = int.tryParse(amountCtrl.text.replaceAll(',', ''));
                        if (newAmount == null || newAmount <= 0 || titleCtrl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('請確認名稱和金額', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _brown),
                          );
                          return;
                        }

                        final payerUid = memberMap[selectedPayerName] ?? r.payerUid;

                        // ★ 修正：displayName → UID，全員時傳空清單
                        final splitUids = splitParticipantNames.length == memberNames.length
                            ? <String>[]
                            : splitParticipantNames
                            .map((name) => memberMap[name])
                            .whereType<String>()
                            .toList();

                        Navigator.pop(ctx);

                        final ok = await SharedBudgetService.instance.updateRecord(
                          budgetId: budgetId,
                          recordId: r.id,
                          createdBy: r.createdBy,
                          title: titleCtrl.text.trim(),
                          category: selectedCategory,
                          amount: newAmount,
                          payerUid: payerUid,
                          payerName: selectedPayerName,
                          splitParticipants: splitUids,
                        );

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '✅ 已更新！' : '更新失敗，只有新增者可以修改', style: const TextStyle(fontFamily: 'MyCustomFont')),
                              backgroundColor: ok ? _green : _brown,
                            ),
                          );
                        }
                      },
                      child: const Text('確認修改', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
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

  // ──────────────────────────────────────────────────────────
  //  新增共享消費頁（跳轉 AddExpenseScreen，回傳後寫 Firestore）
  // ──────────────────────────────────────────────────────────

  Future<void> _openSharedAddExpensePage(SharedBudget budget) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // ★ 修正成員付款統計不同步：將完整成員資訊（uid+displayName）傳入，
    //   回傳時直接帶 payerUid，不再靠脆弱的 displayName 反查。
    final memberMap = {for (final m in budget.members) m.displayName: m.uid};

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          isMultiMode: true,
          tripName: _getTripNameByItineraryId(budget.itineraryId),
          tripMembers: budget.members.map((m) => m.displayName).toList(),
        ),
      ),
    );

    if (result == null || !mounted) return;

    final payerName = result['payer'] as String;
    // ★ 修正：先用 memberMap 精確查 uid，找不到才 fallback myUid
    final payerUid = memberMap[payerName] ?? myUid;

    // ★ 修正：把 AddExpenseScreen 回傳的 displayName 清單轉換成 UID 清單
    final rawParticipants = (result['splitParticipants'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final participantUids = rawParticipants
        .map((name) => memberMap[name])
        .whereType<String>()
        .toList();
    // 全員參與時用空清單（= 全員均攤，向下相容舊資料）
    final splitUids = participantUids.length == budget.members.length
        ? <String>[]
        : participantUids;

    await SharedBudgetService.instance.addRecord(
      budgetId: budget.id,
      title: result['title'],
      category: result['category'],
      amount: result['amount'],
      payerUid: payerUid,
      payerName: payerName,
      note: result['note'] ?? '',
      // ★ 修正：傳入 UID 清單，讓結算邏輯正確按參與人數分攤
      splitParticipants: splitUids,
    );

    // ★ 新增完成後強制重建 stream（確保 StreamBuilder 立刻收到最新資料，
    //   處理 broadcast stream 在 Navigator.pop 後不重播的邊緣情況）
    if (mounted && _watchingBudgetId == budget.id) {
      setState(() {
        _recordsStream = SharedBudgetService.instance.watchRecords(budget.id).map((recs) {
          _cachedRecords = recs;
          return recs;
        });
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('💰 記帳成功！已即時同步給所有成員',
                style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: _green),
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  //  建立共享預算 Dialog
  // ══════════════════════════════════════════════════════════

  void _showCreateSharedBudgetDialog() {
    final nameCtrl   = TextEditingController();
    final budgetCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: const Text('建立共享記帳房間',
            style: TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('建立後可邀請旅伴加入，大家即時看到彼此的消費紀錄。',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.grey,
                    fontSize: 12,
                    height: 1.4)),
            const SizedBox(height: 16),
            _inputField(nameCtrl, '輸入行程名稱'),
            const SizedBox(height: 16),
            _inputField(budgetCtrl, '輸入總預算金額',
                prefixText: 'NT\$ ',
                keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty ||
                  budgetCtrl.text.isEmpty) return;
              Navigator.pop(ctx);

              final budgetId = await SharedBudgetService.instance
                  .createSharedBudget(
                title: nameCtrl.text.trim(),
                totalBudget:
                int.tryParse(budgetCtrl.text) ?? 0,
              );

              if (budgetId != null) {
                // 補寫 memberUids
                await SharedBudgetService.instance
                    .syncMemberUids(budgetId);
                await _loadData();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('✨ 共享記帳房間建立成功！可以邀請旅伴加入囉',
                            style: TextStyle(
                                fontFamily: 'MyCustomFont')),
                        backgroundColor: _green),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('確認建立',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  邀請成員 Dialog（Email 輸入 + 即時搜尋下拉列表）
  // ══════════════════════════════════════════════════════════

  // ★ 共享行程景點共同編輯入口
  Future<void> _openSharedItinerary(SharedBudget budget) async {
    final itineraryId = budget.itineraryId;
    if (itineraryId == null || itineraryId.isEmpty) return;

    // 從本地 SQLite 讀取行程
    final saved = await local_db_service.LocalDbService.instance.getItinerary(itineraryId);
    if (saved == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找不到此行程的景點資料，請確認行程已同步', style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: Color(0xFF9E9182),
          ),
        );
      }
      return;
    }

    // 解析 plansJson → TripPlan（使用 map_screen 的解析邏輯）
    // 因為 budget_screen 沒有直接引入 TripPlan，透過 Navigator 跳轉到 Map 頁面的行程詳情
    // 使用 AppStateManager 切換到地圖頁並帶入行程 ID
    if (mounted) {
      // 導向地圖頁，並在地圖頁開啟該行程的詳細頁面
      AppStateManager.currentTabNotifier.value = 1; // 地圖 tab
      // 透過短暫延遲確保頁面切換完成後再觸發行程打開
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已切換到地圖，請在「查看行程」中找到「${saved.title}」進行編輯',
                style: const TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: const Color(0xFF8BAA88),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showInviteDialog(SharedBudget budget) {
    final emailCtrl = TextEditingController();
    Map<String, String>? foundUser;
    bool isSearching = false;
    String? errorMsg;
    // 下拉建議列表：輸入過程中最多顯示近期搜尋結果
    List<Map<String, String>> suggestions = [];
    bool showSuggestions = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInnerState) => AlertDialog(
          backgroundColor: _cream,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24)),
          title: const Text('邀請成員加入',
              style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: _brown,
                  fontWeight: FontWeight.w900)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('邀請「${budget.title}」的新成員',
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontSize: 12)),
              const SizedBox(height: 4),
              const Text('輸入對方已在 App 登入的 Email 地址進行搜尋。',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontSize: 11,
                      height: 1.4)),
              const SizedBox(height: 12),

              // ── Email 搜尋欄（含下拉框）──────────────────
              Stack(
                clipBehavior: Clip.none,
                children: [
                  // 輸入列
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: _brown,
                              fontSize: 14),
                          decoration: InputDecoration(
                            hintText: '輸入對方 Email…',
                            hintStyle: TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: Colors.grey[400],
                                fontSize: 13),
                            prefixIcon: const Icon(Icons.search_rounded,
                                color: _green, size: 18),
                            suffixIcon: emailCtrl.text.isNotEmpty
                                ? IconButton(
                                icon: const Icon(Icons.clear_rounded,
                                    size: 16, color: Colors.grey),
                                onPressed: () {
                                  emailCtrl.clear();
                                  setInnerState(() {
                                    foundUser = null;
                                    errorMsg = null;
                                    suggestions = [];
                                    showSuggestions = false;
                                  });
                                })
                                : null,
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0))),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0))),
                            focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: _green, width: 1.5)),
                          ),
                          onChanged: (v) {
                            // 清除上一次的搜尋結果
                            setInnerState(() {
                              foundUser = null;
                              errorMsg = null;
                              showSuggestions = false;
                              suggestions = [];
                            });
                          },
                          onSubmitted: (_) async {
                            // 按 Enter 也觸發搜尋
                            setInnerState(() {
                              isSearching = true;
                              foundUser = null;
                              errorMsg = null;
                            });
                            await _doUserSearch(
                              emailCtrl.text.trim(),
                              budget,
                              setInnerState,
                                  (result) => foundUser = result,
                                  (err) => errorMsg = err,
                                  (s) => isSearching = s,
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 搜尋按鈕
                      SizedBox(
                        height: 46,
                        child: ElevatedButton(
                          onPressed: isSearching
                              ? null
                              : () async {
                            setInnerState(() {
                              isSearching = true;
                              foundUser = null;
                              errorMsg = null;
                            });
                            await _doUserSearch(
                              emailCtrl.text.trim(),
                              budget,
                              setInnerState,
                                  (result) => foundUser = result,
                                  (err) => errorMsg = err,
                                  (s) => isSearching = s,
                            );
                          },
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _green,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                  BorderRadius.circular(14))),
                          child: isSearching
                              ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2))
                              : const Text('搜尋',
                              style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // ── 現有成員清單（下拉選擇已知成員作為付款人參考）──
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _brown.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _brown.withOpacity(0.12))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.group_outlined,
                          size: 13, color: Colors.grey),
                      SizedBox(width: 5),
                      Text('目前已加入成員',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 11,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: budget.members.map((m) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius:
                              BorderRadius.circular(8),
                              border: Border.all(
                                  color: _green.withOpacity(0.25))),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 7,
                                backgroundColor:
                                m.isOwner
                                    ? _green.withOpacity(0.2)
                                    : _cream,
                                child: Text(
                                  m.displayName.isNotEmpty
                                      ? m.displayName[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                      fontSize: 8,
                                      color: m.isOwner
                                          ? _green
                                          : _brown,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(m.displayName,
                                  style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      fontSize: 11,
                                      color: _brown,
                                      fontWeight: FontWeight.bold)),
                              if (m.isOwner)
                                const Padding(
                                  padding: EdgeInsets.only(left: 3),
                                  child: Icon(Icons.star_rounded,
                                      size: 9, color: _brown),
                                ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),

              // ── 搜尋結果 ──────────────────────────────────
              if (errorMsg != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: const Color(0xFFA5CBD4).withOpacity(0.4))),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          size: 14, color: const Color(0xFFA5CBD4)),
                      const SizedBox(width: 8),
                      Text(errorMsg!,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: const Color(0xFFA5CBD4),
                              fontSize: 12)),
                    ],
                  ),
                ),
              ],
              if (foundUser != null) ...[
                const SizedBox(height: 10),
                // ★ 問題4：搜尋到使用者，卡片彈入動畫
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.85, end: 1.0),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.elasticOut,
                  builder: (_, v, child) => Transform.scale(scale: v, child: child),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _green.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _green.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: _green.withOpacity(0.2),
                          child: Text(
                            (foundUser!['displayName'] ?? '?')[0]
                                .toUpperCase(),
                            style: const TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: _green,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment.start,
                            children: [
                              Text(
                                  foundUser!['displayName'] ??
                                      '使用者',
                                  style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      color: _brown,
                                      fontWeight:
                                      FontWeight.bold,
                                      fontSize: 13)),
                              Text(
                                  foundUser!['email'] ?? '',
                                  style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      color: Colors.grey,
                                      fontSize: 11)),
                            ],
                          ),
                        ),
                        const Icon(Icons.check_circle_rounded,
                            color: _green, size: 18),
                      ],
                    ),
                  ), // close Container
                ), // close TweenAnimationBuilder
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消',
                    style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.grey,
                        fontWeight: FontWeight.bold))),
            ElevatedButton(
              onPressed: foundUser == null
                  ? null
                  : () async {
                // ✦ 修正：先把 Dialog 關掉
                Navigator.pop(ctx);

                final targetUid = foundUser!['uid'] ?? '';
                final targetName = foundUser!['displayName'] ?? '成員';
                final targetEmail = foundUser!['email'] ?? '';

                if (targetUid.isEmpty) return;

                // ✦ 修正：因為你在共享房間裡，需要確保這個共享房間的 ID 也回填到本地行程 Meta
                // 讓管理者返回首頁再進來時，也能一鍵維持「雲端多人實時 Dashboard」
                bool ok = false;
                try {
                  // 1. 發送邀請到雲端
                  ok = await SharedBudgetService.instance.sendInvite(
                    budgetId: budget.id,
                    budgetTitle: budget.title,
                    targetUid: targetUid,
                    targetEmail: targetEmail,
                  );

                  if (ok) {
                    // 2. 自動幫管理者本地的對應行程綁定這個房間的 sharedBudgetId 與多人模式標籤
                    final matchTripIdx = _trips.indexWhere((t) => t.sharedBudgetId == budget.id || t.itineraryId == budget.itineraryId);
                    if (matchTripIdx >= 0) {
                      setState(() {
                        _trips[matchTripIdx].sharedBudgetId = budget.id;
                        _trips[matchTripIdx].isMultiMode = true; // 強制設定為多人模式
                      });
                      // 寫入本地 SQLite，讓管理者重開 App 數據完全同軌
                      await _saveBudgetMeta(_trips[matchTripIdx]);
                    }

                    // 3. 同步更新雲端房間的成員 UID 清單，保障阿里郎加入時資料庫找得到他
                    await SharedBudgetService.instance.syncMemberUids(budget.id);
                  }
                } catch (e) {
                  debugPrint('⚠️ [Sync] 多人拉人同步失敗：$e');
                }

                if (mounted) {
                  // ✦ 保留你原本的所有 SnackBar 提示與字體風格，完全不刪除
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(
                            ok
                                ? '✉️ 邀請已發送給 $targetName！對方開啟 App 後即可看到邀請通知。'
                                : '⚠️ 邀請發送失敗，請稍後再試',
                            style: const TextStyle(
                                fontFamily: 'MyCustomFont')),
                        backgroundColor: ok ? _green : _brown),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: foundUser != null ? _green : Colors.grey,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: const Text('發送邀請',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜尋使用者輔助方法（避免重複邏輯）
  Future<void> _doUserSearch(
      String email,
      SharedBudget budget,
      StateSetter setInnerState,
      void Function(Map<String, String>?) onFound,
      void Function(String?) onError,
      void Function(bool) onLoading,
      ) async {
    if (email.isEmpty) {
      setInnerState(() {
        onError('請輸入 Email 地址');
        onLoading(false);
      });
      return;
    }
    final result =
    await SharedBudgetService.instance.findUserByEmail(email);
    setInnerState(() {
      onLoading(false);
      if (result == null) {
        onError('找不到此 Email 的使用者，請確認對方已使用此 Email 登入 App');
        onFound(null);
      } else if (result['uid'] ==
          FirebaseAuth.instance.currentUser?.uid) {
        onError('不能邀請自己');
        onFound(null);
      } else if (budget.members.any((m) => m.uid == result['uid'])) {
        onError('「${result['displayName']}」已是此房間的成員');
        onFound(null);
      } else {
        onError(null);
        onFound(result.map((k, v) => MapEntry(k, v)));
      }
    });
  }

  // ══════════════════════════════════════════════════════════
  //  修改預算 Dialog（共享）
  // ══════════════════════════════════════════════════════════

  void _showChangeBudgetDialog(SharedBudget budget) {
    final ctrl =
    TextEditingController(text: budget.totalBudget.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: Text('${budget.title}\n修改預算上限',
            style: const TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontSize: 16,
                fontWeight: FontWeight.w900)),
        content: _inputField(ctrl, '輸入新預算金額',
            prefixText: 'NT\$ ',
            keyboardType: TextInputType.number),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              final v = int.tryParse(ctrl.text);
              if (v != null) {
                await SharedBudgetService.instance
                    .updateTotalBudget(budget.id, v);
                await _loadData();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('儲存',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  離開 / 刪除 共享預算
  // ══════════════════════════════════════════════════════════

  Future<void> _leaveOrDelete(SharedBudget budget) async {
    final isOwner =
        budget.ownerUid ==
            FirebaseAuth.instance.currentUser?.uid;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text(isOwner ? '刪除共享預算？' : '離開共享預算？',
            style: const TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontWeight: FontWeight.w900)),
        content: Text(
            isOwner
                ? '刪除後所有消費紀錄都將消失，且成員無法再存取。'
                : '離開後你將無法看到此共享記帳的資料。',
            style: const TextStyle(
                fontFamily: 'MyCustomFont',
                color: Colors.grey)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(
                      color: Colors.grey,
                      fontFamily: 'MyCustomFont'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isOwner ? '確定刪除' : '確定離開',
                style: const TextStyle(
                    color: const Color(0xFFA5CBD4),
                    fontWeight: FontWeight.bold,
                    fontFamily: 'MyCustomFont')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    bool ok;
    if (isOwner) {
      ok = await SharedBudgetService.instance
          .deleteSharedBudget(budget.id);
    } else {
      ok = await SharedBudgetService.instance
          .leaveSharedBudget(budget.id);
    }

    if (ok) {
      // ★ 修正：立即從本地 _trips 和 saved_itineraries 清除對應骨架，
      //   防止 _sharedBudgets stream 更新後卡片「從 orphan 變成 bound trip 仍顯示」的殘影。
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final tripIdx = _trips.indexWhere((t) => t.sharedBudgetId == budget.id);
      if (tripIdx >= 0) {
        final tripId = _trips[tripIdx].itineraryId;
        // 如果是被邀請加入的骨架（title 與 shared budget 一致），直接刪除本地骨架
        await FirebaseSyncService.instance.deleteItinerary(tripId);
      }

      // [Fix-D] 立即從本地列表移除（不等 stream，防止 UI 快取殘留）
      setState(() {
        _sharedBudgets.removeWhere((b) => b.id == budget.id);
        if (tripIdx >= 0) _trips.removeAt(tripIdx);
        if (_selectedSharedId == budget.id) {
          _selectedSharedId = null;
          _watchingBudgetId = null;
          _watchingBudgetDetail = null;
          _recordsStream = null;
          _cachedRecords = []; // 清空快取
        }
      });
      _budgetDetailSub?.cancel();
      _budgetDetailSub = null;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  isOwner ? '已刪除共享預算' : '已離開共享預算',
                  style: const TextStyle(fontFamily: 'MyCustomFont')),
              backgroundColor: _brown),
        );
      }
      // ★ watchMySharedBudgets stream 會在背景自動同步，不需要手動 _loadData()
    }
  }

  // ══════════════════════════════════════════════════════════
  //  本地記帳部分（原邏輯保留不動）
  // ══════════════════════════════════════════════════════════

  // ★ 紀錄哪張卡片正在「顯示刪除按鈕」狀態（單選）
  int? _expandedDeleteIndex;

  // ★ 完整覆蓋整段 _buildTripCard 函數，解決首頁卡片外框支出顯示不同步的重大 Bug
  // ★ 完整覆蓋整段 _buildTripCard 函數，解決外面簡述支出 NT$ 0 與進度條不同步的重大 Bug！
  // ★ 完整覆蓋整段 _buildTripCard 函數，解決外面簡述支出 NT$ 0 與進度條不同步的重大 Bug！
  Widget _buildTripCard(int index) {
    final trip = _trips[index];
    final isDeleteExpanded = _expandedDeleteIndex == index;
    final bool isMultiActive = trip.isMultiMode && trip.sharedBudgetId != null && trip.sharedBudgetId!.isNotEmpty;

    final int soloSpent = trip.totalSpent;
    final int multiSpent = isMultiActive ? (_sharedSpentCache[trip.sharedBudgetId] ?? 0) : 0;
    final int spent = isMultiActive ? multiSpent : soloSpent;

    // ★ 問題3修正：多人模式預算顯示雲端 sharedBudget 的 totalBudget，而非本地 trip.budget
    final SharedBudget? linkedShared = isMultiActive
        ? _sharedBudgets.where((b) => b.id == trip.sharedBudgetId).firstOrNull
        : null;
    final int displayBudget = isMultiActive && linkedShared != null
        ? linkedShared.totalBudget
        : trip.budget;

    final ratio = displayBudget > 0 ? (spent / displayBudget).clamp(0.0, 1.0) : 0.0;
    final overBudget = spent > displayBudget && displayBudget > 0;
    final isHovered = _hoveredIndex == index;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = null),
      child: TweenAnimationBuilder<double>(
        key: ValueKey('card_enter_$index'),
        tween: Tween(begin: 0.0, end: 1.0),
        duration: Duration(milliseconds: 300 + index * 40),
        curve: Curves.easeOutCubic,
        builder: (_, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: child),
        ),
        child: GestureDetector(
          onLongPress: () => setState(() => _expandedDeleteIndex = isDeleteExpanded ? null : index),
          onTapDown: (_) => setState(() { _hoveredIndex = index; _pressedIndex = index; }),
          onTapCancel: () => setState(() { _hoveredIndex = null; _pressedIndex = null; }),
          onTapUp: (_) {
            setState(() { _pressedIndex = null; });
            Future.delayed(const Duration(milliseconds: 150), () { if (mounted) setState(() => _hoveredIndex = null); });
          },
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.0, end: (_pressedIndex == index) ? 0.93 : (_hoveredIndex == index ? 0.97 : 1.0)),
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeInOut,
            builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.only(bottom: 16),
              transform: Matrix4.identity(),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: overBudget ? const Color(0xFFA5CBD4).withOpacity(0.4) : _green.withOpacity(0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isHovered ? 0.08 : 0.03), // 🌟 劃過去陰影加深
                    blurRadius: isHovered ? 16 : 10,
                    offset: Offset(0, isHovered ? 6 : 2),
                  )
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 標題與模式標籤 ──
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: overBudget ? const Color(0xFFA5CBD4).withOpacity(0.08) : _green.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(trip.icon, color: overBudget ? const Color(0xFFA5CBD4) : _green, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(trip.name,
                                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.bold, color: _brown),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              if (overBudget)
                                const Text('⚠️ 超出預算上限', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: const Color(0xFFA5CBD4), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: isDeleteExpanded
                              ? Row(
                            key: const ValueKey('delete_row'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // ✕ 取消按鈕（再按一次收回）
                              GestureDetector(
                                onTap: () => setState(() => _expandedDeleteIndex = null),
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                                  child: const Icon(Icons.close_rounded, color: Colors.grey, size: 15),
                                ),
                              ),
                              // 刪除按鈕
                              GestureDetector(
                                onTap: () {
                                  setState(() => _expandedDeleteIndex = null);
                                  _deleteLocalTrip(index);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(color: const Color(0xFFA5CBD4), borderRadius: BorderRadius.circular(20)),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.delete_rounded, color: Colors.white, size: 14),
                                      SizedBox(width: 4),
                                      Text('刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          )
                              : GestureDetector(
                            key: const ValueKey('more_btn'),
                            onTap: () {
                              // 顯示設定 + 刪除選單
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (ctx) => Container(
                                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                                  decoration: BoxDecoration(
                                    color: _cream,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                                      const SizedBox(height: 14),
                                      Text(trip.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: _brown), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 14),
                                      // 設定按鈕
                                      // ── 單人設定 ──
                                      GestureDetector(
                                        onTap: () { Navigator.pop(ctx); _showLocalTripSettingsDialog(index); },
                                        child: Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(vertical: 13),
                                          decoration: BoxDecoration(color: _green.withOpacity(0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: _green.withOpacity(0.2))),
                                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            const Icon(Icons.person_rounded, size: 14, color: _green),
                                            const SizedBox(width: 6),
                                            Text(trip.isMultiMode ? '修改名稱 / 單人預算' : '修改名稱 / 預算',
                                                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: _green)),
                                          ]),
                                        ),
                                      ),
                                      // ── 多人預算設定（只有多人模式且有共享房間才顯示）──
                                      if (trip.isMultiMode && trip.sharedBudgetId != null && trip.sharedBudgetId!.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Builder(builder: (bctx) {
                                          final sharedBudget = _sharedBudgets.where((b) => b.id == trip.sharedBudgetId).firstOrNull;
                                          final isOwner = sharedBudget?.ownerUid == FirebaseAuth.instance.currentUser?.uid;
                                          if (!isOwner) return const SizedBox.shrink();
                                          return GestureDetector(
                                            onTap: () {
                                              Navigator.pop(ctx);
                                              if (sharedBudget != null) _showChangeBudgetDialog(sharedBudget);
                                            },
                                            child: Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.symmetric(vertical: 13),
                                              decoration: BoxDecoration(color: _brown.withOpacity(0.07), borderRadius: BorderRadius.circular(14), border: Border.all(color: _brown.withOpacity(0.2))),
                                              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                                Icon(Icons.group_rounded, size: 14, color: _brown),
                                                SizedBox(width: 6),
                                                Text('修改多人分帳預算', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: _brown)),
                                              ]),
                                            ),
                                          );
                                        }),
                                      ],
                                      const SizedBox(height: 6),
                                      // ── 刪除 ──
                                      GestureDetector(
                                        onTap: () { Navigator.pop(ctx); _deleteLocalTrip(index); },
                                        child: Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(vertical: 13),
                                          decoration: BoxDecoration(color: const Color(0xFFA5CBD4).withOpacity(0.10), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFA5CBD4).withOpacity(0.3))),
                                          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFFA5CBD4)),
                                            SizedBox(width: 8),
                                            Text('刪除此行程預算', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFA5CBD4))),
                                          ]),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(color: Colors.grey.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                              child: const Icon(Icons.more_horiz_rounded, color: Colors.grey, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // ── 實時連動進度條（含 80% 警示 + 超預算顏色）──
                    Stack(
                      children: [
                        Container(height: 10, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.12), borderRadius: BorderRadius.circular(8))),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: ratio.toDouble()),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutCubic,
                          builder: (_, animRatio, __) {
                            Color barStart, barEnd;
                            if (overBudget) {
                              barStart = const Color(0xFFA5CBD4).withOpacity(0.8);
                              barEnd   = const Color(0xFFA5CBD4);
                            } else if (ratio >= 0.8) {
                              barStart = const Color(0xFFBCAAA4).withOpacity(0.7); // 淡咖啡警示
                              barEnd   = const Color(0xFF9E8E83);
                            } else {
                              barStart = _green.withOpacity(0.7);
                              barEnd   = _green;
                            }
                            return FractionallySizedBox(
                              widthFactor: animRatio,
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  gradient: LinearGradient(colors: [barStart, barEnd]),
                                ),
                              ),
                            );
                          },
                        ),
                        if (spent > 0)
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text('${(ratio * 100).toInt()}%', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white.withOpacity(0.9))),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // ── 數據文字列：單人/多人各自獨立顯示（格式化數字）──
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 漂亮的金額卡片
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: overBudget ? const Color(0xFFA5CBD4).withOpacity(0.06) : _green.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: overBudget ? const Color(0xFFA5CBD4).withOpacity(0.2) : _green.withOpacity(0.12)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const Text('總預算', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('NT\$ ${_fmtNum(displayBudget)}',
                                    style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontSize: 14, fontWeight: FontWeight.w900)),
                              ]),
                              Container(width: 1, height: 32, color: Colors.grey.withOpacity(0.15)),
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                const Text('已花費', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('NT\$ ${_fmtNum(spent)}',
                                    style: TextStyle(fontFamily: 'MyCustomFont', color: overBudget ? const Color(0xFFA5CBD4) : _brown, fontSize: 14, fontWeight: FontWeight.w900)),
                              ]),
                              Container(width: 1, height: 32, color: Colors.grey.withOpacity(0.15)),
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(overBudget ? '超出' : '剩餘', style: TextStyle(fontFamily: 'MyCustomFont', color: overBudget ? const Color(0xFFA5CBD4) : _green, fontSize: 10, fontWeight: FontWeight.bold)),
                                Text('NT\$ ${_fmtNum((displayBudget - spent).abs())}',
                                    style: TextStyle(fontFamily: 'MyCustomFont', color: overBudget ? const Color(0xFFA5CBD4) : _green, fontSize: 14, fontWeight: FontWeight.w900)),
                              ]),
                            ],
                          ),
                        ),
                        // 若兩種模式都有紀錄，副行顯示另一模式的參考金額
                        if (isMultiActive && soloSpent > 0) ...[
                          const SizedBox(height: 3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _green.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '單人帳: NT\$ ${_fmtNum(soloSpent)}',
                                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: _green, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (!isMultiActive && multiSpent > 0) ...[
                          const SizedBox(height: 3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _brown.withOpacity(0.07),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '多人帳: NT\$ ${_fmtNum(multiSpent)}',
                                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: _brown, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 14),
                    // ★ 單人/多人 Segmented 切換按鈕（創立者和成員都可用）
                    Row(
                      children: [
                        // 單人模式按鈕
                        Expanded(
                          child: GestureDetector(
                            onTap: () async {
                              if (isDeleteExpanded) setState(() => _expandedDeleteIndex = null);
                              if (!trip.isMultiMode) {
                                // 已是單人，直接進入
                                _cleanupBudgetDetailSub();
                                setState(() => _selectedLocalItineraryId = trip.itineraryId);
                                return;
                              }
                              // 顯示統一模式選單（與多人按鈕一樣格式）
                              _showLocalModeDialog(index);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: !trip.isMultiMode ? _green : Colors.grey.withOpacity(0.08),
                                borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                                border: Border.all(color: !trip.isMultiMode ? _green : Colors.grey.withOpacity(0.2)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.person_rounded, size: 14, color: !trip.isMultiMode ? Colors.white : Colors.grey),
                                  const SizedBox(width: 5),
                                  Text('單人記帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: !trip.isMultiMode ? Colors.white : Colors.grey)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 多人模式按鈕
                        Expanded(
                          child: GestureDetector(
                            onTap: () async {
                              if (isDeleteExpanded) setState(() => _expandedDeleteIndex = null);
                              if (trip.isMultiMode) {
                                // 已是多人，直接進入 dashboard
                                // ★ 次要 Bug 修復：sharedBudgetId 可能因 race condition 尚未回填，
                                //   改用 itineraryId 再查一次作為 fallback，防止誤開模式選單
                                SharedBudget? sharedBudget = _sharedBudgets
                                    .where((b) => b.id == trip.sharedBudgetId)
                                    .firstOrNull;
                                sharedBudget ??= _sharedBudgets
                                    .where((b) => b.itineraryId == trip.itineraryId)
                                    .firstOrNull;
                                if (sharedBudget != null) { _selectSharedBudget(sharedBudget); return; }
                              }
                              // 顯示統一模式選單
                              _showLocalModeDialog(index);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: trip.isMultiMode ? _brown : Colors.grey.withOpacity(0.08),
                                borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
                                border: Border.all(color: trip.isMultiMode ? _brown : Colors.grey.withOpacity(0.2)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.group_rounded, size: 14, color: trip.isMultiMode ? Colors.white : Colors.grey),
                                  const SizedBox(width: 5),
                                  Text('多人分帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: trip.isMultiMode ? Colors.white : Colors.grey)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),   // ← GestureDetector 結束
      ),   // ← 入場 TweenAnimationBuilder 結束
    );
  }

  Widget _modeChip(bool isMulti) {
    return Container(
      padding:
      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (isMulti ? _brown : _green).withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: (isMulti ? _brown : _green).withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
              isMulti
                  ? Icons.group_rounded
                  : Icons.person_rounded,
              size: 12,
              color: isMulti ? _brown : _green),
          const SizedBox(width: 4),
          Text(isMulti ? '多人模式' : '單人模式',
              style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  fontSize: 11,
                  color: isMulti ? _brown : _green,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ★ 統一：切換模式底部彈出卡片（單人按或多人按都同一格式）
  Future<bool?> _showModeConfirmSheet({
    required String title,
    required String subtitle,
    required String confirmLabel,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        decoration: BoxDecoration(
          color: _cream,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, -4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 18),
            Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 8),
            Text(subtitle, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13, height: 1.5)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(ctx, false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.08),
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                        border: Border.all(color: Colors.grey.withOpacity(0.2)),
                      ),
                      child: const Center(child: Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey))),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(ctx, true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: _green,
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
                        border: Border.all(color: _green),
                      ),
                      child: Center(child: Text(confirmLabel, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white))),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ★ 多人模式切換：底部彈出卡片（類截圖樣式，橫排兩按鈕）
  void _showLocalModeDialog(int index) {
    final trip = _trips[index];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        decoration: BoxDecoration(
          color: _cream,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, -4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 拉桿 ──
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 18),
            // ── 標題 ──
            const Text('選擇記帳模式', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 6),
            const Text('單人模式資料存於本地，多人模式即時同步 Firebase，旅伴可共同記帳與分帳結算。',
                style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13, height: 1.5)),
            const SizedBox(height: 20),
            // ── 橫排兩按鈕（與截圖一致）──
            Row(
              children: [
                // 單人
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      Navigator.pop(ctx);
                      if (trip.isMultiMode) {
                        final ok = await _showModeConfirmSheet(
                          title: '切換到單人模式？',
                          subtitle: '切換後進入本地單人帳本，多人帳本資料仍保留在雲端。',
                          confirmLabel: '確定切換',
                        );
                        if (ok != true || !mounted) return;
                        // ★ Fix-Bug1：清除共享 stream 訂閱，防止 watchBudget 在切換後覆蓋狀態
                        _cleanupBudgetDetailSub();
                        setState(() {
                          _trips[index].isMultiMode = false;
                          _trips[index].sharedBudgetId = null;
                          _selectedLocalItineraryId = trip.itineraryId;
                        });
                        _saveBudgetMeta(_trips[index]);
                      } else {
                        setState(() => _selectedLocalItineraryId = trip.itineraryId);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: !trip.isMultiMode ? _green : Colors.grey.withOpacity(0.08),
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                        border: Border.all(color: !trip.isMultiMode ? _green : Colors.grey.withOpacity(0.2)),
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.person_rounded, size: 16, color: !trip.isMultiMode ? Colors.white : Colors.grey),
                        const SizedBox(width: 6),
                        Text('單人記帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: !trip.isMultiMode ? Colors.white : Colors.grey)),
                      ]),
                    ),
                  ),
                ),
                // 多人
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      Navigator.pop(ctx);
                      // 若已有 sharedBudgetId，直接進入
                      // ★ 同樣用 itineraryId 作為 fallback 防呆
                      if (trip.sharedBudgetId != null && trip.sharedBudgetId!.isNotEmpty) {
                        SharedBudget? sharedBudget = _sharedBudgets
                            .where((b) => b.id == trip.sharedBudgetId)
                            .firstOrNull;
                        sharedBudget ??= _sharedBudgets
                            .where((b) => b.itineraryId == trip.itineraryId)
                            .firstOrNull;
                        if (sharedBudget != null) { _selectSharedBudget(sharedBudget); return; }
                      } else {
                        // 就算 sharedBudgetId 是 null，也先查 itineraryId
                        final existingByItinerary = _sharedBudgets
                            .where((b) => b.itineraryId == trip.itineraryId)
                            .firstOrNull;
                        if (existingByItinerary != null) {
                          setState(() {
                            _trips[index].sharedBudgetId = existingByItinerary.id;
                            _trips[index].isMultiMode = true;
                          });
                          _saveBudgetMeta(_trips[index]);
                          _selectSharedBudget(existingByItinerary);
                          return;
                        }
                      }
                      // 建立新的共享房間
                      await _createSharedBudgetForTrip(index);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: trip.isMultiMode ? _brown : Colors.grey.withOpacity(0.08),
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
                        border: Border.all(color: trip.isMultiMode ? _brown : Colors.grey.withOpacity(0.2)),
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.group_rounded, size: 16, color: trip.isMultiMode ? Colors.white : Colors.grey),
                        const SizedBox(width: 6),
                        Text('多人分帳', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: trip.isMultiMode ? Colors.white : Colors.grey)),
                      ]),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }


  Widget _buildLocalDashboard(int index) {
    final trip = _trips[index];
    final spent = trip.totalSpent;
    final overBudget =
        spent > trip.budget && trip.budget > 0;
    final ratio = trip.budget > 0
        ? (spent / trip.budget).clamp(0.0, 1.0)
        : 0.0;
    final activeCats = trip.catTotals.entries
        .where((e) => e.value > 0)
        .toList();

    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── 第一行：返回 + 標題 ──
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _brown, size: 20),
                              padding: const EdgeInsets.all(8),
                              constraints: const BoxConstraints(),
                              onPressed: () => setState(() => _selectedLocalItineraryId = null),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(trip.name,
                                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 17, fontWeight: FontWeight.w900, color: _brown),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Row(children: [
                                    Icon(trip.isMultiMode ? Icons.group_rounded : Icons.person_rounded, size: 11, color: _brown),
                                    const SizedBox(width: 3),
                                    Text(trip.isMultiMode ? '多人分帳模式' : '單人記帳模式',
                                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
                                  ]),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // ── 第二行：單人/多人切換 + 設定 ──
                        Padding(
                          padding: const EdgeInsets.only(left: 12, right: 4, bottom: 6),
                          child: Row(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.07),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.withOpacity(0.15)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GestureDetector(
                                      onTap: () async {
                                        if (!trip.isMultiMode) return;
                                        final ok = await _showModeConfirmSheet(
                                          title: '切換到單人模式？',
                                          subtitle: '切換後進入本地單人帳本，多人帳本資料仍保留在雲端。',
                                          confirmLabel: '確定切換',
                                        );
                                        if (ok != true) return;
                                        setState(() { _trips[index].isMultiMode = false; _trips[index].sharedBudgetId = null; });
                                        _saveBudgetMeta(_trips[index]);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: !trip.isMultiMode ? _green : Colors.transparent,
                                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(11)),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.person_rounded, size: 12, color: !trip.isMultiMode ? Colors.white : Colors.grey),
                                          const SizedBox(width: 3),
                                          Text('單人', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: !trip.isMultiMode ? Colors.white : Colors.grey)),
                                        ]),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () {
                                        if (trip.isMultiMode) return;
                                        _showLocalModeDialog(index);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: trip.isMultiMode ? _brown : Colors.transparent,
                                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(11)),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.group_rounded, size: 12, color: trip.isMultiMode ? Colors.white : Colors.grey),
                                          const SizedBox(width: 3),
                                          Text('多人', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold, color: trip.isMultiMode ? Colors.white : Colors.grey)),
                                        ]),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              // 設定按鈕
                              GestureDetector(
                                onTap: () => _showLocalTripSettingsDialog(index),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _brown.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: _brown.withOpacity(0.25)),
                                  ),
                                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.tune_rounded, size: 14, color: _brown),
                                    SizedBox(width: 4),
                                    Text('設定', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
                                  ]),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 預算卡片
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 8),
                sliver: SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                          color: overBudget
                              ? const Color(0xFFA5CBD4)
                              .withOpacity(0.4)
                              : _green.withOpacity(0.5),
                          width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                Text('NT\$ $spent',
                                    style: TextStyle(
                                        fontFamily:
                                        'MyCustomFont',
                                        fontSize: 32,
                                        fontWeight:
                                        FontWeight.w900,
                                        color: overBudget
                                            ? const Color(0xFFA5CBD4)
                                            : _brown)),
                                Text(
                                    '預算上限 NT\$ ${trip.budget}',
                                    style: const TextStyle(
                                        fontFamily:
                                        'MyCustomFont',
                                        fontSize: 13,
                                        color: Colors.grey,
                                        fontWeight:
                                        FontWeight.bold)),
                              ],
                            ),
                            GestureDetector(
                              onTap: () => _changeBudgetDialog(index),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(mainAxisSize: MainAxisSize.min, children: [
                                    Text(
                                      'NT\$ ${trip.budget - spent}',
                                      style: TextStyle(fontFamily: 'MyCustomFont',
                                          color: overBudget ? const Color(0xFFA5CBD4) : _green,
                                          fontWeight: FontWeight.w900, fontSize: 18),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.edit_rounded, size: 12, color: _green),
                                  ]),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: (overBudget ? const Color(0xFFA5CBD4) : _green).withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(overBudget ? Icons.trending_up_rounded : Icons.savings_rounded,
                                          size: 11, color: overBudget ? const Color(0xFFA5CBD4) : _green),
                                      const SizedBox(width: 3),
                                      Text(overBudget ? '超支' : '可用',
                                          style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10,
                                              color: overBudget ? const Color(0xFFA5CBD4) : _green,
                                              fontWeight: FontWeight.bold)),
                                    ]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius:
                          BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: ratio.toDouble(),
                            backgroundColor:
                            Colors.grey.withOpacity(0.15),
                            valueColor:
                            AlwaysStoppedAnimation<Color>(
                                overBudget
                                    ? const Color(0xFFA5CBD4)
                                    : ratio >= 0.8
                                    ? const Color(0xFF9E8E83) // ★ 80% 深棕警示（配色統一）
                                    : _green),
                            minHeight: 10,
                          ),
                        ),
                        // ★ 80% 警示提示列
                        if (!overBudget && ratio >= 0.8)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, size: 13, color: Color(0xFF9E8E83)),
                                const SizedBox(width: 5),
                                Text(
                                  '已使用 ${(ratio * 100).toStringAsFixed(0)}%，即將接近預算上限！',
                                  style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      fontSize: 11,
                                      color: Color(0xFF9E8E83),
                                      fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

              // 多人模式：成員區
              if (trip.isMultiMode)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 8),
                  sliver: SliverToBoxAdapter(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius:
                          BorderRadius.circular(20)),
                      child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('同行成員',
                                  style: TextStyle(
                                      fontFamily:
                                      'MyCustomFont',
                                      fontSize: 13,
                                      fontWeight:
                                      FontWeight.w900,
                                      color: _brown)),
                              const Spacer(),
                              GestureDetector(
                                onTap: () =>
                                    _showAddLocalMemberDialog(
                                        index),
                                child: Container(
                                  padding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _green
                                        .withOpacity(0.1),
                                    borderRadius:
                                    BorderRadius.circular(
                                        12),
                                    border: Border.all(
                                        color: _green
                                            .withOpacity(0.3)),
                                  ),
                                  child: const Row(
                                    mainAxisSize:
                                    MainAxisSize.min,
                                    children: [
                                      Icon(
                                          Icons
                                              .person_add_outlined,
                                          size: 12,
                                          color: _green),
                                      SizedBox(width: 4),
                                      Text('加成員',
                                          style: TextStyle(
                                              fontFamily:
                                              'MyCustomFont',
                                              fontSize: 11,
                                              color: _green,
                                              fontWeight:
                                              FontWeight
                                                  .bold)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: trip.members.map((m) {
                                final paid = trip
                                    .memberPayments[m] ??
                                    0;
                                return GestureDetector(
                                  onLongPress: m != '自己'
                                      ? () =>
                                      _showRemoveMemberConfirm(
                                          index, m)
                                      : null,
                                  child: Container(
                                    margin: const EdgeInsets
                                        .only(right: 16),
                                    child: Column(
                                      children: [
                                        Stack(
                                          children: [
                                            CircleAvatar(
                                              radius: 22,
                                              backgroundColor:
                                              _cream,
                                              child: Text(
                                                m == '自己'
                                                    ? '我'
                                                    : m[0],
                                                style: const TextStyle(
                                                    fontFamily:
                                                    'MyCustomFont',
                                                    fontSize:
                                                    14,
                                                    color:
                                                    _brown,
                                                    fontWeight:
                                                    FontWeight
                                                        .bold),
                                              ),
                                            ),
                                            if (m != '自己')
                                              Positioned(
                                                right: 0,
                                                top: 0,
                                                child: Container(
                                                  width: 12,
                                                  height: 12,
                                                  decoration: const BoxDecoration(
                                                      color: Colors
                                                          .redAccent,
                                                      shape: BoxShape
                                                          .circle),
                                                  child:
                                                  const Icon(
                                                    Icons.close,
                                                    size: 8,
                                                    color: Colors
                                                        .white,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(m,
                                            style: const TextStyle(
                                                fontFamily:
                                                'MyCustomFont',
                                                fontSize: 11,
                                                color:
                                                Colors.grey,
                                                fontWeight:
                                                FontWeight
                                                    .bold)),
                                        Text('NT\$ $paid',
                                            style: const TextStyle(
                                                fontFamily:
                                                'MyCustomFont',
                                                fontSize: 12,
                                                color: _brown,
                                                fontWeight:
                                                FontWeight
                                                    .w900)),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 圓餅圖
              if (activeCats.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 8),
                  sliver: SliverToBoxAdapter(
                    child: _buildDonutCard(
                        activeCats, spent),
                  ),
                ),

              // 本地結算建議
              if (trip.isMultiMode &&
                  trip.settlementSuggestions.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 4),
                  sliver: SliverToBoxAdapter(
                    child: _buildLocalSettlementCard(trip),
                  ),
                ),

              // 消費紀錄
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    24, 16, 24, 120),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                        (ctx, idx) {
                      if (idx == 0) {
                        return Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            const Text('消費明細紀錄',
                                style: TextStyle(
                                    fontFamily:
                                    'MyCustomFont',
                                    fontSize: 16,
                                    fontWeight:
                                    FontWeight.w900,
                                    color: _brown)),
                            const SizedBox(height: 8),
                            Container(
                                height: 1.5,
                                color: _green.withOpacity(0.2),
                                margin: const EdgeInsets.only(
                                    bottom: 12)),
                            if (trip.records.isEmpty)
                              Container(
                                padding:
                                const EdgeInsets.symmetric(
                                    vertical: 32),
                                alignment: Alignment.center,
                                child: Column(
                                  children: [
                                    Icon(
                                        Icons
                                            .receipt_long_outlined,
                                        size: 42,
                                        color: Colors.grey
                                            .withOpacity(0.4)),
                                    const SizedBox(height: 8),
                                    const Text(
                                        '尚無消費紀錄，點擊右下角「+」新增',
                                        style: TextStyle(
                                            fontFamily:
                                            'MyCustomFont',
                                            color: Colors.grey,
                                            fontSize: 13)),
                                  ],
                                ),
                              ),
                          ],
                        );
                      }
                      final r = trip.records[idx - 1];
                      return _buildLocalRecordTile(
                          r, index, idx - 1);
                    },
                    childCount: trip.records.length + 1,
                  ),
                ),
              ),
            ],
          ),

          // FAB
          Positioned(
            bottom: 24,
            right: 24,
            child: GestureDetector(
              onTap: () => _openAddExpensePage(isMulti: false, localTripIdx: index),
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: _green,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: _green.withOpacity(0.4),
                        blurRadius: 15,
                        offset: const Offset(0, 6))
                  ],
                ),
                child: const Icon(Icons.add_rounded,
                    color: Colors.white, size: 36),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 圓餅圖元件（共用）────────────────────────────────────
  Widget _buildDonutCard(
      List<MapEntry<String, int>> activeCats, int spent) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10)
          ]),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            height: 110,
            child: Stack(
              children: [
                CustomPaint(
                  size: const Size(110, 110),
                  painter: _DonutChartPainter(
                      activeCategories: activeCats,
                      total: spent > 0 ? spent : 1),
                ),
                const Center(
                  child: Text('支出占比',
                      style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          color: _brown)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: activeCats.map((e) {
                final pct = spent > 0
                    ? (e.value / spent * 100).toInt()
                    : 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: _catColors[e.key] ??
                                Colors.grey,
                            shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(e.key,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: _brown)),
                      const Spacer(),
                      Text('$pct%',
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 11,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      Text('NT\$ ${e.value}',
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── 本地結算卡片 ─────────────────────────────────────────
  Widget _buildLocalSettlementCard(BudgetTrip trip) {
    final total = trip.totalSpent;
    final suggestions = trip.settlementSuggestions;
    // ★ 修正：有自訂參與人員時不能用全員數量平均，改顯示各人應付金額摘要
    final Map<String, int> shouldPay = {for (var m in trip.members) m: 0};
    for (final r in trip.records) {
      final participants = r.splitParticipants.isEmpty
          ? trip.members
          : r.splitParticipants.where((p) => trip.members.contains(p)).toList();
      if (participants.isEmpty) continue;
      final share = r.amount ~/ participants.length;
      final remainder = r.amount - share * participants.length;
      for (int i = 0; i < participants.length; i++) {
        shouldPay[participants[i]] = (shouldPay[participants[i]] ?? 0) + share + (i == 0 ? remainder : 0);
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _brown.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _brown.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_rounded,
                  color: _brown, size: 16),
              SizedBox(width: 6),
              Text('分帳結算建議',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: _brown)),
            ],
          ),
          const SizedBox(height: 8),
          Text('總消費 NT\$ $total',
              style: const TextStyle(
                  fontFamily: 'MyCustomFont',
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          // ★ 新增：各人應付金額一覽（依實際參與筆數計算）
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: shouldPay.entries.map((e) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _cream,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _brown.withOpacity(0.15)),
              ),
              child: Text('${e.key} 應付 NT\$ ${e.value}',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
            )).toList(),
          ),
          const SizedBox(height: 10),
          ...suggestions.map((s) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _green.withOpacity(0.3))),
            child: Row(
              children: [
                const Icon(Icons.arrow_forward_rounded,
                    size: 14, color: _green),
                const SizedBox(width: 8),
                Text('${s['from']} → ${s['to']}',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 13,
                        color: _brown,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('NT\$ ${s['amount']}',
                    style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 13,
                        color: _green,
                        fontWeight: FontWeight.w900)),
              ],
            ),
          )),
        ],
      ),
    );
  }

  // ── 本地消費紀錄列 ────────────────────────────────────────
  Widget _buildLocalRecordTile(
      BudgetRecord r, int tripIdx, int recIdx) {
    final color = _catColors[r.category] ?? Colors.grey;
    final icon =
        _catIcons[r.category] ?? Icons.receipt_long_rounded;

    return Dismissible(
      key: Key(
          '${r.title}_${r.createdAt.millisecondsSinceEpoch}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
            color: const Color(0xFFA5CBD4).withOpacity(0.15),
            borderRadius: BorderRadius.circular(20)),
        child:
        const Icon(Icons.delete_rounded, color: const Color(0xFFA5CBD4)),
      ),
      onDismissed: (_) async {
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        final tripId = _trips[tripIdx].itineraryId;
        // ★ 修正：同步刪除本地 DB 紀錄（先撈 ID，再刪）
        try {
          final dbRecords = await local_db_service.LocalDbService.instance
              .getBudgetRecords(tripId, userId: uid);
          // 按 title + amount + createdAt 匹配找到對應的 DB 紀錄 ID
          final match = dbRecords.where((db) =>
          db.title == r.title &&
              db.amount == r.amount &&
              db.createdAt.millisecondsSinceEpoch ==
                  r.createdAt.millisecondsSinceEpoch).firstOrNull;
          if (match != null) {
            await FirebaseSyncService.instance.deleteBudgetRecord(match.id);
          }
        } catch (e) {
          debugPrint('⚠️ [Budget] 本地消費紀錄刪除失敗：$e');
        }
        setState(() => _trips[tripIdx].records.removeAt(recIdx));
        _saveBudgetMeta(_trips[tripIdx]);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 3))
            ]),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title,
                      style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: _brown)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(r.category,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontSize: 11,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold)),
                      if (_trips[tripIdx].isMultiMode) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: _cream,
                              borderRadius:
                              BorderRadius.circular(6),
                              border: Border.all(
                                  color: _green
                                      .withOpacity(0.3))),
                          child: Text('付: ${r.payer}',
                              style: const TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  fontSize: 10,
                                  color: _brown,
                                  fontWeight:
                                  FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Text('-NT\$ ${r.amount}',
                style: const TextStyle(
                    fontFamily: 'MyCustomFont',
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: _brown)),
          ],
        ),
      ),
    );
  }

  // ── 本地：新增消費頁 ───────────────────────────────────────
  // 🌟 統一集中管理：無論單人多人，點開的都是同一個一模一樣的精緻視窗，但資料分開紀錄並全部同步雲端
  Future<void> _openAddExpensePage({required bool isMulti, int? localTripIdx, SharedBudget? sharedBudget}) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    String tripName = isMulti ? (sharedBudget?.title ?? '') : (_trips[localTripIdx!].name);
    List<String> members = isMulti ? (sharedBudget?.members.map((m) => m.displayName).toList() ?? ['自己']) : (_trips[localTripIdx!].members);

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          isMultiMode: isMulti,
          tripName: tripName,
          tripMembers: members,
        ),
      ),
    );

    if (result == null || !mounted) return;

    if (isMulti && sharedBudget != null) {
      // 【多人模式】消費紀錄 -> 寫入群組雲端 Firestore Room
      final memberMap = {for (final m in sharedBudget.members) m.displayName: m.uid};
      final payerName = result['payer'] as String;
      final payerUid = memberMap[payerName] ?? myUid;

      await SharedBudgetService.instance.addRecord(
        budgetId: sharedBudget.id, title: result['title'], category: result['category'],
        amount: result['amount'], payerUid: payerUid, payerName: payerName, note: result['note'] ?? '',
      );
    } else if (!isMulti && localTripIdx != null) {
      // 【單人模式】消費紀錄 -> 寫入本地 SQLite，並透過服務即時同步備份到雲端個人庫（互相隔離）
      final trip = _trips[localTripIdx];
      final now = DateTime.now();
      final newRecord = BudgetRecord(
        title: result['title'], category: result['category'], amount: result['amount'], payer: '自己', createdAt: now,
      );

      setState(() {
        trip.records.insert(0, newRecord);
      });

      // 透過雲端服務，上傳到個人隔離保存區，防丟失
      await FirebaseSyncService.instance.saveBudgetRecord(
        local_db_service.BudgetRecord(
          id: const Uuid().v4(), itineraryId: trip.itineraryId, userId: myUid,
          title: newRecord.title, category: newRecord.category, amount: newRecord.amount, payer: '自己', createdAt: now,
        ),
      );
      await _saveBudgetMeta(trip);
      // ★ Fix-Bug1：單人模式不呼叫 _loadData()，避免干擾 _selectedLocalItineraryId 狀態
      //   trip.records 已透過 setState insert(0, newRecord) 即時更新畫面
    }
    // ★ Fix-Bug2：多人模式同樣不呼叫 _loadData()，StreamBuilder watchRecords 自動推送新紀錄
    //   呼叫 _loadData() 會觸發 _isLoading=true，卸載 StreamBuilder，導致畫面瞬間歸零
  }

  // ── 本地：新增行程 Dialog ──────────────────────────────────
  void _showAddTripDialog() {
    final nameCtrl   = TextEditingController();
    final budgetCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: const Text('建立行程預算',
            style: TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _inputField(nameCtrl, '輸入行程名稱'),
            const SizedBox(height: 16),
            _inputField(budgetCtrl, '輸入總預算金額',
                prefixText: 'NT\$ ',
                keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty ||
                  budgetCtrl.text.isEmpty) return;
              final uid = FirebaseAuth.instance.currentUser
                  ?.uid ??
                  '';
              final id = await ItinerarySaveService.instance
                  .saveManualItinerary(
                title: nameCtrl.text,
                estimatedBudget:
                int.tryParse(budgetCtrl.text) ?? 0,
                startDate: DateTime.now(),
                endDate: DateTime.now(),
                plans: [],
                userId: uid,
              );
              setState(() {
                _trips.add(BudgetTrip(
                  itineraryId: id,
                  name: nameCtrl.text,
                  budget: int.tryParse(budgetCtrl.text) ?? 0,
                ));
              });
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('✨ 行程預算建立成功！',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              fontWeight: FontWeight.bold)),
                      backgroundColor: _green),
                );
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('確認建立',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── 本地：刪除行程 ─────────────────────────────────────────
  // ★ 核心修復：結合雲端主表打上墓碑標記，根除重登後死灰復燃問題
  void _deleteLocalTrip(int index) {
    final trip = _trips[index];
    final hasBudgetRecords = trip.totalSpent > 0;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(children: [
          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFA5CBD4).withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.delete_outline_rounded, color: Color(0xFFA5CBD4), size: 20)),
          const SizedBox(width: 10),
          const Text('刪除行程預算', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: _brown)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('確定要刪除「${trip.name}」的行程預算表嗎？', style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, height: 1.5)),
            const SizedBox(height: 8),
            const Text('刪除後雲端與跨裝置同步將徹底抹除，重登亦不再出現。', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey, height: 1.5)),
            if (hasBudgetRecords) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFA5CBD4).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFA5CBD4).withOpacity(0.3)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.account_balance_wallet_rounded, size: 16, color: Color(0xFFA5CBD4)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('此行程含有 NT\$ ${trip.totalSpent.toString().replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (m) => "${m[1]},")} 的消費紀錄，一併刪除嗎？', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7FA3B0), height: 1.5))),
                ]),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: Colors.grey, fontFamily: 'MyCustomFont'))),
          if (hasBudgetRecords)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _doDeleteTrip(index, deleteBudgetRecords: false);
              },
              child: const Text('只刪行程', style: TextStyle(color: _brown, fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
            ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _doDeleteTrip(index, deleteBudgetRecords: true);
            },
            child: Text(hasBudgetRecords ? '全部刪除' : '確定刪除',
                style: const TextStyle(color: Color(0xFFA5CBD4), fontWeight: FontWeight.bold, fontFamily: 'MyCustomFont')),
          ),
        ],
      ),
    );
  }

  Future<void> _doDeleteTrip(int index, {required bool deleteBudgetRecords}) async {
    final trip = _trips[index];
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // 1. 如果是多人共享房間，執行解散或主動退出房間
    if (trip.isMultiMode && trip.sharedBudgetId != null && trip.sharedBudgetId!.isNotEmpty) {
      try {
        final budgetDoc = await FirebaseFirestore.instance.collection('shared_budgets').doc(trip.sharedBudgetId).get();
        final isOwner = (budgetDoc.data()?['ownerUid'] ?? '') == uid;
        if (isOwner) {
          await SharedBudgetService.instance.deleteSharedBudget(trip.sharedBudgetId!);
        } else {
          await SharedBudgetService.instance.leaveSharedBudget(trip.sharedBudgetId!);
        }
      } catch (e) {
        debugPrint('⚠️ [Delete] 多人房間移除失敗：$e');
      }
    }

    // 2. 刪除預算紀錄（若選擇一併刪除）
    if (deleteBudgetRecords) {
      try {
        final records = await local_db_service.LocalDbService.instance
            .getBudgetRecords(trip.itineraryId, userId: uid);
        for (final r in records) {
          await FirebaseSyncService.instance.deleteBudgetRecord(r.id);
        }
      } catch (e) {
        debugPrint('⚠️ [Delete] 預算紀錄刪除失敗：$e');
      }
    }

    // 3. 刪除行程（本地 + 雲端墓碑）
    await FirebaseSyncService.instance.deleteItinerary(trip.itineraryId);

    // 4. 移除記憶體快取
    if (mounted) {
      setState(() {
        _trips.removeAt(index);
        _expandedDeleteIndex = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(deleteBudgetRecords ? '🗑️ 已刪除行程及所有消費紀錄' : '🗑️ 已刪除行程（消費紀錄保留）',
              style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: _brown,
        ),
      );
    }
  }


  // ══════════════════════════════════════════════════════════
  //  ★ 選擇性刪除行程（可複選）
  // ══════════════════════════════════════════════════════════
  Future<void> _showDeleteTripsDialog() async {
    if (_trips.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目前沒有行程可刪除', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _brown),
      );
      return;
    }

    final selectedIds = <String>{};
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          decoration: BoxDecoration(color: _cream, borderRadius: BorderRadius.circular(28)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拉桿
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.delete_sweep_rounded, color: _brown, size: 20),
                  const SizedBox(width: 8),
                  const Text('選擇要刪除的行程', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.w900, fontSize: 16)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setSheet(() => selectedIds.length == _trips.length ? selectedIds.clear() : selectedIds.addAll(_trips.map((t) => t.itineraryId))),
                    child: Text(selectedIds.length == _trips.length ? '取消全選' : '全選', style: const TextStyle(fontFamily: 'MyCustomFont', color: _green, fontWeight: FontWeight.bold)),
                  ),
                ]),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.45),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _trips.length,
                  itemBuilder: (_, i) {
                    final trip = _trips[i];
                    final selected = selectedIds.contains(trip.itineraryId);
                    return GestureDetector(
                      onTap: () => setSheet(() => selected ? selectedIds.remove(trip.itineraryId) : selectedIds.add(trip.itineraryId)),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: selected ? const Color(0xFFA5CBD4).withOpacity(0.12) : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: selected ? const Color(0xFFA5CBD4) : Colors.grey.withOpacity(0.2), width: selected ? 1.5 : 1),
                        ),
                        child: Row(children: [
                          Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                              color: selected ? const Color(0xFFA5CBD4) : Colors.grey, size: 20),
                          const SizedBox(width: 10),
                          Icon(trip.icon, size: 16, color: _brown.withOpacity(0.5)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(trip.name, style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: (trip.isMultiMode ? _brown : _green).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                            child: Text(trip.isMultiMode ? '多人' : '單人', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: trip.isMultiMode ? _brown : _green, fontWeight: FontWeight.bold)),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(color: Colors.grey.withOpacity(0.08), borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)), border: Border.all(color: Colors.grey.withOpacity(0.2))),
                        child: const Center(child: Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 14))),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: selectedIds.isEmpty ? null : () => Navigator.pop(ctx, true),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: selectedIds.isEmpty ? Colors.grey.withOpacity(0.15) : const Color(0xFFA5CBD4),
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
                        ),
                        child: Center(child: Text(
                          selectedIds.isEmpty ? '請選擇行程' : '刪除 ${selectedIds.length} 筆',
                          style: TextStyle(fontFamily: 'MyCustomFont', color: selectedIds.isEmpty ? Colors.grey : Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        )),
                      ),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );

    if (selectedIds.isEmpty || !mounted) return;

    // 執行刪除
    for (final itId in selectedIds.toList()) {
      final idx = _trips.indexWhere((t) => t.itineraryId == itId);
      if (idx < 0) continue;
      final trip = _trips[idx];
      // 多人房間先離開或解散
      if (trip.isMultiMode && trip.sharedBudgetId != null) {
        try {
          final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
          final budgetDoc = await FirebaseFirestore.instance.collection('shared_budgets').doc(trip.sharedBudgetId).get();
          final isOwner = (budgetDoc.data()?['ownerUid'] ?? '') == uid;
          if (isOwner) {
            await SharedBudgetService.instance.deleteSharedBudget(trip.sharedBudgetId!);
          } else {
            await SharedBudgetService.instance.leaveSharedBudget(trip.sharedBudgetId!);
          }
        } catch (_) {}
      }
      await FirebaseSyncService.instance.deleteItinerary(itId);
    }

    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🗑️ 已刪除 ${selectedIds.length} 筆行程', style: const TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: _brown),
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  //  ★ 首次同步：地圖新增行程後，預算頁第一次偵測到新行程提示使用者
  // ══════════════════════════════════════════════════════════

  Future<void> _checkFirstSyncNeeded() async {
    if (!mounted || _trips.isEmpty) return;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    // ★ 從 SharedPreferences 載入已提示過的行程 ID 集合（按 uid 隔離，重登自動 clear）
    final prefs = await SharedPreferences.getInstance();
    final prefsKey = 'budget_sync_prompted_$uid';
    final saved = prefs.getStringList(prefsKey) ?? [];
    _promptedSyncIds.addAll(saved);

    final List<BudgetTrip> newTrips = [];
    for (final trip in _trips) {
      if (_promptedSyncIds.contains(trip.itineraryId)) continue;
      try {
        final records = await local_db_service.LocalDbService.instance
            .getBudgetRecords(trip.itineraryId, userId: uid);
        final config = await local_db_service.LocalDbService.instance
            .getBudgetConfig(trip.itineraryId, userId: uid, defaultBudget: -1);
        final hasConfig = config.budgetLimit >= 0 && config.budgetLimit != -1;
        if (records.isEmpty && !hasConfig) {
          newTrips.add(trip);
        }
        // 標記為已提示（不管結果）
        _promptedSyncIds.add(trip.itineraryId);
      } catch (_) {
        _promptedSyncIds.add(trip.itineraryId);
      }
    }
    // 寫回 prefs（持久化，重登不再重問）
    await prefs.setStringList(prefsKey, _promptedSyncIds.toList());

    if (newTrips.isEmpty || !mounted) return;

    final trip = newTrips.first;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: _green.withOpacity(0.1), shape: BoxShape.circle),
              child: const Icon(Icons.sync_rounded, color: _green, size: 22),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('發現新行程！', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.w900, fontSize: 16)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _green.withOpacity(0.06), borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  const Icon(Icons.map_rounded, color: _green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(trip.name,
                        style: const TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontWeight: FontWeight.bold, fontSize: 14),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
                '是否要為這筆行程建立預算記帳本？\n\n建立後可以記錄消費、設定預算上限，也可以邀請旅伴一起多人分帳。資料會自動同步到 Firebase，不同帳號彼此隔離。',
                style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13, height: 1.5)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('以後再說', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _green, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: const Text('立即建立', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final idx = _trips.indexWhere((t) => t.itineraryId == trip.itineraryId);
      if (idx >= 0) {
        await _saveBudgetMeta(_trips[idx]);
        setState(() => _selectedLocalItineraryId = trip.itineraryId);
      }
    }

    if (mounted && newTrips.length > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkFirstSyncNeeded();
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  //  ★ 清除所有消費記錄（本地 + Firebase，保留行程骨架）
  // ══════════════════════════════════════════════════════════
  Future<void> _clearAllBudgetRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('清除所有消費記錄？', style: TextStyle(fontFamily: 'MyCustomFont', color: const Color(0xFFA5CBD4), fontWeight: FontWeight.w900)),
        content: const Text(
            '這將刪除本帳號所有行程的消費明細（同步至雲端 Firebase），但行程本身不會被刪除。\n\n此操作不可復原。',
            style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFA5CBD4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: const Text('確定清除', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    int deleted = 0;

    try {
      final db = await local_db_service.LocalDbService.instance.db;
      final rows = await db.query('budget_records',
          columns: ['id'], where: 'user_id = ?', whereArgs: [uid]);
      for (final row in rows) {
        final id = row['id'] as String;
        await local_db_service.LocalDbService.instance.deleteBudgetRecord(id);
        FirebaseSyncService.instance.deleteBudgetRecord(id).catchError((e) {
          debugPrint('⚠️ [ClearAll] Firebase record delete failed $id: $e');
        });
        deleted++;
      }

      if (mounted) {
        setState(() {
          for (final t in _trips) {
            t.records.clear();
          }
          _sharedSpentCache.clear();
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🗑️ 已清除 $deleted 筆消費記錄', style: const TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: _brown,
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ [ClearAll] 清除失敗：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ 清除失敗，請稍後再試', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFA5CBD4)),
        );
      }
    }
  }

  Future<void> _clearBudgetMeta(String itineraryId) async {
    final existing =
    await local_db_service.LocalDbService.instance.getItinerary(itineraryId);
    if (existing == null) return;
    dynamic originalPlans;
    try {
      final decoded = jsonDecode(existing.plansJson);
      originalPlans =
      decoded is Map && decoded.containsKey('_budget_meta')
          ? decoded['plans']
          : decoded;
    } catch (_) {
      originalPlans = [];
    }
    final updated = SavedItinerary(
      id: existing.id,
      userId: existing.userId,
      title: existing.title,
      estimatedBudget: existing.estimatedBudget,
      startDate: existing.startDate,
      endDate: existing.endDate,
      plansJson: jsonEncode(originalPlans),
      isFromAi: existing.isFromAi,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await FirebaseSyncService.instance.updateItinerary(updated);
  }

  // ── 修改預算（本地）────────────────────────────────────────
  void _changeBudgetDialog(int index) {
    final ctrl = TextEditingController(
        text: _trips[index].budget.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: Text(
            '${_trips[index].name}\n設定新預算上限',
            style: const TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontSize: 16,
                fontWeight: FontWeight.w900)),
        content: _inputField(ctrl, '輸入預算金額',
            prefixText: 'NT\$ ',
            keyboardType: TextInputType.number),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              final v = int.tryParse(ctrl.text);
              if (v != null) {
                setState(() => _trips[index].budget = v);
                await _saveBudgetMeta(_trips[index]);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('儲存修改',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── 本地：行程設定（修改名稱 + 修改預算）──────────────────────
  // ★ 為本地行程建立多人共享房間，並進入 Dashboard
  Future<void> _createSharedBudgetForTrip(int index) async {
    if (index < 0 || index >= _trips.length) return;
    final trip = _trips[index];

    // ── 防呆 1：若 trip 已記錄 sharedBudgetId，直接進入 ──
    if (trip.sharedBudgetId != null && trip.sharedBudgetId!.isNotEmpty) {
      final existing = _sharedBudgets.where((b) => b.id == trip.sharedBudgetId).firstOrNull;
      if (existing != null) { _selectSharedBudget(existing); return; }
    }

    // ── 防呆 2（核心修復）：即使 sharedBudgetId 尚未回填，
    //   也透過 itineraryId 在 _sharedBudgets 裡查找是否已有對應房間，
    //   防止 race condition 造成 sharedBudgetId 沒回填就誤建新空白房間 ──
    final existingByItinerary = _sharedBudgets
        .where((b) => b.itineraryId == trip.itineraryId)
        .firstOrNull;
    if (existingByItinerary != null) {
      // 補回填本地狀態，並直接進入（不建新房間）
      setState(() {
        _trips[index].sharedBudgetId = existingByItinerary.id;
        _trips[index].isMultiMode = true;
      });
      _saveBudgetMeta(_trips[index]);
      _selectSharedBudget(existingByItinerary);
      return;
    }

    // ── 防呆 3：再向 Firestore 查一次（_sharedBudgets stream 可能還沒推到）──
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty) {
        final snap = await FirebaseFirestore.instance
            .collection('shared_budgets')
            .where('itineraryId', isEqualTo: trip.itineraryId)
            .where('memberUids', arrayContains: uid)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          final remoteDoc = snap.docs.first;
          final remoteBudget = SharedBudget.fromDoc(remoteDoc);
          setState(() {
            _trips[index].sharedBudgetId = remoteBudget.id;
            _trips[index].isMultiMode = true;
          });
          _saveBudgetMeta(_trips[index]);
          _selectSharedBudget(remoteBudget);
          return;
        }
      }
    } catch (e) {
      debugPrint('⚠️ [createShared] Firestore 二次查找失敗（繼續建立新房間）：$e');
    }

    // 建立新的共享房間（帶入行程 ID 關聯）
    final newId = await SharedBudgetService.instance.createSharedBudget(
      title: trip.name,
      totalBudget: trip.budget,
      itineraryId: trip.itineraryId,
    );

    if (newId == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ 建立共享房間失敗，請稍後再試', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: const Color(0xFFA5CBD4)));
      return;
    }

    // 補寫 memberUids + 本地 meta
    await SharedBudgetService.instance.syncMemberUids(newId);
    setState(() {
      _trips[index].sharedBudgetId = newId;
      _trips[index].isMultiMode = true;
    });
    await _saveBudgetMeta(_trips[index]);
    // ★ Bug 1 修復：移除 await _loadData()——它會觸發 _isLoading=true 重建畫面，
    //   且此時 Firestore stream 可能尚未推送新 budget，造成 _sharedBudgets 找不到而無法進 Dashboard。
    //   改為直接從 Firestore 拉取剛建立的房間，stream 會在背景自動同步。

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✨ 多人分帳房間建立成功！可邀請旅伴加入', style: TextStyle(fontFamily: 'MyCustomFont')), backgroundColor: Color(0xFF8BAA88)));

    // 進入 Dashboard：先查本地快取，找不到就直接從 Firestore 拉取剛建立的房間
    SharedBudget? budget = _sharedBudgets.where((b) => b.id == newId).firstOrNull;
    if (budget == null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shared_budgets')
            .doc(newId)
            .get();
        if (doc.exists) budget = SharedBudget.fromDoc(doc);
      } catch (e) {
        debugPrint('⚠️ [createShared] 直接拉取新房間失敗：$e');
      }
    }
    if (budget != null && mounted) _selectSharedBudget(budget);
  }

  void _showLocalTripSettingsDialog(int index) {
    final trip = _trips[index];
    final nameCtrl = TextEditingController(text: trip.name);
    final budgetCtrl =
    TextEditingController(text: trip.budget.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.tune_rounded, color: _green, size: 22),
            SizedBox(width: 8),
            Text('行程設定',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.w900,
                    fontSize: 17)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('行程名稱',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _inputField(nameCtrl, '輸入行程名稱'),
            const SizedBox(height: 20),
            const Text('預算上限 (NT\$)',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _inputField(budgetCtrl, '輸入總預算金額',
                prefixText: 'NT\$ ',
                keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.grey,
                      fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              final newBudget = int.tryParse(budgetCtrl.text);
              if (newName.isEmpty) return;

              final nameChanged = newName != trip.name;
              final budgetChanged = newBudget != null && newBudget != trip.budget;

              if (!nameChanged && !budgetChanged) {
                if (ctx.mounted) Navigator.pop(ctx);
                return;
              }

              // 更新本地狀態
              if (nameChanged) setState(() => _trips[index].name = newName);
              if (budgetChanged) setState(() => _trips[index].budget = newBudget);

              // 同步到 Firebase：只需呼叫一次，同時更新名稱與預算
              final existing = await local_db_service.LocalDbService.instance
                  .getItinerary(trip.itineraryId);
              if (existing != null) {
                // 保留 _budget_meta
                dynamic originalPlans;
                try {
                  final decoded = jsonDecode(existing.plansJson);
                  originalPlans = decoded is Map && decoded.containsKey('_budget_meta')
                      ? decoded
                      : decoded;
                } catch (_) {
                  originalPlans = existing.plansJson;
                }

                // 重建 plansJson：若有 _budget_meta 需帶入新 budget
                String newPlansJson;
                try {
                  if (originalPlans is Map && originalPlans.containsKey('_budget_meta')) {
                    newPlansJson = jsonEncode({
                      'plans': originalPlans['plans'],
                      '_budget_meta': {
                        ...(originalPlans['_budget_meta'] as Map<String, dynamic>),
                      },
                    });
                  } else {
                    newPlansJson = existing.plansJson;
                  }
                } catch (_) {
                  newPlansJson = existing.plansJson;
                }

                final updated = SavedItinerary(
                  id: existing.id,
                  userId: existing.userId,
                  title: nameChanged ? newName : existing.title,
                  estimatedBudget: budgetChanged ? newBudget : existing.estimatedBudget,
                  startDate: existing.startDate,
                  endDate: existing.endDate,
                  plansJson: newPlansJson,
                  isFromAi: existing.isFromAi,
                  createdAt: existing.createdAt,
                  updatedAt: DateTime.now(),
                );
                await FirebaseSyncService.instance.updateItinerary(updated);
              }

              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('✅ 設定已儲存',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont')),
                      backgroundColor: _green),
                );
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('儲存設定',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── 本地：新增成員 ─────────────────────────────────────────
  // ★ 新增成員：搜尋 Firebase 使用者 + 發邀請等對方同意
  void _showAddLocalMemberDialog(int tripIndex) {
    final emailCtrl = TextEditingController();
    Map<String, String>? foundUser;
    String? errorMsg;
    bool isSearching = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: _cream,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.person_add_rounded,
                  color: _green, size: 22),
              SizedBox(width: 8),
              Text('邀請同行成員',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: _brown,
                      fontWeight: FontWeight.w900,
                      fontSize: 17)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '輸入對方的帳號 Email，系統將發送邀請通知。對方同意後才會正式加入。',
                    style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 12,
                        color: Colors.grey,
                        height: 1.5),
                  ),
                  const SizedBox(height: 16),

                  // ── Email 搜尋欄位 ──
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: _brown,
                              fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            hintText: '輸入 Email 地址',
                            hintStyle: TextStyle(
                                color: Colors.grey[400],
                                fontFamily: 'MyCustomFont'),
                            prefixIcon: const Icon(
                                Icons.email_outlined,
                                color: _green,
                                size: 18),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding:
                            const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                                borderRadius:
                                BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0))),
                            enabledBorder: OutlineInputBorder(
                                borderRadius:
                                BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: Color(0xFFE2E8F0))),
                            focusedBorder: OutlineInputBorder(
                                borderRadius:
                                BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                    color: _green, width: 1.5)),
                          ),
                          onSubmitted: (_) async {
                            setS(() {
                              isSearching = true;
                              foundUser = null;
                              errorMsg = null;
                            });
                            await _doLocalMemberSearch(
                              emailCtrl.text.trim(),
                              setS,
                                  (r) => foundUser = r,
                                  (e) => errorMsg = e,
                                  (s) => isSearching = s,
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: () async {
                            setS(() {
                              isSearching = true;
                              foundUser = null;
                              errorMsg = null;
                            });
                            await _doLocalMemberSearch(
                              emailCtrl.text.trim(),
                              setS,
                                  (r) => foundUser = r,
                                  (e) => errorMsg = e,
                                  (s) => isSearching = s,
                            );
                          },
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _green,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                  BorderRadius.circular(14))),
                          child: isSearching
                              ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2))
                              : const Text('搜尋',
                              style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),

                  // ── 錯誤訊息 ──
                  if (errorMsg != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: const Color(0xFFA5CBD4)
                                  .withOpacity(0.3))),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 14, color: const Color(0xFFA5CBD4)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(errorMsg!,
                                style: const TextStyle(
                                    fontFamily: 'MyCustomFont',
                                    color: const Color(0xFFA5CBD4),
                                    fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // ── 搜尋結果：找到使用者 ──
                  if (foundUser != null) ...[
                    const SizedBox(height: 12),
                    // ★ 問題4：搜尋到使用者時，卡片以動畫縮放效果顯示
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.88, end: 1.0),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.elasticOut,
                      builder: (_, v, child) => Transform.scale(scale: v, child: child),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _green.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: _green.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor:
                                  _green.withOpacity(0.2),
                                  child: Text(
                                    (foundUser!['displayName'] ??
                                        '?')[0]
                                        .toUpperCase(),
                                    style: const TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        color: _green,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          foundUser!['displayName'] ??
                                              '使用者',
                                          style: const TextStyle(
                                              fontFamily: 'MyCustomFont',
                                              color: _brown,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14)),
                                      Text(
                                          foundUser!['email'] ?? '',
                                          style: const TextStyle(
                                              fontFamily: 'MyCustomFont',
                                              color: Colors.grey,
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.check_circle_rounded,
                                    color: _green, size: 20),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                                color: _brown.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(10)),
                            child: const Row(
                              children: [
                                Icon(Icons.info_outline_rounded,
                                    size: 13, color: Colors.grey),
                                SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '邀請通知將發送給對方，對方同意後才會正式加入本行程的分帳。',
                                    style: TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        fontSize: 11,
                                        color: Colors.grey,
                                        height: 1.4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消',
                    style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.grey,
                        fontWeight: FontWeight.bold))),
            ElevatedButton(
              onPressed: foundUser == null
                  ? null
                  : () async {
                final targetUid =
                    foundUser!['uid'] ?? '';
                final targetName =
                    foundUser!['displayName'] ?? '成員';
                final targetEmail =
                    foundUser!['email'] ?? '';

                if (targetUid.isEmpty) return;

                final trip = _trips[tripIndex];

                // 建立 shared_budget 房間（若尚未建立）
                // 發邀請：寫入 users/{targetUid}/shared_budget_invites
                bool sent = false;
                if (trip.sharedBudgetId != null &&
                    trip.sharedBudgetId!.isNotEmpty) {
                  sent =
                  await SharedBudgetService.instance
                      .sendInvite(
                    budgetId: trip.sharedBudgetId!,
                    budgetTitle: trip.name,
                    targetUid: targetUid,
                    targetEmail: targetEmail,
                  );
                } else {
                  // 先建立 shared_budget 房間，再邀請
                  final newId =
                  await SharedBudgetService.instance
                      .createSharedBudget(
                    title: trip.name,
                    totalBudget: trip.budget,
                  );
                  if (newId != null) {
                    setState(() =>
                    _trips[tripIndex].sharedBudgetId =
                        newId);
                    await _saveBudgetMeta(
                        _trips[tripIndex]);
                    sent =
                    await SharedBudgetService.instance
                        .sendInvite(
                      budgetId: newId,
                      budgetTitle: trip.name,
                      targetUid: targetUid,
                      targetEmail: targetEmail,
                    );
                  }
                }

                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(
                    SnackBar(
                        content: Text(
                            sent
                                ? '📨 已發送邀請給 $targetName，等待對方同意'
                                : '⚠️ 邀請發送失敗，請稍後再試',
                            style: const TextStyle(
                                fontFamily: 'MyCustomFont')),
                        backgroundColor:
                        sent ? _green : _brown),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor:
                  foundUser != null ? _green : Colors.grey,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: const Text('發送邀請',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ★ 搜尋成員輔助（本地模式）
  Future<void> _doLocalMemberSearch(
      String email,
      StateSetter setS,
      void Function(Map<String, String>?) onFound,
      void Function(String?) onError,
      void Function(bool) onLoading,
      ) async {
    if (email.isEmpty) {
      setS(() {
        onError('請輸入 Email 地址');
        onLoading(false);
      });
      return;
    }
    final result =
    await SharedBudgetService.instance.findUserByEmail(email);
    setS(() {
      onLoading(false);
      if (result == null) {
        onError('找不到此 Email 的使用者，請確認對方已使用此 Email 登入 App');
        onFound(null);
      } else if (result['uid'] ==
          FirebaseAuth.instance.currentUser?.uid) {
        onError('不能邀請自己');
        onFound(null);
      } else {
        onError(null);
        onFound(result.map((k, v) => MapEntry(k, v)));
      }
    });
  }

  // ── 移除成員確認 ───────────────────────────────────────────
  void _showRemoveMemberConfirm(int tripIndex, String member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cream,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('移除成員「$member」？',
            style: const TextStyle(
                fontFamily: 'MyCustomFont',
                color: _brown,
                fontWeight: FontWeight.w900)),
        content: const Text('該成員的付款紀錄將歸屬於「自己」。',
            style: TextStyle(
                fontFamily: 'MyCustomFont',
                color: Colors.grey)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      color: Colors.grey,
                      fontFamily: 'MyCustomFont'))),
          TextButton(
            onPressed: () {
              setState(() {
                _trips[tripIndex].members.remove(member);
                for (var r in _trips[tripIndex].records) {
                  if (r.payer == member) r.payer = '自己';
                }
              });
              _saveBudgetMeta(_trips[tripIndex]);
              Navigator.pop(ctx);
            },
            child: const Text('確定移除',
                style: TextStyle(
                    color: const Color(0xFFA5CBD4),
                    fontWeight: FontWeight.bold,
                    fontFamily: 'MyCustomFont')),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  共用 UI 元件
  // ──────────────────────────────────────────────────────────

  Widget _buildTopHeader(
      String title,
      String subtitle, {
        Widget? trailing,
      }) {
    // 拆分 title → "MY " + "BUDGET" 雙色（與 community 風格一致）
    final parts = title.split(' ');
    final firstWord = parts.isNotEmpty ? '${parts[0]} ' : title;
    final restWords = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
        color: _cream,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 第一行：漢堡 + 大標題 + 右側按鈕群 ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  icon: const Icon(Icons.menu_rounded, size: 30, color: _brown),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 12),
                // 大標題：Expanded 讓它佔滿中間剩餘空間
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5),
                      children: [
                        TextSpan(text: firstWord, style: const TextStyle(color: _brown)),
                        if (restWords.isNotEmpty)
                          TextSpan(text: restWords, style: const TextStyle(color: _green)),
                      ],
                    ),
                  ),
                ),
                // 右側按鈕群：緊貼標題右端，與標題垂直置中
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 6),
            // ── 第二行：副標籤膠囊 ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _green.withOpacity(0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _green.withOpacity(0.35), width: 1.2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_balance_wallet_rounded, size: 13, color: _green),
                  const SizedBox(width: 6),
                  Text(subtitle,
                      style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 12,
                          color: _brown,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextField _inputField(
      TextEditingController ctrl,
      String hint, {
        String? prefixText,
        TextInputType keyboardType = TextInputType.text,
      }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: const TextStyle(
          fontFamily: 'MyCustomFont',
          color: _brown,
          fontWeight: FontWeight.bold),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: Colors.grey[400], fontFamily: 'MyCustomFont'),
        prefixText: prefixText,
        prefixStyle: const TextStyle(
            color: _green, fontWeight: FontWeight.bold),
        focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _green, width: 2)),
        enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFFE2E8F0))),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  TabBar Delegate（讓 TabBar 在 NestedScrollView 中 pin）
// ══════════════════════════════════════════════════════════════
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  const _TabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: const Color(0xFFFDFCF5),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) => false;
}

// ══════════════════════════════════════════════════════════════
//  漢堡選單 Drawer（從 Firestore 讀取 app 帳號頭貼＋真實跳頁）
// ══════════════════════════════════════════════════════════════
class _HomeStyleDrawer extends StatefulWidget {
  const _HomeStyleDrawer();

  @override
  State<_HomeStyleDrawer> createState() => _HomeStyleDrawerState();
}

class _HomeStyleDrawerState extends State<_HomeStyleDrawer> {
  static const _green = Color(0xFF8BAA88);
  static const _brown = Color(0xFF7D6E5D);

  Uint8List? _avatarBytes;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1. 先從 SharedPreferences 快取讀（與 profile_screen 同一個 key）
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'avatar_cache_${user.uid}';
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.length > 100) {
      final clean = cached.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
      if (mounted) setState(() => _avatarBytes = base64Decode(clean));
    }

    // 2. 再從 Firestore 同步最新（用與 profile_screen 完全一樣的 query）
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('uid', isEqualTo: user.uid)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty && mounted) {
        final data = snap.docs.first.data();
        if (data.containsKey('avatarBase64') && data['avatarBase64'] != null) {
          final base64String = data['avatarBase64'].toString();
          if (base64String.length > 100) {
            final clean = base64String.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
            final bytes = base64Decode(clean);
            // 同步更新快取
            await prefs.setString(cacheKey, base64String);
            if (mounted) setState(() => _avatarBytes = bytes);
          }
        }
      }
    } catch (_) {}
  }

  void _navigateTo(int tabIndex) {
    Navigator.pop(context);
    AppStateManager.currentTabNotifier.value = tabIndex;
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

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isGuest = user == null;
    final name = user?.displayName ?? '旅遊探險家';
    final email = user?.email ?? '訪客模式';

    return Drawer(
      backgroundColor: const Color(0xFFF9F8F4),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────
          _SharedDrawerHeader(user: user, displayName: name, email: email),

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
                    onTap: () => _navigateTo(6)),
                _DItem(icon: Icons.favorite_rounded, label: '我的收藏', color: const Color(0xFFE8A0A0),
                    onTap: () => _navigateTo(3)),
                _DItem(icon: Icons.auto_stories_rounded, label: '我的發布紀錄', color: const Color(0xFF7FA3B0),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => UserLogsPage(posts: const [], onRefresh: () async {})));
                    }),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 16, 24, 6),
                  child: Text('設定', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFFB0A898), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                _DItem(icon: Icons.settings_rounded, label: '系統設定', color: const Color(0xFF9E9182),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SystemSettingsScreen()));
                    }),
                _DItem(icon: Icons.help_rounded, label: '幫助與支援', color: const Color(0xFFB09070),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpSupportScreen()));
                    }),
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
}

// ── Drawer 列表項目（與 HomeScreen _DItem 設計完全一致）──
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

// ══════════════════════════════════════════════════════════════
//  圓餅圖 CustomPainter（保持不動）
// ══════════════════════════════════════════════════════════════
class _DonutChartPainter extends CustomPainter {
  final List<MapEntry<String, int>> activeCategories;
  final int total;

  static const Map<String, Color> _catColors = {
    '美食': Color(0xFF7D6E5D),
    '住宿': Color(0xFF8BAA88),
    '交通': Color(0xFFBCAAA4),
    '購物': Color(0xFFA0A0A0),
    '其他': Color(0xFFCCCCCC),
  };

  _DonutChartPainter(
      {required this.activeCategories, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    const strokeW = 16.0;
    final rect = Rect.fromLTWH(strokeW / 2, strokeW / 2,
        size.width - strokeW, size.height - strokeW);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;

    if (total == 0 || activeCategories.isEmpty) {
      paint.color = Colors.grey.withOpacity(0.15);
      canvas.drawArc(rect, 0, 2 * pi, false, paint);
      return;
    }

    double startAngle = -pi / 2;
    for (var cat in activeCategories) {
      double sweepAngle = (cat.value / total) * 2 * pi;
      paint.color = _catColors[cat.key] ?? Colors.grey;
      canvas.drawArc(
          rect, startAngle, sweepAngle - 0.04, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => true;
}

// ══════════════════════════════════════════════════════════════
//  AddExpenseScreen（新增消費頁，保持不動）
// ══════════════════════════════════════════════════════════════
class AddExpenseScreen extends StatefulWidget {
  final bool isMultiMode;
  final List<String> tripMembers;
  final String tripName;

  const AddExpenseScreen({
    super.key,
    required this.isMultiMode,
    required this.tripMembers,
    required this.tripName,
  });

  @override
  State<AddExpenseScreen> createState() =>
      _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey =
  GlobalKey<ScaffoldState>();
  final _nameCtrl   = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _noteCtrl   = TextEditingController();

  String _selectedCat = '美食';
  late String _selectedPayer;
  // ★ 新增：參與分攤的人（預設全選）
  late List<String> _splitParticipants;

  static const _green = Color(0xFF8BAA88);
  static const _brown = Color(0xFF7D6E5D);
  static const _cream = Color(0xFFFDFCF5);

  final List<String> _cats = ['美食', '住宿', '交通', '購物', '其他'];
  static const Map<String, IconData> _catIcons = {
    '美食': Icons.restaurant_rounded,
    '住宿': Icons.hotel_rounded,
    '交通': Icons.directions_transit_rounded,
    '購物': Icons.shopping_bag_rounded,
    '其他': Icons.receipt_long_rounded,
  };

  @override
  void initState() {
    super.initState();
    _selectedPayer = widget.tripMembers.isNotEmpty
        ? widget.tripMembers[0]
        : '自己';
    // ★ 新增：預設全員都參與分攤
    _splitParticipants = List<String>.from(widget.tripMembers);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_nameCtrl.text.trim().isEmpty ||
        _amountCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('請填入完整的消費名稱與花費金額喔！',
                style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: _brown),
      );
      return;
    }
    final amt = int.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('金額必須大於 0 喔！',
                style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: _brown),
      );
      return;
    }
    Navigator.pop(context, {
      'title': _nameCtrl.text.trim(),
      'category': _selectedCat,
      'amount': amt,
      'payer': widget.isMultiMode ? _selectedPayer : '自己',
      'note': _noteCtrl.text.trim(),
      // ★ 新增：傳回參與分攤人員（空代表全員）
      'splitParticipants': widget.isMultiMode ? _splitParticipants : <String>[],
    });
  }

  void _showPicker(
      {required String title,
        required List<String> items,
        required String current,
        required ValueChanged<String> onSelect}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cream,
      shape: const RoundedRectangleBorder(
          borderRadius:
          BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: _brown)),
              const SizedBox(height: 16),
              ...items.map((e) => ListTile(
                leading: _catIcons.containsKey(e)
                    ? Icon(_catIcons[e],
                    color: e == current
                        ? _green
                        : Colors.grey,
                    size: 20)
                    : null,
                title: Text(e,
                    style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        fontSize: 15,
                        fontWeight: e == current
                            ? FontWeight.w900
                            : FontWeight.bold,
                        color: e == current
                            ? _green
                            : _brown)),
                trailing: e == current
                    ? const Icon(
                    Icons.check_circle_rounded,
                    color: _green)
                    : null,
                onTap: () {
                  onSelect(e);
                  Navigator.pop(ctx);
                },
              )),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: _brown, size: 22),
            onPressed: () => Navigator.pop(context)),
        title: Column(
          children: [
            const Text('新增消費紀錄',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.w900,
                    fontSize: 17)),
            Text(widget.tripName,
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown.withOpacity(0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('支出類別',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 12),
            Row(
              children: _cats.map((cat) {
                final selected = _selectedCat == cat;
                return Expanded(
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _selectedCat = cat),
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                          vertical: 10),
                      decoration: BoxDecoration(
                        color: selected
                            ? _green.withOpacity(0.15)
                            : Colors.white,
                        borderRadius:
                        BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? _green
                              : const Color(0xFFE2E8F0),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(_catIcons[cat],
                              size: 20,
                              color: selected
                                  ? _green
                                  : Colors.grey),
                          const SizedBox(height: 4),
                          Text(cat,
                              style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  fontSize: 11,
                                  color: selected
                                      ? _green
                                      : Colors.grey,
                                  fontWeight:
                                  FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            const Text('消費項目名稱',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 8),
            _styledTextField(_nameCtrl, '輸入消費明細…'),
            const SizedBox(height: 20),
            const Text('花費金額 (NT\$)',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 8),
            _styledTextField(_amountCtrl, '0',
                prefixText: 'NT\$ ',
                keyboardType: TextInputType.number,
                fontSize: 24,
                fontWeight: FontWeight.w900),
            if (widget.isMultiMode) ...[
              const SizedBox(height: 20),
              const Text('實際付款人',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      color: _brown,
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _showPicker(
                  title: '請選擇付款人',
                  items: widget.tripMembers,
                  current: _selectedPayer,
                  onSelect: (v) =>
                      setState(() => _selectedPayer = v),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                          radius: 12,
                          backgroundColor:
                          Color(0xFFFDFCF5),
                          child: Text('👤',
                              style:
                              TextStyle(fontSize: 12))),
                      const SizedBox(width: 12),
                      Text(_selectedPayer,
                          style: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: _brown,
                              fontWeight: FontWeight.bold)),
                      const Spacer(),
                      const Icon(Icons.expand_more_rounded,
                          color: _green),
                    ],
                  ),
                ),
              ),
              // ★ 新增：參與分攤區塊
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('參與分攤的人',
                      style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: _brown,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  GestureDetector(
                    onTap: () => setState(() {
                      if (_splitParticipants.length == widget.tripMembers.length) {
                        // 全選 → 只保留付款人
                        _splitParticipants = [_selectedPayer];
                      } else {
                        // 非全選 → 全選
                        _splitParticipants = List<String>.from(widget.tripMembers);
                      }
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _green.withOpacity(0.3)),
                      ),
                      child: Text(
                        _splitParticipants.length == widget.tripMembers.length ? '取消全選' : '全選',
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _green, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.tripMembers.map((m) {
                  final selected = _splitParticipants.contains(m);
                  return GestureDetector(
                    onTap: () => setState(() {
                      if (selected) {
                        // 至少保留一人
                        if (_splitParticipants.length > 1) {
                          _splitParticipants.remove(m);
                        }
                      } else {
                        _splitParticipants.add(m);
                      }
                    }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? _green.withOpacity(0.12) : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? _green : const Color(0xFFE2E8F0),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                            size: 14,
                            color: selected ? _green : Colors.grey[400],
                          ),
                          const SizedBox(width: 6),
                          Text(m, style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 13,
                            color: selected ? _green : Colors.grey[600],
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          )),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              // 分攤說明小字
              if (_splitParticipants.length < widget.tripMembers.length) ...[
                const SizedBox(height: 8),
                Text(
                  '此筆費用由 ${_splitParticipants.join('、')} 分攤',
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green.withOpacity(0.8), fontWeight: FontWeight.bold),
                ),
              ],
            ],
            const SizedBox(height: 20),
            const Text('備註（選填）',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: _brown,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 8),
            _styledTextField(_noteCtrl, '輸入備註資訊…',
                maxLines: 2),
            const SizedBox(height: 36),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    shape: RoundedRectangleBorder(
                        borderRadius:
                        BorderRadius.circular(28))),
                child: const Text('確認新增此筆支出',
                    style: TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _styledTextField(
      TextEditingController ctrl,
      String hint, {
        String? prefixText,
        TextInputType keyboardType = TextInputType.text,
        double fontSize = 16,
        FontWeight fontWeight = FontWeight.bold,
        int maxLines = 1,
      }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: TextStyle(
          fontFamily: 'MyCustomFont',
          color: _brown,
          fontSize: fontSize,
          fontWeight: fontWeight),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontFamily: 'MyCustomFont',
            color: Colors.grey[400]),
        prefixText: prefixText,
        prefixStyle: const TextStyle(
            color: _brown,
            fontSize: 18,
            fontWeight: FontWeight.bold),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
            const BorderSide(color: Color(0xFFE2E8F0))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
            const BorderSide(color: Color(0xFFE2E8F0))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
            const BorderSide(color: _green, width: 1.5)),
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
              fontWeight: FontWeight.w900, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          if (!isGuest) Text(widget.email, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
              color: Colors.white.withOpacity(0.82)), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          if (!isGuest)
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.22), borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.45))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_rounded, size: 12, color: Colors.white),
                  SizedBox(width: 4),
                  Text('已登入', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Colors.white, fontWeight: FontWeight.bold)),
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