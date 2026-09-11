import 'dart:convert';
import 'dart:ui';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'map_screen.dart' show ItineraryDetailScreen, TripPlan, DailyItinerary, ItineraryItem, TransportType;
import 'local_db_service.dart';
import 'news_screen.dart' show NewsDetailScreen, ActivityItem;

// ── CalendarEvent 相關類別（內嵌，不需外部 calendar_event_service.dart）──
enum CalendarEventType { officialEvent, itinerary }

// ─── 月曆事件模型 ────────────────────────────────────────────
class CalendarEvent {
  final String id;
  final CalendarEventType type;
  final String title;
  final String date;      // yyyy-MM-dd  (行程 = 開始日)
  final String endDate;   // yyyy-MM-dd  (可為空字串)
  final String time;
  final String location;
  final String desc;
  final String image;
  final List<String> tags;
  final String? itineraryId;
  final String? newsActivityId; // ★ 連結回 NewsDetailScreen 的活動 id
  final String note;            // ★ 個人筆記
  final DateTime createdAt;

  const CalendarEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.date,
    this.endDate = '',
    required this.time,
    required this.location,
    required this.desc,
    required this.image,
    required this.tags,
    this.itineraryId,
    this.newsActivityId,
    this.note = '',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'title': title,
    'date': date,
    'end_date': endDate,
    'time': time,
    'location': location,
    'desc': desc,
    'image': image,
    'tags': tags,
    'itinerary_id': itineraryId,
    'news_activity_id': newsActivityId,
    'note': note,
    'created_at': createdAt.toIso8601String(),
  };

  factory CalendarEvent.fromMap(Map<String, dynamic> m) => CalendarEvent(
    id: m['id']?.toString() ?? const Uuid().v4(),
    type: m['type'] == 'itinerary'
        ? CalendarEventType.itinerary
        : CalendarEventType.officialEvent,
    title: m['title']?.toString() ?? '',
    date: m['date']?.toString() ?? '',
    endDate: m['end_date']?.toString() ?? '',
    time: m['time']?.toString() ?? '',
    location: m['location']?.toString() ?? '',
    desc: m['desc']?.toString() ?? '',
    image: m['image']?.toString() ?? '',
    tags: List<String>.from(m['tags'] ?? []),
    itineraryId: m['itinerary_id']?.toString(),
    newsActivityId: m['news_activity_id']?.toString(),
    note: m['note']?.toString() ?? '',
    createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
  );
}

// ─── App 通知模型（與 budget 邀請同層級） ────────────────────
class AppNotification {
  final String id;
  final String type;       // 'event_share'
  final String title;
  final String body;
  final String senderName;
  final String senderUid;
  final Map<String, dynamic> payload; // CalendarEvent.toMap()
  final bool isRead;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.senderName,
    required this.senderUid,
    required this.payload,
    required this.isRead,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type,
    'title': title,
    'body': body,
    'senderName': senderName,
    'senderUid': senderUid,
    'payload': payload,
    'isRead': isRead,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AppNotification.fromMap(Map<String, dynamic> m) => AppNotification(
    id: m['id']?.toString() ?? '',
    type: m['type']?.toString() ?? 'event_share',
    title: m['title']?.toString() ?? '',
    body: m['body']?.toString() ?? '',
    senderName: m['senderName']?.toString() ?? '',
    senderUid: m['senderUid']?.toString() ?? '',
    payload: Map<String, dynamic>.from(m['payload'] ?? {}),
    isRead: m['isRead'] == true,
    createdAt: DateTime.tryParse(m['createdAt']?.toString() ?? '') ?? DateTime.now(),
  );

  /// 從通知 payload 還原 CalendarEvent（home_screen 相容用）
  CalendarEvent toEventModel() =>
      CalendarEvent.fromMap({...payload, 'id': const Uuid().v4()});
}

// ─── 服務主體 ────────────────────────────────────────────────
class CalendarEventService {
  static CalendarEventService? _instance;
  static CalendarEventService get instance =>
      _instance ??= CalendarEventService._();
  CalendarEventService._();

  final _db = FirebaseFirestore.instance;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String get _name => FirebaseAuth.instance.currentUser?.displayName ?? '使用者';

  CollectionReference _eventsOf(String uid) =>
      _db.collection('users').doc(uid).collection('calendar_events');

  CollectionReference _notifsOf(String uid) =>
      _db.collection('users').doc(uid).collection('app_notifications');

  // ── 1. 加入活動提醒 ─────────────────────────────────────────
  /// 回傳 true = 成功新增；false = 已存在
  Future<bool> addEventReminder(CalendarEvent event) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final dup = await _eventsOf(uid)
          .where('title', isEqualTo: event.title)
          .where('date',  isEqualTo: event.date)
          .limit(1).get();
      if (dup.docs.isNotEmpty) return false;

      final newId = const Uuid().v4();
      final newEvent = CalendarEvent(
        id: newId,
        type: event.type,
        title: event.title,
        date: event.date,
        endDate: event.endDate,
        time: event.time,
        location: event.location,
        desc: event.desc,
        image: event.image,
        tags: event.tags,
        itineraryId: event.itineraryId,
        newsActivityId: event.newsActivityId,
        createdAt: DateTime.now(),
      );
      await _eventsOf(uid).doc(newId).set(newEvent.toMap());

      // ★ 同時寫一筆自己的 app_notifications，讓首頁鈴鐺顯示紅點
      final notif = AppNotification(
        id: const Uuid().v4(),
        type: 'event_reminder',
        title: '📅 已加入月曆：${event.title}',
        body: event.endDate.isNotEmpty
            ? '${event.date} ~ ${event.endDate}'
            : event.date.isNotEmpty ? event.date : '即將到來',
        senderName: _name,
        senderUid: uid,
        payload: newEvent.toMap(),
        isRead: false,
        createdAt: DateTime.now(),
      );
      await _notifsOf(uid).doc(notif.id).set(notif.toMap());
      return true;
    } catch (e) {
      debugPrint('⚠️ [CalendarEvent] addEventReminder: $e');
      return false;
    }
  }

  // ── 2. 加入行程到月曆 ────────────────────────────────────────
  Future<bool> addItineraryToCalendar({
    required String itineraryId,
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    required int budget,
  }) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final dup = await _eventsOf(uid)
          .where('itinerary_id', isEqualTo: itineraryId)
          .limit(1).get();
      if (dup.docs.isNotEmpty) return false;

      String fmt(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      final days = endDate.difference(startDate).inDays + 1;
      final newId = const Uuid().v4();

      final event = CalendarEvent(
        id: newId,
        type: CalendarEventType.itinerary,
        title: title,
        date: fmt(startDate),
        endDate: fmt(endDate),
        time: '全天',
        location: '我的行程',
        desc: '$days 天行程・預算 NT\$ $budget',
        image: '',
        tags: ['我的行程'],
        itineraryId: itineraryId,
        createdAt: DateTime.now(),
      );
      await _eventsOf(uid).doc(newId).set(event.toMap());

      // ★ 觸發鈴鐺：寫自己的通知
      final notif = AppNotification(
        id: const Uuid().v4(),
        type: 'itinerary_calendar',
        title: '🗺 行程已加入月曆：$title',
        body: '${fmt(startDate)} ~ ${fmt(endDate)}・$days 天',
        senderName: _name,
        senderUid: uid,
        payload: event.toMap(),
        isRead: false,
        createdAt: DateTime.now(),
      );
      await _notifsOf(uid).doc(notif.id).set(notif.toMap());
      return true;
    } catch (e) {
      debugPrint('⚠️ [CalendarEvent] addItinerary: $e');
      return false;
    }
  }

  // ── 3. 監聽我的月曆事件（Stream） ────────────────────────────
  Stream<List<CalendarEvent>> watchMyEvents() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _eventsOf(uid)
        .orderBy('date')
        .snapshots()
        .map((s) => s.docs
        .map((d) => CalendarEvent.fromMap(d.data() as Map<String, dynamic>))
        .toList());
  }

  // ── 4. 移除月曆事件 ──────────────────────────────────────────
  Future<void> removeEvent(String eventId) async {
    final uid = _uid;
    if (uid == null) return;
    await _eventsOf(uid).doc(eventId).delete();
  }

  // ── 5. 搜尋使用者（完全對齊 SharedBudgetService.findUserByEmail） ──
  Future<Map<String, String>?> findUserByEmail(String email) async {
    if (email.isEmpty) return null;
    try {
      final snap = await _db
          .collection('users')
          .where('email', isEqualTo: email.trim().toLowerCase())
          .limit(1).get();
      if (snap.docs.isEmpty) return null;
      final d = snap.docs.first.data();
      return {
        'uid': snap.docs.first.id,
        'displayName': d['displayName']?.toString() ?? '使用者',
        'email': d['email']?.toString() ?? email,
      };
    } catch (e) {
      debugPrint('⚠️ [CalendarEvent] findUserByEmail: $e');
      return null;
    }
  }

  // ── 6. 分享活動給他人 ────────────────────────────────────────
  /// 回傳：'ok' | 'not_found' | 'self' | 'error'
  Future<String> shareEventToUser({
    required String targetEmail,
    required CalendarEvent event,
  }) async {
    final uid = _uid;
    if (uid == null) return 'error';
    try {
      final found = await findUserByEmail(targetEmail);
      if (found == null) return 'not_found';
      if (found['uid'] == uid) return 'self';

      final notif = AppNotification(
        id: const Uuid().v4(),
        type: 'event_share',
        title: '🎉 $_name 分享了一個活動給你',
        body: '${event.title}・${event.date}',
        senderName: _name,
        senderUid: uid,
        payload: event.toMap(),
        isRead: false,
        createdAt: DateTime.now(),
      );
      await _notifsOf(found['uid']!).doc(notif.id).set(notif.toMap());
      return 'ok';
    } catch (e) {
      debugPrint('⚠️ [CalendarEvent] shareEvent: $e');
      return 'error';
    }
  }

  // ── 7. 監聽我的通知（Stream） ────────────────────────────────
  Stream<List<AppNotification>> watchMyNotifications() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    // ★ 不用 orderBy（避免 Firestore composite index 缺失導致空資料）
    //   改 client-side 排序
    return _notifsOf(uid)
        .limit(50)
        .snapshots()
        .map((s) {
      final list = s.docs
          .map((d) => AppNotification.fromMap(d.data() as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  // ── 8. 未讀通知數（Stream） ──────────────────────────────────
  Stream<int> watchUnreadCount() {
    final uid = _uid;
    if (uid == null) return Stream.value(0);
    // ★ 同樣不用 where+orderBy 組合，改 client-side filter
    return _notifsOf(uid)
        .limit(50)
        .snapshots()
        .map((s) => s.docs
        .where((d) => (d.data() as Map)['isRead'] != true)
        .length);
  }

  // ── 9. 標記已讀 ──────────────────────────────────────────────
  Future<void> markRead(String notifId) async {
    final uid = _uid;
    if (uid == null) return;
    await _notifsOf(uid).doc(notifId).update({'isRead': true});
  }

  // ── 10. 從通知加入月曆 ────────────────────────────────────────
  Future<bool> addFromNotification(AppNotification notif) async {
    try {
      final event = CalendarEvent.fromMap({...notif.payload, 'id': const Uuid().v4()});
      final ok = await addEventReminder(event);
      if (ok) await markRead(notif.id);
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ── 11. 刪除通知 ─────────────────────────────────────────────
  Future<void> deleteNotification(String notifId) async {
    final uid = _uid;
    if (uid == null) return;
    await _notifsOf(uid).doc(notifId).delete();
  }

  // ── 別名方法（向下相容 home_screen 舊版呼叫） ─────────────
  Future<void> markNotificationRead(String notifId) => markRead(notifId);
  Future<bool> addEventFromNotification(AppNotification notif) => addFromNotification(notif);
}



// ═══════════════════════════════════════════════════════════════
//  活動月曆頁面 ─ v3 動態版
//  ✅ 官方活動（寫死嘉義節慶） + 個人提醒（Firestore 同步）
//  ✅ 加入提醒 → 寫入 Firestore calendar_events
//  ✅ 分享活動 → 寫入對方 app_notifications，首頁鈴鐺顯示
//  ✅ 月曆點擊日期顯示當天所有事件
//  ✅ 行程事件可點擊導入行程詳情
// ═══════════════════════════════════════════════════════════════

const Map<String, Color> _tagColors = {
  '生態導覽':  Color(0xFF6BAE8B),
  '季節限定':  Color(0xFFE8A87C),
  '熱門':      Color(0xFF8B7355),
  '音樂藝文':  Color(0xFF7A9FD4),
  '國際盛事':  Color(0xFFB07AC8),
  '免費入場':  Color(0xFF6BAE8B),
  '美食體驗':  Color(0xFFE8C47C),
  '夜間活動':  Color(0xFF7A9FD4),
  '好康優惠':  Color(0xFF8B7355),
  '親子友善':  Color(0xFF7AC8A0),
  '在地小農':  Color(0xFFB0A87A),
  '展覽':      Color(0xFFB07AC8),
  '我的行程':  Color(0xFF8BAA88),
  '宗教文化':  Color(0xFFB07AC8),
  '體育賽事':  Color(0xFF4A90D9),
};
Color _tagColor(String tag) => _tagColors[tag] ?? const Color(0xFF8BAA88);

// ── 國定假日：date → 顯示短名 ─────────────────────────────────
// 格子上只顯示 2–4 字短名，不進入「今日活動」清單
const Map<String, String> _publicHolidays = {
  // 2025
  '2025-01-01': '元旦',
  '2025-01-29': '除夕',
  '2025-01-30': '初一',
  '2025-01-31': '初二',
  '2025-02-01': '初三',
  '2025-02-02': '初四',
  '2025-02-28': '和平日',
  '2025-04-04': '兒童節',
  '2025-04-05': '清明節',
  '2025-05-01': '勞動節',
  '2025-05-31': '端午節',
  '2025-10-06': '中秋節',
  '2025-10-10': '國慶日',
  '2025-12-31': '除夕',
  // 2026
  '2026-01-01': '元旦',
  '2026-02-17': '除夕',
  '2026-02-18': '初一',
  '2026-02-19': '初二',
  '2026-02-20': '初三',
  '2026-02-21': '初四',
  '2026-02-28': '和平日',
  '2026-04-04': '兒童節',
  '2026-05-01': '勞動節',
  '2026-06-19': '端午節',
  '2026-09-25': '中秋節',
  '2026-10-10': '國慶日',
};

String? _holidayName(DateTime d) {
  final key = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
  return _publicHolidays[key];
}
class EventModel {
  final String title;
  final String date;
  final String endDate;
  final String location;
  final String time;
  final String image;
  final String desc;
  final List<String> tags;

  const EventModel({
    required this.title,
    required this.date,
    this.endDate = '',
    required this.location,
    required this.time,
    required this.image,
    required this.desc,
    required this.tags,
  });
}

const List<EventModel> _officialEvents = [
  // ── 2025 ──
  EventModel(
    title: '第33屆嘉義國際管樂節',
    date: '2025-12-19', endDate: '2026-01-01',
    location: '嘉義市文化公園・文化路・中正公園',
    time: '多場次，詳見官網',
    image: 'https://icmp-ws.chiayi.gov.tw/001/Upload/399/relpic/9149/924184/cd8a8b2c-a4e7-4a41-910e-e0ac27b0ec85@710x470.jpg',
    desc: '嘉義市年度音樂盛典！邀請黃宣YELLOW、嘉頌重奏團、FlagStudio 等藝人同台，帶大家穿越30年的音樂記憶。活動橫跨室內外：嘉義市音樂廳、文化公園、中正公園等多個場館連續演出，感受滿滿的創作能量。',
    tags: ['音樂藝文', '國際盛事', '免費入場'],
  ),
  EventModel(
    title: '320+1 嘉義市城市博覽會',
    date: '2025-12-19', endDate: '2026-01-01',
    location: '嘉義市政府北棟大樓預定地（吳鳳北路、忠孝路、民權路、中山路旁）',
    time: '開放時間詳見官網',
    image: 'https://icmp-ws.chiayi.gov.tw/001/Upload/399/relpic/9150/914972/09769644-ded8-4dbf-a0d2-b0a5c1fc94a9.png',
    desc: '嘉義市建市320週年特別企劃！城市博覽會以光影藝術裝置展覽為核心，呈現嘉義的過去、現在與未來。融合科技互動、在地文化展示，讓每位到訪者都能深刻感受這座城市的獨特魅力。',
    tags: ['展覽', '國際盛事'],
  ),


  // ── 2026 ──
  EventModel(
    title: '阿里山螢火蟲季',
    date: '2026-04-15', endDate: '2026-06-30',
    location: '阿里山國家森林遊樂區',
    time: '20:00 - 22:00',
    image: 'https://www.ali-nsa.net/image/31656/1024x768',
    desc: '一年一度的阿里山螢火蟲季閃亮登場！整個阿里山國家風景區化身夢幻星光森林，每日限額300名遊客入場，強烈建議提前預約。',
    tags: ['生態導覽', '季節限定', '熱門'],
  ),


  EventModel(
    title: '嘉義農博春季展',
    date: '2026-05-25',
    location: '嘉義農業博覽會場',
    time: '09:00 - 17:00',
    image: 'https://static.wixstatic.com/media/e8a2cf_9a6e375464c94935b0549564879891c8~mv2.png/v1/fill/w_1470,h_585,al_c,q_90,usm_0.66_1.00_0.01,enc_avif,quality_auto/e8a2cf_9a6e375464c94935b0549564879891c8~mv2.png',
    desc: '春季最大農業博覽會，展出嘉義最新鮮的在地農特產品，現場設有親子手作區、小農市集與食農教育講座，非常適合全家大小週末同遊。',
    tags: ['親子友善', '在地小農', '展覽'],
  ),
  EventModel(
    title: '城隍廟文化祭',
    date: '2026-07-10', endDate: '2026-07-15',
    location: '嘉義城隍廟周邊',
    time: '全天',
    image: 'https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/Chiayi_Cheng_Huang_%28City_God%29_Temple%2C_Pailou_%28Arch%29_%28Taiwan%29.jpg/500px-Chiayi_Cheng_Huang_%28City_God%29_Temple%2C_Pailou_%28Arch%29_%28Taiwan%29.jpg',
    desc: '百年城隍廟一年一度文化祭，包含遶境、傳統陣頭表演、夜間燈會。是深度體驗嘉義在地信仰文化的最佳時機，吸引大批信眾與觀光客共同參與。',
    tags: ['宗教文化', '熱門'],
  ),

  EventModel(
    title: '阿里山賞楓季',
    date: '2026-11-01', endDate: '2026-11-30',
    location: '阿里山國家公園',
    time: '06:00 - 17:00',
    image: 'https://www.ali-nsa.net/image/14960/1024x768',
    desc: '秋天的阿里山換上火紅楓葉妝，漫步在楓紅林間感受季節的魔法。搭乘阿里山森林鐵道穿越雲海，居高臨下欣賞層層染紅的山巒，是一年中最浪漫的季節限定景象。',
    tags: ['生態導覽', '季節限定'],
  ),
  EventModel(
    title: '嘉義燈會',
    date: '2026-02-01', endDate: '2026-02-28',
    location: '嘉義公園・世賢路',
    time: '18:00 - 22:00',
    image: 'https://images.ctee.com.tw/newsphoto/2026-02-28/1024/20260228700656.jpg',
    desc: '每年元宵前後，嘉義公園與世賢路燈火通明！各式花燈藝術裝置點亮夜空，帶來濃厚年節氣氛。現場還有猜燈謎、小吃攤位，全家同樂的好去處。',
    tags: ['夜間活動', '親子友善', '免費入場'],
  ),
];

// ═══════════════════════════════════════════════════════════════
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  bool _isCalendarView = true;
  int _tabIndex = 0;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  // 從 Firestore 讀取的個人事件
  List<CalendarEvent> _personalEvents = [];
  StreamSubscription<List<CalendarEvent>>? _eventSub;
  bool _isLoading = true;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  final List<String> _tabs = ['全部', '官方活動', '我的行程', '已加提醒'];

  @override
  void initState() {
    super.initState();
    _eventSub = CalendarEventService.instance.watchMyEvents().listen((events) {
      if (mounted) setState(() { _personalEvents = events; _isLoading = false; });
    }, onError: (_) { if (mounted) setState(() => _isLoading = false); });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // 把官方活動轉成 CalendarEvent 格式，方便統一顯示
  List<CalendarEvent> get _officialAsCalendar => _officialEvents.map((e) => CalendarEvent(
    id: 'official_${e.date}_${e.title.hashCode.abs()}',
    type: CalendarEventType.officialEvent,
    title: e.title,
    date: e.date,
    endDate: e.endDate,
    time: e.time,
    location: e.location,
    desc: e.desc,
    image: e.image,
    tags: e.tags,
    createdAt: DateTime.now(),
  )).toList();

  // 判斷某日期是否有任何事件（官方 or 個人）
  bool _hasAnyEvent(DateTime date) {
    final ds = _fmt(date);
    final hasOfficial = _officialEvents.any((e) => _dateInRange(ds, e.date, e.endDate));
    final hasPersonal = _personalEvents.any((e) => _dateInRange(ds, e.date, e.endDate));
    return hasOfficial || hasPersonal;
  }

  // 取某天的所有事件（官方+個人，依 tab 過濾，去重）
  List<CalendarEvent> _getEventsForDay(DateTime date) {
    final ds = _fmt(date);
    final result = <CalendarEvent>[];

    if (_tabIndex == 0 || _tabIndex == 1) {
      // 官方活動：若已加入提醒則用個人版本（有 id 可刪除），否則用靜態版本
      for (final e in _officialAsCalendar.where((e) => _dateInRange(ds, e.date, e.endDate))) {
        final personal = _personalEvents.where((p) =>
        p.title == e.title && p.date == e.date &&
            p.type == CalendarEventType.officialEvent).firstOrNull;
        result.add(personal ?? e);
      }
      // ★ 加入從最新消息加進來的在地活動（不在 hardcoded 清單中）
      final hardcodedTitles = _officialAsCalendar.map((e) => e.title).toSet();
      result.addAll(_personalEvents.where((e) =>
      e.type == CalendarEventType.officialEvent &&
          !hardcodedTitles.contains(e.title) &&
          _dateInRange(ds, e.date, e.endDate)));
    }
    if (_tabIndex == 0 || _tabIndex == 2) {
      result.addAll(_personalEvents.where((e) =>
      e.type == CalendarEventType.itinerary && _dateInRange(ds, e.date, e.endDate)));
    }
    if (_tabIndex == 3) {
      // 「已加提醒」tab：所有個人 officialEvent（包含 news 加入的在地活動）
      result.addAll(_personalEvents.where((e) =>
      e.type == CalendarEventType.officialEvent && _dateInRange(ds, e.date, e.endDate)));
    }
    return result;
  }

  // 清單模式下所有事件（去重）
  List<CalendarEvent> get _allEventsForList {
    final result = <CalendarEvent>[];
    if (_tabIndex == 0 || _tabIndex == 1) {
      for (final e in _officialAsCalendar) {
        final personal = _personalEvents.where((p) =>
        p.title == e.title && p.date == e.date &&
            p.type == CalendarEventType.officialEvent).firstOrNull;
        if (personal != null) {
          result.add(CalendarEvent(
            id: personal.id,
            type: personal.type,
            title: e.title,
            date: e.date,
            endDate: e.endDate,
            time: e.time,
            location: e.location,
            desc: e.desc,
            image: e.image,
            tags: e.tags,
            itineraryId: personal.itineraryId,
            newsActivityId: personal.newsActivityId,
            createdAt: personal.createdAt,
          ));
        } else {
          result.add(e);
        }
      }
      // ★ 加入從最新消息加進來的在地活動（不在 hardcoded 清單中）
      final hardcodedTitles = _officialAsCalendar.map((e) => e.title).toSet();
      result.addAll(_personalEvents.where((e) =>
      e.type == CalendarEventType.officialEvent &&
          !hardcodedTitles.contains(e.title)));
    }
    if (_tabIndex == 0 || _tabIndex == 2) {
      result.addAll(_personalEvents.where((e) => e.type == CalendarEventType.itinerary));
    }
    if (_tabIndex == 3) {
      // 「已加提醒」tab：所有個人 officialEvent（包含在地活動）
      result.addAll(_personalEvents.where((e) => e.type == CalendarEventType.officialEvent));
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    // ★ 套用搜尋過濾
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      return result.where((e) =>
      e.title.toLowerCase().contains(q) ||
          e.location.toLowerCase().contains(q) ||
          e.tags.any((t) => t.toLowerCase().contains(q))).toList();
    }
    return result;
  }

  String _fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  bool _dateInRange(String ds, String start, String end) {
    if (end.isEmpty) return ds == start;
    return ds.compareTo(start) >= 0 && ds.compareTo(end) <= 0;
  }

  // 判斷個人事件中是否已有某官方活動
  bool _isAdded(EventModel e) => _personalEvents.any(
          (p) => p.title == e.title && p.date == e.date && p.type == CalendarEventType.officialEvent);

  @override
  Widget build(BuildContext context) {
    // ★ 月曆模式也套用搜尋過濾
    List<CalendarEvent> rawDay = _isCalendarView
        ? _getEventsForDay(_selectedDay)
        : _allEventsForList;
    final displayEvents = (_isCalendarView && _searchQuery.isNotEmpty)
        ? rawDay.where((e) {
      final q = _searchQuery.toLowerCase();
      return e.title.toLowerCase().contains(q) ||
          e.location.toLowerCase().contains(q) ||
          e.tags.any((t) => t.toLowerCase().contains(q));
    }).toList()
        : rawDay;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),
          SliverToBoxAdapter(child: _buildSearchBar()),
          SliverToBoxAdapter(child: _buildFilterTabs()),
          SliverToBoxAdapter(child: _buildViewToggle()),
          if (_isCalendarView)
            SliverToBoxAdapter(child: _buildElegantCalendar()),
          SliverToBoxAdapter(
            child: _buildStyledSectionTitle(
              _isCalendarView ? Icons.event_available_rounded : Icons.format_list_bulleted_rounded,
              _isCalendarView ? '${_selectedDay.month}月${_selectedDay.day}日 的活動' : '所有活動',
            ),
          ),
          if (_isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88))),
              ),
            )
          else if (displayEvents.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    _isCalendarView ? '這天暫無安排活動 🌱' : '目前沒有活動',
                    style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildEventCard(displayEvents[i]),
                childCount: displayEvents.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
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
                  Text('EVENTS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
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
                    Icon(Icons.calendar_month_rounded, size: 14, color: Color(0xFF8BAA88)),
                    SizedBox(width: 6),
                    Text('活動月曆', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
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
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)],
        ),
        child: Row(
          children: [
            const SizedBox(width: 18),
            const Icon(Icons.search_rounded, color: Color(0xFF8BAA88), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
                style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '搜尋節慶、展覽、活動...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 14),
                ),
              ),
            ),
            if (_searchQuery.isNotEmpty)
              GestureDetector(
                onTap: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); },
                child: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.close_rounded, color: Color(0xFF9E9182), size: 18),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(20)),
                child: const Center(child: Text('搜尋', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterTabs() {
    return SizedBox(
      height: 45,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: List.generate(_tabs.length, (i) {
          final isSel = i == _tabIndex;
          return GestureDetector(
            onTap: () => setState(() => _tabIndex = i),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isSel ? const Color(0xFF8BAA88) : Colors.white,
                border: Border.all(color: isSel ? Colors.transparent : const Color(0xFF8BAA88).withOpacity(0.3)),
                borderRadius: BorderRadius.circular(20),
                boxShadow: isSel ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 3))] : [],
              ),
              child: Text(_tabs[i], style: TextStyle(fontFamily: 'MyCustomFont', color: isSel ? Colors.white : const Color(0xFF7D6E5D), fontSize: 13, fontWeight: FontWeight.bold)),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildViewToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)],
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _isCalendarView = true),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _isCalendarView ? const Color(0xFF8BAA88) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: _isCalendarView ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))] : [],
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_month_rounded, size: 16, color: _isCalendarView ? Colors.white : const Color(0xFF7D6E5D)),
                        const SizedBox(width: 6),
                        Text('月曆模式', style: TextStyle(fontFamily: 'MyCustomFont', color: _isCalendarView ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _isCalendarView = false),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: !_isCalendarView ? const Color(0xFF8BAA88) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: !_isCalendarView ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))] : [],
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.format_list_bulleted_rounded, size: 16, color: !_isCalendarView ? Colors.white : const Color(0xFF7D6E5D)),
                        const SizedBox(width: 6),
                        Text('清單模式', style: TextStyle(fontFamily: 'MyCustomFont', color: !_isCalendarView ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElegantCalendar() {
    final now = DateTime.now();
    final firstDay = DateTime(_focusedDay.year, _focusedDay.month, 1);
    final lastDay = DateTime(_focusedDay.year, _focusedDay.month + 1, 0);
    final startWeekday = firstDay.weekday % 7;
    final totalCells = startWeekday + lastDay.day;
    final gridCount = (totalCells / 7).ceil() * 7;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 15, offset: const Offset(0, 8))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _focusedDay = DateTime(_focusedDay.year, _focusedDay.month - 1)),
                  child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFF9F8F4), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2))), child: const Icon(Icons.chevron_left_rounded, color: Color(0xFF7D6E5D), size: 20)),
                ),
                Text('${_focusedDay.year} 年 ${_focusedDay.month.toString().padLeft(2, '0')} 月', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), letterSpacing: 1.2)),
                GestureDetector(
                  onTap: () => setState(() => _focusedDay = DateTime(_focusedDay.year, _focusedDay.month + 1)),
                  child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFF9F8F4), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2))), child: const Icon(Icons.chevron_right_rounded, color: Color(0xFF7D6E5D), size: 20)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: ['日','一','二','三','四','五','六']
                  .map((d) => Expanded(child: Center(child: Text(d, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF9E9182), fontWeight: FontWeight.bold)))))
                  .toList(),
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
            ...List.generate((gridCount / 7).round(), (rowIdx) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: List.generate(7, (colIdx) {
                    final cellIdx = rowIdx * 7 + colIdx;
                    final dayNum = cellIdx - startWeekday + 1;
                    if (dayNum < 1 || dayNum > lastDay.day) return const Expanded(child: SizedBox(height: 56));
                    final date = DateTime(_focusedDay.year, _focusedDay.month, dayNum);
                    final isToday = date.year == now.year && date.month == now.month && date.day == now.day;
                    final isSelected = date.year == _selectedDay.year && date.month == _selectedDay.month && date.day == _selectedDay.day;
                    final hasEvent = _hasAnyEvent(date);
                    final hasPersonal = _personalEvents.any((e) => _dateInRange(_fmt(date), e.date, e.endDate));
                    final holidayName = _holidayName(date);
                    final isHoliday = holidayName != null;
                    final isSunday = date.weekday == 7;
                    final isSaturday = date.weekday == 6;

                    // 文字顏色
                    Color dayColor;
                    if (isToday) {
                      dayColor = Colors.white;
                    } else if (isHoliday || isSunday) {
                      dayColor = const Color(0xFF9E7B6B); // 暖褐色取代金色
                    } else if (isSaturday) {
                      dayColor = const Color(0xFF8BAA88); // 抹茶綠取代藍色
                    } else {
                      dayColor = const Color(0xFF7D6E5D);
                    }

                    // 背景色
                    Color bgColor;
                    if (isToday) {
                      bgColor = const Color(0xFF8BAA88);
                    } else if (isSelected) {
                      bgColor = const Color(0xFFF5F2EE);
                    } else if (isHoliday) {
                      bgColor = const Color(0xFFF5EDE8); // 淡暖褐底色取代紅底
                    } else {
                      bgColor = Colors.transparent;
                    }

                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() { _selectedDay = date; _isCalendarView = true; }),
                        child: Container(
                          height: 56,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(12),
                            border: isHoliday && !isToday
                                ? Border.all(color: const Color(0xFF9E7B6B).withOpacity(0.5), width: 1.5)
                                : isSelected && !isToday
                                ? Border.all(color: const Color(0xFF8BAA88).withOpacity(0.7), width: 2.0)
                                : null,
                            boxShadow: isToday
                                ? [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 6, offset: const Offset(0, 3))]
                                : isHoliday && !isToday
                                ? [BoxShadow(color: const Color(0xFF9E7B6B).withOpacity(0.15), blurRadius: 4, offset: const Offset(0, 2))]
                                : [],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$dayNum',
                                style: TextStyle(
                                  fontFamily: 'MyCustomFont',
                                  fontSize: 14,
                                  color: dayColor,
                                  fontWeight: isToday || isSelected || isHoliday
                                      ? FontWeight.w900
                                      : FontWeight.w600,
                                ),
                              ),
                              // 假日名稱 或 事件圓點
                              if (isHoliday && !isToday) ...[
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF9E7B6B).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    holidayName,
                                    style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      fontSize: 8,
                                      color: Color(0xFF9E7B6B),
                                      fontWeight: FontWeight.w900,
                                      height: 1.2,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                  ),
                                ),
                              ] else if (isToday && isHoliday) ...[
                                const SizedBox(height: 2),
                                Text(
                                  holidayName,
                                  style: const TextStyle(
                                    fontFamily: 'MyCustomFont',
                                    fontSize: 8,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    height: 1.2,
                                  ),
                                ),
                              ] else if (hasEvent) ...[
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1),
                                        decoration: BoxDecoration(
                                            color: isToday ? Colors.white : const Color(0xFF8B7355),
                                            shape: BoxShape.circle)),
                                    if (hasPersonal)
                                      Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1),
                                          decoration: BoxDecoration(
                                              color: isToday ? Colors.white70 : const Color(0xFF8BAA88),
                                              shape: BoxShape.circle)),
                                  ],
                                ),
                              ] else
                                const SizedBox(height: 5),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
            // ── 圖例 ──
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _buildLegendDot(const Color(0xFF9E7B6B), '國定假日'),
              const SizedBox(width: 10),
              _buildLegendDot(const Color(0xFF8B7355), '官方活動'),
              const SizedBox(width: 10),
              _buildLegendDot(const Color(0xFF8BAA88), '我的提醒'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Color(0xFF9E9182))),
    ],
  );

  Widget _buildStyledSectionTitle(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Row(
        children: [
          Container(width: 4, height: 20, decoration: BoxDecoration(color: const Color(0xFF8BAA88), borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
          Icon(icon, size: 20, color: const Color(0xFF7D6E5D)),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), letterSpacing: 1.2)),
        ],
      ),
    );
  }

  Widget _buildEventCard(CalendarEvent event) {
    final isItinerary = event.type == CalendarEventType.itinerary;
    final isAdded = _personalEvents.any((p) => p.title == event.title && p.date == event.date);
    final isHolidayCard = event.tags.contains('國定假日');

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(
            event: event,
            isAdded: isAdded,
            onAddReminder: isItinerary ? null : (e) async {
              final ok = await CalendarEventService.instance.addEventReminder(e);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok ? '✅ 已加入月曆！' : '⚠️ 此活動已在月曆中', style: const TextStyle(fontFamily: 'MyCustomFont')),
                  backgroundColor: ok ? const Color(0xFF8BAA88) : const Color(0xFF9EB89A),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ));
              }
            },
            onRemove: isAdded ? (e) async {
              await CalendarEventService.instance.removeEvent(e.id);
              if (mounted) Navigator.pop(context);
            } : null,
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isItinerary
                ? const Color(0xFF8BAA88).withOpacity(0.4)
                : isHolidayCard
                ? const Color(0xFF9E7B6B).withOpacity(0.25)
                : const Color(0xFF8BAA88).withOpacity(0.2),
          ),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            // ── 圖片欄位：行程不顯示圖片，改用行程 icon ──
            if (isItinerary)
              Container(
                width: 90, height: 90,
                decoration: BoxDecoration(
                  color: const Color(0xFF8BAA88).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                ),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.map_rounded, size: 28, color: Color(0xFF8BAA88)),
                  SizedBox(height: 4),
                  Text('我的行程', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 9, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                ]),
              )
            else
              Container(
                width: 90, height: 90,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isHolidayCard
                        ? const Color(0xFF9E7B6B).withOpacity(0.4)
                        : const Color(0xFF8BAA88).withOpacity(0.2),
                    width: isHolidayCard ? 2 : 1,
                  ),
                  // 假日卡片加淡黃底色光暈
                  boxShadow: isHolidayCard
                      ? [BoxShadow(color: const Color(0xFF9E7B6B).withOpacity(0.1), blurRadius: 8, spreadRadius: 1)]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: event.image.isNotEmpty
                      ? Image.network(event.image, width: 90, height: 90, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: isHolidayCard ? const Color(0xFFFFF8E1) : const Color(0xFFE8E0D8),
                        child: Icon(
                          isHolidayCard ? Icons.celebration_rounded : Icons.calendar_month_rounded,
                          color: isHolidayCard ? const Color(0xFF9E7B6B) : Colors.white54,
                          size: 32,
                        ),
                      ))
                      : Container(
                    color: isHolidayCard ? const Color(0xFFFFF8E1) : const Color(0xFFE8E0D8),
                    child: Icon(
                      isHolidayCard ? Icons.celebration_rounded : Icons.calendar_month_rounded,
                      color: isHolidayCard ? const Color(0xFF9E7B6B) : Colors.white54,
                      size: 32,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.calendar_month_rounded, size: 13, color: Color(0xFF8BAA88)),
                      const SizedBox(width: 4),
                      Expanded(child: Text(
                        event.endDate.isNotEmpty
                            ? '${event.date} ~ ${event.endDate}'
                            : '${event.date} | ${event.time}',
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      )),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.location_on_rounded, size: 13, color: Color(0xFF8BAA88)),
                      const SizedBox(width: 4),
                      Expanded(child: Text(event.location, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 標籤 + 已加入月曆標記
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      ...event.tags.take(2).map((t) {
                        final c = _tagColor(t);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.3))),
                          child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: c, fontSize: 9, fontWeight: FontWeight.bold)),
                        );
                      }),
                      if (isAdded)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF9EB89A).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF9EB89A).withOpacity(0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.check_rounded, size: 9, color: Color(0xFF9EB89A)),
                            SizedBox(width: 2),
                            Text('已加入月曆', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9EB89A), fontSize: 9, fontWeight: FontWeight.bold)),
                          ]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle),
              child: const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF8BAA88), size: 14),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  活動詳情頁面
// ═══════════════════════════════════════════════════════════════
class EventDetailScreen extends StatefulWidget {
  final CalendarEvent event;
  final bool isAdded;
  final Future<void> Function(CalendarEvent)? onAddReminder;
  final Future<void> Function(CalendarEvent)? onRemove;
  /// 若從 news 加入的提醒，傳入 ActivityItem 可讓「查看詳情」跳回 news
  final dynamic newsActivity; // ActivityItem from news_screen

  const EventDetailScreen({
    super.key,
    required this.event,
    this.isAdded = false,
    this.onAddReminder,
    this.onRemove,
    this.newsActivity,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  bool _isFavorite = false;
  bool _isAdded = false;
  bool _isLoading = false;
  bool _favLoading = false;
  String _note = '';          // ★ 個人紀錄
  String? _savedEventId;      // ★ 已存的 calendar_event id（用於刪除）

  @override
  void initState() {
    super.initState();
    _isAdded = widget.isAdded;
    _checkFavorite();
    _loadNoteAndId();
  }

  // ★ 讀取筆記 + 取得已存的 event id
  Future<void> _loadNoteAndId() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('calendar_events')
          .where('title', isEqualTo: widget.event.title)
          .where('date', isEqualTo: widget.event.date)
          .limit(1).get();
      if (snap.docs.isNotEmpty && mounted) {
        final data = snap.docs.first.data();
        setState(() {
          _savedEventId = snap.docs.first.id;
          _note = data['note']?.toString() ?? '';
          _isAdded = true;
        });
      }
    } catch (_) {}
  }

  // ★ 刪除此月曆事件
  Future<void> _deleteEvent() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final id = _savedEventId ?? widget.event.id;
    if (id.isEmpty || id.startsWith('official_')) return;
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('calendar_events')
          .doc(id).delete();
      if (mounted) {
        setState(() { _isAdded = false; _savedEventId = null; _note = ''; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已從月曆移除', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF9E7B6B),
          behavior: SnackBarBehavior.floating,
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('移除失敗: $e', style: const TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: const Color(0xFF9E7B6B),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ★ 儲存筆記
  Future<void> _saveNote(String note) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final id = _savedEventId ?? widget.event.id;
    if (id.isEmpty || id.startsWith('official_')) return;
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('calendar_events')
          .doc(id).update({'note': note});
      if (mounted) {
        setState(() => _note = note);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ 筆記已儲存', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF8BAA88),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {}
  }

  // ★ 顯示筆記編輯 Dialog
  void _showNoteDialog() {
    final ctrl = TextEditingController(text: _note);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
              const Text('我的筆記', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 4),
              const Text('可以記錄你對這個活動的想法、備忘等', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                decoration: InputDecoration(
                  hintText: '寫下你的想法或備忘…',
                  hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey[400], fontSize: 13),
                  filled: true, fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _saveNote(ctrl.text.trim());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8BAA88), elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('儲存筆記', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkFavorite() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('favorites')
          .doc(_favDocId)
          .get();
      if (mounted) setState(() => _isFavorite = doc.exists);
    } catch (_) {}
  }

  String get _favDocId =>
      'event_${widget.event.date}_${widget.event.title.hashCode.abs()}';

  Future<void> _toggleFavorite() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _favLoading) return;
    setState(() => _favLoading = true);
    try {
      final ref = FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('favorites')
          .doc(_favDocId);
      if (_isFavorite) {
        await ref.delete();
        if (mounted) {
          setState(() { _isFavorite = false; _favLoading = false; });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已從收藏移除', style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: const Color(0xFF9EB89A),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } else {
        await ref.set({
          'id': _favDocId,
          'type': '活動',
          'title': widget.event.title,
          'sub': widget.event.location.isNotEmpty ? widget.event.location : '嘉義活動',
          'date': widget.event.date,
          'image': widget.event.image,
          'tags': widget.event.tags,
          'desc': widget.event.desc,
          'score': '5.0',
          'source': 'calendar',
          'createdAt': DateTime.now().toIso8601String(),
        });
        if (mounted) {
          setState(() { _isFavorite = true; _favLoading = false; });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ 已加入收藏！可在「我的收藏」→「活動」查看', style: TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: Color(0xFF8BAA88),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _favLoading = false);
    }
  }

  // 分享 Dialog
  void _showShareDialog() {
    final emailCtrl = TextEditingController();
    Map<String, String>? foundUser;   // uid / displayName / email
    bool isSearching = false;
    String? errorMsg;
    bool isSent = false;
    bool isSending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // handle bar
                Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                const Text('分享活動', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 4),
                Text('對方會在首頁鈴鐺收到通知，點擊可查看活動介紹', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 14),
                // 活動預覽卡片
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.25))),
                  child: Row(children: [
                    if (widget.event.image.isNotEmpty)
                      ClipRRect(borderRadius: BorderRadius.circular(8),
                          child: Image.network(widget.event.image, width: 48, height: 48, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(width: 48, height: 48, color: const Color(0xFFE8E0D8))))
                    else
                      Container(width: 48, height: 48,
                          decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.event_rounded, color: Color(0xFF8BAA88), size: 24)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.event.title, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('${widget.event.date}・${widget.event.location}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ])),
                  ]),
                ),
                const SizedBox(height: 14),
                // Email 輸入 + 搜尋按鈕（budget 風格）
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                      onChanged: (_) => setS(() { foundUser = null; errorMsg = null; isSent = false; }),
                      onSubmitted: (_) async {
                        if (emailCtrl.text.trim().isEmpty) return;
                        setS(() { isSearching = true; foundUser = null; errorMsg = null; });
                        final r = await CalendarEventService.instance.findUserByEmail(emailCtrl.text.trim());
                        final myUid = FirebaseAuth.instance.currentUser?.uid;
                        setS(() {
                          isSearching = false;
                          if (r == null) { errorMsg = '找不到此 Email 的使用者，請確認對方已使用此 Email 登入 App'; }
                          else if (r['uid'] == myUid) { errorMsg = '不能分享給自己'; }
                          else { foundUser = r; errorMsg = null; }
                        });
                      },
                      decoration: InputDecoration(
                        hintText: '輸入對方 Email…',
                        hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey[400], fontSize: 13),
                        prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF8BAA88), size: 18),
                        suffixIcon: emailCtrl.text.isNotEmpty
                            ? IconButton(icon: const Icon(Icons.clear_rounded, size: 16, color: Colors.grey),
                            onPressed: () { emailCtrl.clear(); setS(() { foundUser = null; errorMsg = null; isSent = false; }); })
                            : null,
                        filled: true, fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(height: 46, child: ElevatedButton(
                    onPressed: isSearching ? null : () async {
                      final email = emailCtrl.text.trim();
                      if (email.isEmpty) { setS(() => errorMsg = '請輸入 Email 地址'); return; }
                      setS(() { isSearching = true; foundUser = null; errorMsg = null; isSent = false; });
                      final r = await CalendarEventService.instance.findUserByEmail(email);
                      final myUid = FirebaseAuth.instance.currentUser?.uid;
                      setS(() {
                        isSearching = false;
                        if (r == null) { errorMsg = '找不到此 Email 的使用者，\n請確認對方已使用此 Email 登入 App'; }
                        else if (r['uid'] == myUid) { errorMsg = '不能分享給自己'; }
                        else { foundUser = r; errorMsg = null; }
                      });
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8BAA88),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: isSearching
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('搜尋', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                ]),
                // 錯誤訊息
                if (errorMsg != null) Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(errorMsg!, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E7B6B), fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                // 找到使用者卡片（budget 風格）
                if (foundUser != null) ...[
                  const SizedBox(height: 12),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 260),
                    builder: (_, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, (1-t)*8), child: child)),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8BAA88).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                      ),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
                          child: Text(
                            (foundUser!['displayName'] ?? '?')[0].toUpperCase(),
                            style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(foundUser!['displayName'] ?? '使用者',
                              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 13)),
                          Text(foundUser!['email'] ?? '',
                              style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 11)),
                        ])),
                        if (isSent)
                          const Icon(Icons.check_circle_rounded, color: Color(0xFF8BAA88), size: 20)
                        else
                          ElevatedButton(
                            onPressed: isSending ? null : () async {
                              setS(() => isSending = true);
                              final r = await CalendarEventService.instance.shareEventToUser(
                                targetEmail: foundUser!['email']!,
                                event: widget.event,
                              );
                              setS(() { isSending = false; isSent = r == 'ok'; });
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text(r == 'ok' ? '✅ 通知已成功發送給 ${foundUser!['displayName']}！' : '❌ 發送失敗',
                                      style: const TextStyle(fontFamily: 'MyCustomFont')),
                                  backgroundColor: r == 'ok' ? const Color(0xFF8BAA88) : const Color(0xFF9E7B6B),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ));
                              }
                            },
                            style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8BAA88),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                            child: isSending
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                : const Text('發送', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                      ]),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isItinerary = widget.event.type == CalendarEventType.itinerary;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: isItinerary ? 160.0 : 300.0,
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
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.4), shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.5))),
                      child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF7D6E5D)),
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12, top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: GestureDetector(
                      onTap: _favLoading ? null : _toggleFavorite,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _isFavorite ? const Color(0xFF8BAA88).withOpacity(0.9) : Colors.white.withOpacity(0.4),
                          shape: BoxShape.circle,
                          border: Border.all(color: _isFavorite ? const Color(0xFF8BAA88).withOpacity(0.6) : Colors.white.withOpacity(0.5)),
                        ),
                        child: _favLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8BAA88)))
                            : Icon(_isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 20, color: _isFavorite ? Colors.white : const Color(0xFF7D6E5D)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: isItinerary
              // 行程：不顯示圖片，改用漸層 + 地圖 icon
                  ? Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF8BAA88).withOpacity(0.15),
                      const Color(0xFFD4E8D0).withOpacity(0.4),
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8BAA88).withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.map_rounded, size: 48, color: Color(0xFF8BAA88)),
                      ),
                      const SizedBox(height: 12),
                      const Text('我的行程', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88))),
                    ],
                  ),
                ),
              )
                  : Stack(
                fit: StackFit.expand,
                children: [
                  widget.event.image.isNotEmpty
                      ? Image.network(widget.event.image, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: const Color(0xFFE8E0D8)))
                      : Container(color: const Color(0xFFE8E0D8),
                      child: const Center(child: Icon(Icons.calendar_month_rounded, size: 60, color: Colors.white54))),
                  Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, const Color(0xFFF9F8F4).withOpacity(0.95)]))),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.event.tags.map((t) {
                      final color = _tagColor(t);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.35))),
                        child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: color, fontSize: 12, fontWeight: FontWeight.w900)),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Text(widget.event.title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), height: 1.3, letterSpacing: 0.5)),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)]),
                    child: Column(
                      children: [
                        _buildInfoRow(Icons.calendar_month_rounded, '活動日期',
                            widget.event.endDate.isNotEmpty
                                ? '${widget.event.date} ~ ${widget.event.endDate}'
                                : widget.event.date),
                        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
                        _buildInfoRow(Icons.access_time_rounded, '活動時間', widget.event.time),
                        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
                        _buildInfoRow(Icons.location_on_rounded, '舉辦地點', widget.event.location),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text('活動介紹', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                  const SizedBox(height: 12),
                  Text(widget.event.desc, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, color: Color(0xFF4A4036), height: 1.8, letterSpacing: 0.5)),
                  const SizedBox(height: 40),
                  // ★ 筆記區塊（已加入月曆才顯示）
                  if (_isAdded) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8BAA88).withOpacity(0.06),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(children: [
                                const Icon(Icons.notes_rounded, size: 16, color: Color(0xFF8BAA88)),
                                const SizedBox(width: 6),
                                const Text('我的筆記', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                              ]),
                              GestureDetector(
                                onTap: _showNoteDialog,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF8BAA88).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(_note.isEmpty ? '新增筆記' : '編輯', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ],
                          ),
                          if (_note.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(_note, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), height: 1.5)),
                          ] else ...[
                            const SizedBox(height: 8),
                            Text('點擊「新增筆記」記錄你的想法 ✍️', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey[400], fontStyle: FontStyle.italic)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 從月曆移除按鈕
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFFF9F8F4),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              title: const Text('從月曆移除', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                              content: Text('確定要從月曆移除「${widget.event.title}」嗎？', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182))),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88))),
                                ),
                                ElevatedButton(
                                  onPressed: () { Navigator.pop(ctx); _deleteEvent(); },
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF9E7B6B), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                                  child: const Text('移除', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFF9E7B6B)),
                        label: const Text('從月曆移除', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E7B6B), fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: const Color(0xFF9E7B6B).withOpacity(0.4)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // ── 底部按鈕 ──
                  Row(
                    children: [
                      // 分享按鈕（行程類型不顯示分享）
                      if (!isItinerary) ...[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _showShareDialog,
                            icon: const Icon(Icons.share_rounded, size: 18, color: Color(0xFF8BAA88)),
                            label: const Text('分享活動', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: BorderSide(color: const Color(0xFF8BAA88).withOpacity(0.5), width: 1.5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      // 加入提醒 / 已加入 / 前往行程 / 前往新聞
                      Expanded(
                        child: isItinerary
                            ? ElevatedButton.icon(
                          // 行程：前往行程詳情
                          onPressed: widget.event.itineraryId == null ? null : () async {
                            final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                            final itineraries = await LocalDbService.instance.getAllItineraries(userId: uid);
                            final match = itineraries.where((it) => it.id == widget.event.itineraryId).firstOrNull;
                            if (match == null || !context.mounted) return;
                            final plans = <DailyItinerary>[];
                            try {
                              final decoded = (jsonDecode(match.plansJson) as List)
                                  .map((e) => Map<String, dynamic>.from(e as Map))
                                  .toList();
                              for (final d in decoded) {
                                final rawItems = (d['items'] as List? ?? []);
                                final items = rawItems.map((raw) {
                                  final m = Map<String, dynamic>.from(raw as Map);
                                  final tt = Map<String, dynamic>.from(m['transportTimes'] as Map? ?? {});
                                  List<String> tips = [];
                                  if (m['tips'] is List) tips = List<String>.from(m['tips'] as List);
                                  else if (m['tips'] is String && (m['tips'] as String).isNotEmpty) tips = [m['tips'] as String];
                                  final rawTicket = m['ticket']?.toString();
                                  return ItineraryItem(
                                    time: m['time']?.toString() ?? '09:00',
                                    title: m['title']?.toString() ?? '',
                                    location: m['location']?.toString() ?? '',
                                    duration: m['duration']?.toString() ?? '1 小時',
                                    transportTimes: {
                                      TransportType.car:     tt['car']?.toString()     ?? '10min',
                                      TransportType.transit: tt['transit']?.toString() ?? '15min',
                                      TransportType.bike:    tt['bike']?.toString()    ?? '15min',
                                      TransportType.walk:    tt['walk']?.toString()    ?? '25min',
                                    },
                                    selectedTransport: TransportType.values.firstWhere(
                                          (t) => t.name == (m['selectedTransport']?.toString() ?? 'transit'),
                                      orElse: () => TransportType.transit,
                                    ),
                                    tips: tips,
                                    ticket: (rawTicket == null || rawTicket == 'null') ? null : rawTicket,
                                    mapPosition: LatLng(
                                      (m['lat'] as num?)?.toDouble() ?? 23.4801,
                                      (m['lon'] as num?)?.toDouble() ?? 120.4491,
                                    ),
                                    category: m['category']?.toString() ?? '景點',
                                    transportFrom: m['transport_from']?.toString() ?? '',
                                  );
                                }).toList();
                                plans.add(DailyItinerary(d['dayLabel']?.toString() ?? 'Day 1', items));
                              }
                            } catch (_) {}
                            if (!context.mounted) return;
                            Navigator.push(context, MaterialPageRoute(
                              builder: (_) => ItineraryDetailScreen(
                                tripPlan: TripPlan(match.title, match.estimatedBudget, match.startDate, match.endDate, plans, id: match.id),
                              ),
                            ));
                          },
                          icon: const Icon(Icons.map_rounded, size: 18, color: Colors.white),
                          label: const Text('查看行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), backgroundColor: const Color(0xFF8BAA88), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        )
                        // news 活動：若有 newsActivity 則顯示「查看詳情」
                            : widget.newsActivity != null
                            ? ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(context, MaterialPageRoute(
                              builder: (_) => NewsDetailScreen(activity: widget.newsActivity!),
                            ));
                          },
                          icon: const Icon(Icons.article_rounded, size: 18, color: Colors.white),
                          label: const Text('查看詳情', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), backgroundColor: const Color(0xFF8BAA88), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        )
                            : AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          child: ElevatedButton.icon(
                            onPressed: (_isAdded || _isLoading) ? null : () async {
                              setState(() => _isLoading = true);
                              if (widget.onAddReminder != null) {
                                await widget.onAddReminder!(widget.event);
                                if (mounted) setState(() { _isAdded = true; _isLoading = false; });
                              } else {
                                setState(() => _isLoading = false);
                              }
                            },
                            icon: Icon(_isAdded ? Icons.check_rounded : Icons.calendar_month_rounded, size: 18, color: Colors.white),
                            label: Text(_isAdded ? '已加入月曆' : '加入月曆', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              backgroundColor: _isAdded ? const Color(0xFF9EB89A) : const Color(0xFF8BAA88),
                              elevation: _isAdded ? 0 : 5,
                              shadowColor: const Color(0xFF8BAA88).withOpacity(0.4),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle), child: Icon(icon, size: 16, color: const Color(0xFF8BAA88))),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold)),
        const Spacer(),
        Expanded(
          child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900), maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}