import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import 'traffic_screen.dart' show ParkingInfoScreen, YouBikeInfoScreen, BusInfoScreen;
import 'traffic_api_service.dart';
import 'attractions_screen.dart' show AttractionsScreen, AttractionModel, AttractionDetailScreen, NavTarget;
import 'food_screen.dart' show FoodScreen, FoodModel, FoodDetailScreen, FoodComment;
import 'accommodation_screen.dart' show AccommodationScreen, HotelModel, HotelDetailScreen, HotelComment, RoomType;
import 'local_db_service.dart';
import 'itinerary_save_service.dart';
import 'firebase_sync_service.dart';
import 'community_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_state.dart' show AppStateManager;
import 'home_screen.dart' show UserAvatar;
import 'calendar_screen.dart' show CalendarEventService;
import 'help_support_screen.dart';
import 'system_settings_screen.dart';
import 'profile_screen.dart' show UserLogsPage;
import 'login_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  地圖探索與行程頁 ─ OSM 實體地圖 + GPS 真實定位整合版
// ═══════════════════════════════════════════════════════════════

// ── 交通資料型別 ──

enum MapMarkerKind { poi, parking, ubike, bus }

// ── 通用 POI 標記資料模型（景點 / 餐廳）──
class PoiMarker {
  final String id;
  final String name;
  final String category;   // '景點' | '美食'
  final double lat;
  final double lon;
  final String address;
  final String description;
  final String imageUrl;
  final double? starRating;
  final String phone;
  final String openTime;
  const PoiMarker({
    required this.id, required this.name, required this.category,
    required this.lat, required this.lon,
    this.address = '', this.description = '', this.imageUrl = '',
    this.starRating, this.phone = '', this.openTime = '',
  });

  Color get markerColor {
    if (category == '景點') return const Color(0xFF8BAA88);
    if (category == '美食') return const Color(0xFFA5CBD4);
    return const Color(0xFF9E9182);
  }

  IconData get markerIcon {
    if (category == '景點') return Icons.landscape_rounded;
    if (category == '美食') return Icons.restaurant_rounded;
    if (category == '住宿') return Icons.hotel_rounded;
    return Icons.place_rounded;
  }

  factory PoiMarker.fromAttraction(String id, Map<String, dynamic> j) => PoiMarker(
    id: id,
    name: j['AttractionName']?.toString() ?? '',
    category: '景點',
    lat: (j['PositionLat'] as num).toDouble(),
    lon: (j['PositionLon'] as num).toDouble(),
    address: j['Address']?.toString() ?? '',
    description: j['Description']?.toString() ?? '',
    imageUrl: _firstImageUrl(j['Images']),
    starRating: (j['Star_rating'] as num?)?.toDouble(),
    phone: _firstPhone(j['Telephones']),
    openTime: _parseServiceTime(j['ServiceTimeInfo']),
  );

  factory PoiMarker.fromRestaurant(Map<String, dynamic> j) => PoiMarker(
    id: j['RestaurantID']?.toString() ?? '',
    name: j['RestaurantName']?.toString() ?? '',
    category: '美食',
    lat: (j['PositionLat'] as num).toDouble(),
    lon: (j['PositionLon'] as num).toDouble(),
    address: j['Address']?.toString() ?? '',
    description: j['Description']?.toString() ?? '',
    imageUrl: _firstRestImageUrl(j['Images']),
    phone: _firstPhone(j['Phone']),   // Phone 是 List，用 _firstPhone 統一處理
    openTime: j['OpenTime']?.toString() ?? '',
  );

  static String _firstImageUrl(dynamic images) {
    if (images is List && images.isNotEmpty) {
      final first = images[0];
      if (first is Map) return first['url']?.toString() ?? '';
    }
    return '';
  }

  static String _firstRestImageUrl(dynamic images) {
    if (images is List && images.isNotEmpty) {
      final first = images[0];
      if (first is Map) return first['url']?.toString() ?? first['Url']?.toString() ?? '';
      if (first is String) return first;
    }
    return '';
  }

  static String _firstPhone(dynamic phones) {
    if (phones is List && phones.isNotEmpty) {
      final first = phones[0];
      if (first is Map) {
        return first['phoneNumber']?.toString()   // attractions 用小寫
            ?? first['PhoneNumber']?.toString()   // 保留向後相容
            ?? first['Tel']?.toString()
            ?? '';
      }
      if (first is String) return first;
    }
    if (phones is String) return phones;
    return '';
  }

  static String _parseServiceTime(dynamic serviceTime) {
    if (serviceTime == null) return '';
    final str = serviceTime.toString();
    if (str.isEmpty) return '';
    return str.split('；').first.trim();
  }
}

class ParkingLot {
  final String id;
  final String name;
  final String type;
  final String address;
  final double lat;
  final double lon;
  final int spaceTotal;
  final int? remainingSpace;
  final String fareDescription;
  final int evCharging;
  final int toilet;
  final String telephone;
  final int liveAvailable;
  const ParkingLot({
    required this.id, required this.name, required this.type,
    required this.address, required this.lat, required this.lon,
    required this.spaceTotal, this.remainingSpace,
    required this.fareDescription, required this.evCharging,
    required this.toilet, required this.telephone, required this.liveAvailable,
  });
  factory ParkingLot.fromJson(Map<String, dynamic> j) => ParkingLot(
    id: j['CarParkID']?.toString() ?? '',
    name: j['CarParkName']?.toString() ?? '停車場',
    type: j['CarParkType']?.toString() ?? '',
    address: j['Address']?.toString() ?? '',
    lat: (j['PositionLat'] as num?)?.toDouble() ?? 0.0,
    lon: (j['PositionLon'] as num?)?.toDouble() ?? 0.0,
    spaceTotal: (j['SpaceTotal'] as num?)?.toInt() ?? 0,
    remainingSpace: (j['RemainingSpace'] as num?)?.toInt(),
    fareDescription: j['FareDescription']?.toString() ?? '',
    evCharging: (j['EVRechargingAvailable'] as num?)?.toInt() ?? 0,
    toilet: (j['Toilet'] as num?)?.toInt() ?? 0,
    telephone: j['Telephone']?.toString() ?? '',
    liveAvailable: (j['LiveOccuppancyAvailable'] as num?)?.toInt() ?? 0,
  );
}

class UBikeStation {
  final String uid;
  final String name;
  final double lat;
  final double lon;
  final int availableRent;
  final int availableReturn;
  final int serviceStatus;
  const UBikeStation({
    required this.uid, required this.name,
    required this.lat, required this.lon,
    required this.availableRent, required this.availableReturn,
    required this.serviceStatus,
  });
  factory UBikeStation.fromJson(Map<String, dynamic> j) {
    // ubike.py 已將座標攤平至頂層 PositionLat / PositionLon
    final lat = (j['PositionLat'] as num?)?.toDouble();
    final lon = (j['PositionLon'] as num?)?.toDouble();
    if (lat == null || lon == null) throw const FormatException('missing coords');
    return UBikeStation(
      uid: j['StationUID']?.toString() ?? '',
      name: j['StationName']?.toString() ?? 'YouBike 站',
      lat: lat,
      lon: lon,
      availableRent: (j['AvailableRentBikes'] as num?)?.toInt() ?? 0,
      availableReturn: (j['AvailableReturnBikes'] as num?)?.toInt() ?? 0,
      serviceStatus: (j['ServiceStatus'] as num?)?.toInt() ?? 0,
    );
  }
}

class BusStopRoute {
  final String routeName;
  final int direction;
  final String estimateTime;
  final bool hasBus;
  const BusStopRoute({
    required this.routeName, required this.direction,
    required this.estimateTime, required this.hasBus,
  });
}

class BusStop {
  final String stopId;
  final String stopName;
  final double lat;
  final double lon;
  final List<BusStopRoute> routes;
  const BusStop({
    required this.stopId, required this.stopName,
    required this.lat, required this.lon,
    required this.routes,
  });
}

class BusVehicle {
  final String plateNumb;
  final String routeName;
  final String routeId;
  final int direction;
  final String stopName;
  final String estimateTime;
  final double? busLat;
  final double? busLon;
  final double? azimuth;
  const BusVehicle({
    required this.plateNumb, required this.routeName, required this.routeId,
    required this.direction, required this.stopName, required this.estimateTime,
    this.busLat, this.busLon, this.azimuth,
  });
  factory BusVehicle.fromJson(Map<String, dynamic> j) {
    final busPos = (j['BusPosition'] as Map<String, dynamic>?) ?? {};
    return BusVehicle(
      plateNumb:    j['PlateNumb']?.toString()   ?? '',
      routeName:    j['RouteName']?.toString()   ?? '',
      routeId:      j['RouteID']?.toString()     ?? '',
      direction:    (j['Direction'] as num?)?.toInt() ?? 0,
      stopName:     j['StopName']?.toString()    ?? '',
      estimateTime: j['EstimateTime']?.toString() ?? '',
      busLat:  (busPos['PositionLat'] as num?)?.toDouble(),
      busLon:  (busPos['PositionLon'] as num?)?.toDouble(),
      azimuth: (j['Azimuth'] as num?)?.toDouble(),
    );
  }
}

// 從 bus_realtime.json Routes 清單解析出所有站點
Map<String, BusStop> parseBusStops(List<dynamic> routes) {
  final Map<String, BusStop> map = {};
  for (final route in routes) {
    final rName = route['RouteName']?.toString() ?? '';
    final dir = (route['Direction'] as num?)?.toInt() ?? 0;
    for (final s in (route['Stops'] as List<dynamic>? ?? [])) {
      final sid = s['StopID']?.toString() ?? '';
      final lat = (s['PositionLat'] as num?)?.toDouble();
      final lon = (s['PositionLon'] as num?)?.toDouble();
      if (sid.isEmpty || lat == null || lon == null) continue;
      final sName = s['StopName']?.toString() ?? '';
      final eta = s['EstimateTime']?.toString() ?? '無資料';
      final hasBus = s['HasBus'] == true;
      final r = BusStopRoute(routeName: rName, direction: dir, estimateTime: eta, hasBus: hasBus);
      if (map.containsKey(sid)) {
        final existing = map[sid]!;
        map[sid] = BusStop(
          stopId: existing.stopId, stopName: existing.stopName,
          lat: existing.lat, lon: existing.lon,
          routes: [...existing.routes, r],
        );
      } else {
        map[sid] = BusStop(stopId: sid, stopName: sName, lat: lat, lon: lon, routes: [r]);
      }
    }
  }
  return map;
}

// ── 行程相關型別 ──

enum TransportType { car, transit, bike, walk }

class TransportOption {
  final IconData icon;
  final String label;
  final String time;
  final bool isRecommended;
  TransportOption(this.icon, this.label, this.time, this.isRecommended);
}

class ItineraryItem {
  String time;
  String title;
  String location;
  String duration;
  Map<TransportType, String> transportTimes;
  TransportType selectedTransport;
  List<String> tips;
  String? ticket;
  LatLng mapPosition;
  String category;         // ★ '景點' | '餐廳' | '住宿'
  String transportFrom;    // ★ 從哪裡出發到這站

  ItineraryItem({
    required this.time,
    required this.title,
    required this.location,
    required this.duration,
    required this.transportTimes,
    required this.selectedTransport,
    this.tips = const [],
    this.ticket,
    required this.mapPosition,
    this.category = '景點',
    this.transportFrom = '',
  });
}

class DailyItinerary {
  String dayLabel;
  List<ItineraryItem> items;
  DailyItinerary(this.dayLabel, this.items);
}

class TripPlan {
  String id;            // ★ 唯一 ID，對應 SQLite saved_itineraries.id
  String title;
  int estimatedBudget;
  DateTime startDate;
  DateTime endDate;
  List<DailyItinerary> dailyPlans;

  TripPlan(this.title, this.estimatedBudget, this.startDate, this.endDate, this.dailyPlans, {String? id})
      : id = id ?? const Uuid().v4();
}

// ── 主地圖頁面 ──
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin {

  // ★ 保持 State 存活，切換 Tab 不重建
  @override
  bool get wantKeepAlive => true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _searchController = TextEditingController();
  final MapController _mapController = MapController();

  // 篩選：0=全部 1=景點 2=美食 3=住宿 4=交通
  int _filterIndex = 0;
  final List<String> _filters = ['全部', '景點', '美食', '住宿', '交通'];

  bool _isItineraryMode = false;
  bool _isTopUIHidden = false;
  int _selectedTripIndex = 0;
  int? _selectedMarkerIndex;

  late PageController _tripPageController;

  // 定位
  LatLng? _myLocation;
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<User?>? _authSubscription; // ★ 監聽帳號切換
  bool _isTracking = true;

  // 嘉義中心
  static const LatLng _chiayiCenter = LatLng(23.4800, 120.4500);

  // POI 標記：從 JSON 動態載入（景點 / 美食 / 住宿）
  List<PoiMarker> _poiMarkers = [];
  // ★ 原始 JSON，依 marker.id → raw map，用於開啟詳細資訊頁
  final Map<String, Map<String, dynamic>> _rawAttractionData = {};
  String? _lastProximityAlertSpotId;
  DateTime? _lastProximityAlertTime;
  final Map<String, Map<String, dynamic>> _rawRestaurantData = {};
  final Map<String, Map<String, dynamic>> _rawHotelData = {};
  // ★ 我的收藏狀態快取（避免每次都查 Firestore）
  final Set<String> _favoritedIds = {};

  // 交通資料
  List<ParkingLot> _parkingLots = [];
  List<UBikeStation> _ubikeStations = [];
  Map<String, BusStop> _busStops = {};
  List<BusVehicle> _busVehicles = [];

  // 選中的交通標記  kind: 'parking'|'ubike'|'bus'|'busvehicle'
  String? _selectedTransportKind;
  String? _selectedTransportId;

  // ★ 不再有任何預設假行程，全部從 SQLite 載入
  final List<TripPlan> _itineraries = [];

  // ★ 防止 _loadSavedItineraries 重複執行的旗標
  bool _itinerariesLoaded = false;

  @override
  void initState() {
    super.initState();
    _tripPageController = PageController(viewportFraction: 0.85);
    _startLocationTracking();
    _loadPoiData();
    // ★ 從景點頁導航過來時，飛到指定座標並打標記
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingNavigation());
    _startTransportRefresh();
    // ★ 先載入 DB，再掛 listener，避免 listener 在 DB 尚未 ready 時觸發
    _loadSavedItineraries().then((_) {
      if (!mounted) return;
      AppStateManager.aiItineraryPoiNotifier.addListener(_handleAiItineraryPoi);
      AppStateManager.aiGeneratedTripNotifier.addListener(_handleAiGeneratedTrip);
      // 若 listener 掛上前 notifier 就已有值，立即處理
      if (AppStateManager.aiGeneratedTripNotifier.value != null) {
        _handleAiGeneratedTrip();
      }
    });

    // ★ 監聽帳號切換：登入/登出/換帳號時重新載入行程
    String? _lastUid = FirebaseAuth.instance.currentUser?.uid;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      final newUid = user?.uid;
      // 只有 uid 真正變動才處理（避免 app 啟動時 authStateChanges 初次觸發重複載入）
      if (newUid == _lastUid) return;
      _lastUid = newUid;
      if (!mounted) return;
      // 清空記憶體中的行程 + 重置旗標，再重新從 DB 載入
      setState(() {
        _itineraries.clear();
        _selectedTripIndex = 0;
        _itinerariesLoaded = false;
      });
      // ★ 重登後必須先從 Firebase 把雲端資料同步回本地 DB，
      //   因為登出時 signOut() 會 clearAllData() 清空本地，
      //   不先 sync 就直接載入會永遠撈到空的。
      if (newUid != null) {
        FirebaseSyncService.instance.syncFromFirebase().then((_) {
          if (!mounted) return;
          _loadSavedItineraries();
        });
      } else {
        _loadSavedItineraries();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tripPageController.dispose();
    _mapController.dispose();
    _positionStreamSubscription?.cancel();
    _authSubscription?.cancel(); // ★ 取消帳號監聽
    _transportRefreshTimer?.cancel();
    // removeListener 是 idempotent：若 listener 未被加入也不會 crash
    AppStateManager.aiItineraryPoiNotifier.removeListener(_handleAiItineraryPoi);
    AppStateManager.aiGeneratedTripNotifier.removeListener(_handleAiGeneratedTrip);
    super.dispose();
  }

  // ── AI 自動填入行程 ──
  // 只負責從 notifier 取值後交給 async 方法，避免 void listener 呼叫 async 的問題
  void _handleAiGeneratedTrip() {
    final tripData = AppStateManager.aiGeneratedTripNotifier.value;
    if (tripData == null) return;
    AppStateManager.aiGeneratedTripNotifier.value = null;
    _processAndSaveAiTrip(tripData);
  }

  // ★ 完整的 AI 行程處理：先解析 → 存 DB → 從 DB reload → 更新 UI
  // 這樣即使切換頁面、重新登入，行程都不會消失
  Future<void> _processAndSaveAiTrip(Map<String, dynamic> tripData) async {
    try {
      final title = tripData['title']?.toString() ?? 'AI 嘉義行程';
      final budget = (tripData['estimatedBudget'] as num?)?.toInt() ?? 0;
      final now = DateTime.now();
      final daysData = tripData['days'] as List<dynamic>? ?? [];

      // ── 1. 解析 dailyPlans（用於 map 飛行計算，不直接塞 _itineraries）──
      final List<DailyItinerary> dailyPlans = [];
      for (final d in daysData) {
        final dayLabel = d['dayLabel']?.toString() ?? 'Day 1';
        final rawItems = d['items'] as List<dynamic>? ?? [];
        final List<ItineraryItem> items = rawItems.map((item) {
          final tt = item['transportTimes'] as Map<String, dynamic>? ?? {};
          double lat = (item['lat'] as num?)?.toDouble() ?? 0.0;
          double lon = (item['lon'] as num?)?.toDouble() ?? 0.0;
          final itemTitle = item['title']?.toString() ?? '';
          final itemLocation = item['location']?.toString() ?? '';

          if (lat == 0.0 || lon == 0.0) {
            final matched = _matchPoiCoords(itemTitle) ?? _matchPoiCoords(itemLocation);
            if (matched != null) {
              lat = matched.latitude;
              lon = matched.longitude;
            } else {
              lat = 23.4800;
              lon = 120.4500;
            }
          }

          final rawTips = item['tips'];
          final List<String> tips;
          if (rawTips is List) {
            tips = rawTips
                .where((t) => t != null && t.toString().isNotEmpty)
                .map((t) => t.toString())
                .toList();
          } else {
            tips = [];
          }

          final rawTicket = item['ticket']?.toString();
          final ticket = (rawTicket == null || rawTicket == 'null') ? null : rawTicket;

          return ItineraryItem(
            time: item['time']?.toString() ?? '09:00',
            title: itemTitle,
            location: itemLocation,
            duration: item['duration']?.toString() ?? '1 小時',
            transportTimes: {
              TransportType.car:     tt['car']?.toString()     ?? '10min',
              TransportType.transit: tt['transit']?.toString() ?? '15min',
              TransportType.bike:    tt['bike']?.toString()    ?? '15min',
              TransportType.walk:    tt['walk']?.toString()    ?? '25min',
            },
            selectedTransport: TransportType.values.firstWhere(
                  (t) => t.name == (item['selectedTransport']?.toString() ?? 'transit'),
              orElse: () => TransportType.transit,
            ),
            tips: tips,
            ticket: ticket,
            mapPosition: LatLng(lat, lon),
            category: item['category']?.toString() ?? '景點',
            transportFrom: item['transport_from']?.toString() ?? '',
          );
        }).toList();
        dailyPlans.add(DailyItinerary(dayLabel, items));
      }

      // ── 2. 將 dailyPlans 序列化成符合 _parseSavedItineraries 期望的格式 ──
      final plansForDb = dailyPlans.map((day) => {
        'dayLabel': day.dayLabel,
        'items': day.items.map((item) => {
          'time':     item.time,
          'title':    item.title,
          'location': item.location,
          'category': item.category,
          'duration': item.duration,
          'transport_from': item.transportFrom,
          'transportTimes': {
            'car':     item.transportTimes[TransportType.car]     ?? '10min',
            'transit': item.transportTimes[TransportType.transit] ?? '15min',
            'bike':    item.transportTimes[TransportType.bike]    ?? '15min',
            'walk':    item.transportTimes[TransportType.walk]    ?? '25min',
          },
          'selectedTransport': item.selectedTransport.name,
          'tips':   item.tips,
          'ticket': item.ticket,
          'lat':    item.mapPosition.latitude,
          'lon':    item.mapPosition.longitude,
        }).toList(),
      }).toList();

      // ── 3. ★ await 存入 DB（本地 + Firebase），這一步完成才繼續 ──
      await ItinerarySaveService.instance.saveManualItinerary(
        title: title,
        estimatedBudget: budget,
        startDate: now,
        endDate: now.add(Duration(days: math.max(0, dailyPlans.length - 1))),
        plans: plansForDb,
        userId: _currentUid,   // ★ 帶入 uid
      );
      debugPrint('✅ AI 行程已寫入 DB：$title');

      // ── 4. ★ await 從 DB 重新載入，確保 _itineraries 內容與 DB 完全一致 ──
      await _reloadItinerariesFromDb();

      if (!mounted) return;

      // ── 5. 選中剛加入的行程（index 0，因為 DB 按 updated_at DESC 排序）──
      setState(() {
        _selectedTripIndex = 0;
        _isItineraryMode = true;
        _selectedMarkerIndex = null;
        _selectedTransportKind = null;
        _isTopUIHidden = false;
      });

      // ── 6. 地圖飛行 ──
      final allPos = dailyPlans
          .expand((d) => d.items)
          .map((e) => e.mapPosition)
          .where((p) => !(p.latitude == 23.4800 && p.longitude == 120.4500))
          .toList();

      if (allPos.isNotEmpty) {
        if (allPos.length == 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try { _mapController.move(allPos.first, 14.5); } catch (_) {}
          });
        } else {
          final minLat = allPos.map((p) => p.latitude).reduce(math.min);
          final maxLat = allPos.map((p) => p.latitude).reduce(math.max);
          final minLon = allPos.map((p) => p.longitude).reduce(math.min);
          final maxLon = allPos.map((p) => p.longitude).reduce(math.max);
          final centerLat = (minLat + maxLat) / 2;
          final centerLon = (minLon + maxLon) / 2;
          final latSpan = maxLat - minLat;
          final lonSpan = maxLon - minLon;
          final span = math.max(latSpan, lonSpan);
          double zoom = 14.0;
          if (span > 0.5) zoom = 11.0;
          else if (span > 0.2) zoom = 12.0;
          else if (span > 0.05) zoom = 13.0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try { _mapController.move(LatLng(centerLat, centerLon), zoom); } catch (_) {}
          });
        }
      }

      // ── 7. SnackBar 通知 ──
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🗺️「$title」已儲存，共 ${allPos.length} 個景點已標記在地圖上！',
              style: const TextStyle(fontFamily: 'MyCustomFont'),
            ),
            backgroundColor: const Color(0xFF8BAA88),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: '查看詳情',
              textColor: Colors.white,
              onPressed: () {
                if (_itineraries.isNotEmpty) {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => ItineraryDetailScreen(
                      tripPlan: _itineraries[0],
                      onSaved: _reloadItinerariesFromDb,
                    ),
                  )).then((_) { if (mounted) _reloadItinerariesFromDb(); });
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ AI 行程儲存失敗：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ 行程儲存失敗，請重試：$e',
                style: const TextStyle(fontFamily: 'MyCustomFont')),
            backgroundColor: const Color(0xFFD97B2A),
          ),
        );
      }
    }
  }

  /// 從已載入的 POI 標記中模糊匹配景點座標
  LatLng? _matchPoiCoords(String text) {
    if (text.isEmpty) return null;
    final query = text.length >= 4 ? text.substring(0, 4) : text;
    for (final m in _poiMarkers) {
      if (m.name.contains(query) || query.contains(m.name.substring(0, math.min(m.name.length, 4)))) {
        return LatLng(m.lat, m.lon);
      }
    }
    return null;
  }

  // ── AI 景點監聽 ──
  void _handleAiItineraryPoi() {
    final pois = AppStateManager.aiItineraryPoiNotifier.value;
    if (pois == null || pois.isEmpty) return;
    AppStateManager.aiItineraryPoiNotifier.value = null;

    final firstPoi = pois.first;
    final name = firstPoi['AttractionName']?.toString() ?? '';

    final matched = _poiMarkers.where((m) => m.name == name).toList();
    if (matched.isNotEmpty) {
      final marker = matched.first;
      _mapController.move(LatLng(marker.lat, marker.lon), 15);
      setState(() {
        _selectedMarkerIndex = _poiMarkers.indexOf(marker);
      });
    } else {
      final lat = (firstPoi['PositionLat'] as num?)?.toDouble();
      final lon = (firstPoi['PositionLon'] as num?)?.toDouble();
      if (lat != null && lon != null) {
        _mapController.move(LatLng(lat, lon), 15);
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已跳轉至「$name」📍 可加入行程',
              style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: const Color(0xFF8BAA88),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: '切換行程模式',
            textColor: Colors.white,
            onPressed: () => setState(() => _isItineraryMode = true),
          ),
        ),
      );
    }
  }

  // ═══ 共用：將 SavedItinerary 清單解析成 TripPlan 清單 ═══
  List<TripPlan> _parseSavedItineraries(List<SavedItinerary> saved) {
    final List<TripPlan> plans = [];
    for (final s in saved) {
      try {
        final plansData = json.decode(s.plansJson) as List<dynamic>;
        final dailyPlans = plansData.map((d) {
          final rawItems = (d['items'] as List<dynamic>? ?? []);
          final items = rawItems.map((item) {
            final tt = item['transportTimes'];
            final Map<String, String> tTimes;
            if (tt is Map) {
              tTimes = {
                'car':     tt['car']?.toString()     ?? '10min',
                'transit': tt['transit']?.toString() ?? '15min',
                'bike':    tt['bike']?.toString()    ?? '15min',
                'walk':    tt['walk']?.toString()    ?? '25min',
              };
            } else {
              tTimes = {'car': '10min', 'transit': '15min', 'bike': '15min', 'walk': '25min'};
            }
            final rawTips = item['tips'];
            final List<String> tips;
            if (rawTips is List) {
              tips = rawTips.where((t) => t != null && t.toString().isNotEmpty).map((t) => t.toString()).toList();
            } else if (rawTips is String && rawTips.isNotEmpty) {
              tips = [rawTips];
            } else {
              tips = [];
            }
            final rawTicket = item['ticket']?.toString();
            final ticket = (rawTicket == null || rawTicket == 'null') ? null : rawTicket;
            final selTransStr = item['selectedTransport']?.toString() ?? item['transport']?.toString() ?? 'transit';
            final rawCategory = item['category']?.toString() ?? item['type']?.toString() ?? item['kind']?.toString() ?? '景點';
            final safeCategory = ['景點','餐廳','住宿'].contains(rawCategory) ? rawCategory : '景點';
            return ItineraryItem(
              time:     item['time']?.toString()     ?? '09:00',
              title:    item['title']?.toString()    ?? '景點',
              location: item['location']?.toString() ?? '',
              duration: item['duration']?.toString() ?? '1 小時',
              transportTimes: {
                TransportType.car:     tTimes['car']!,
                TransportType.transit: tTimes['transit']!,
                TransportType.bike:    tTimes['bike']!,
                TransportType.walk:    tTimes['walk']!,
              },
              selectedTransport: TransportType.values.firstWhere(
                      (t) => t.name == selTransStr, orElse: () => TransportType.transit),
              tips:   tips,
              ticket: ticket,
              mapPosition: LatLng(
                (item['lat'] as num?)?.toDouble() ?? 23.4800,
                (item['lon'] as num?)?.toDouble() ?? 120.4500,
              ),
              category:      safeCategory,
              transportFrom: item['transport_from']?.toString() ?? '',
            );
          }).toList();
          return DailyItinerary(d['dayLabel']?.toString() ?? 'Day 1', items);
        }).toList();
        plans.add(TripPlan(s.title, s.estimatedBudget, s.startDate, s.endDate, dailyPlans, id: s.id));
      } catch (e) {
        debugPrint('⚠️ 解析行程失敗 [${s.id}]：$e');
      }
    }
    return plans;
  }

  // ★ 取目前登入帳號 uid，未登入回空字串（訪客）
  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  // ═══ 首次載入：App 啟動時從 DB 讀取所有行程 ═══
  Future<void> _loadSavedItineraries() async {
    if (_itinerariesLoaded) return;
    _itinerariesLoaded = true;
    await _reloadItinerariesFromDb();
  }

  // ═══ 完整重新載入（新增/刪除/AI 行程寫入 DB 後呼叫）═══
  Future<void> _reloadItinerariesFromDb() async {
    try {
      // ★ 帶入 uid，只撈這個帳號的行程
      final saved = await LocalDbService.instance.getAllItineraries(userId: _currentUid);
      if (!mounted) return;
      final loadedPlans = _parseSavedItineraries(saved);
      setState(() {
        _itineraries
          ..clear()
          ..addAll(loadedPlans);
        if (_selectedTripIndex >= _itineraries.length) {
          _selectedTripIndex = _itineraries.isEmpty ? 0 : _itineraries.length - 1;
        }
      });
      debugPrint('✅ 從 DB 載入 ${loadedPlans.length} 筆行程（uid=$_currentUid）');
    } catch (e) {
      debugPrint('⚠️ _reloadItinerariesFromDb 失敗：$e');
    }
  }


  Future<void> _loadPoiData() async {
    final loaded = <PoiMarker>[];

    // 景點
    try {
      final raw = await rootBundle.loadString('assets/data/attractions_fixed_final.json');
      final Map<String, dynamic> map = json.decode(raw);
      for (final entry in map.entries) {
        try {
          final j = entry.value as Map<String, dynamic>;
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final marker = PoiMarker.fromAttraction(entry.key, j);
          loaded.add(marker);
          _rawAttractionData[marker.id] = j; // ★ 快取原始資料
        } catch (e) {
          debugPrint('❌ 單筆景點解析錯誤: $e');
        }
      }
    } catch (e) {
      debugPrint('🚨 找不到景點 JSON 檔案，請檢查 pubspec.yaml！錯誤訊息：$e');
    }

    // 餐廳
    try {
      final raw = await rootBundle.loadString('assets/data/app_restaurants.json');
      final List<dynamic> list = json.decode(raw);
      for (final e in list) {
        try {
          final j = e as Map<String, dynamic>;
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final marker = PoiMarker.fromRestaurant(j);
          loaded.add(marker);
          _rawRestaurantData[marker.id] = j; // ★ 快取原始資料
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('🚨 找不到餐廳 JSON 檔案！錯誤訊息：$e');
    }

    // 住宿
    try {
      final raw = await rootBundle.loadString('assets/data/app_hotels.json');
      final List<dynamic> list = json.decode(raw);
      for (final e in list) {
        try {
          final j = e as Map<String, dynamic>;
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final phone = j['Phone']?.toString() ?? '';
          final hotelId = j['HotelID']?.toString() ?? '';
          final hotelMarker = PoiMarker(
            id: hotelId,
            name: j['HotelName']?.toString() ?? '住宿',
            category: '住宿',
            lat: lat,
            lon: lon,
            address: j['Address']?.toString() ?? '',
            description: j['Description']?.toString() ?? '',
            imageUrl: (j['Picture'] as Map<String, dynamic>?)?['PictureUrl1']?.toString() ?? '',
            phone: phone,
          );
          loaded.add(hotelMarker);
          _rawHotelData[hotelId] = j; // ★ 快取原始資料
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('🚨 找不到住宿 JSON 檔案！錯誤訊息：$e');
    }
    // ★ 初始化時載入已收藏的 POI
    _loadFavoritedIds();

    final attractions = loaded.where((m) => m.category == '景點').length;
    final restaurants = loaded.where((m) => m.category == '美食').length;
    final hotels     = loaded.where((m) => m.category == '住宿').length;
    debugPrint('✅ POI 載入完成：景點 $attractions 筆，美食 $restaurants 筆，住宿 $hotels 筆，共 ${loaded.length} 筆');

    setState(() => _poiMarkers = loaded);
  }

  // ── 載入交通資料 ──
  //   停車場 / YouBike：從 assets 靜態 JSON 載入（不打 API，不限流）
  //   公車：仍從 Python server 抓即時資料（有動態資訊）
  final _api = TrafficApiService();
  Timer? _transportRefreshTimer;

  /// 解包 server _wrap 格式：list → 直接取；map → 取 "data" key
  List<dynamic> _unwrapList(dynamic raw) {
    if (raw is List) return raw;
    if (raw is Map) {
      final data = raw['data'];
      if (data is List) return data;
    }
    return [];
  }

  Future<void> _loadStaticTransportData() async {
    // ── 停車場：從 assets 靜態 JSON 載入 ──
    try {
      final raw = await rootBundle.loadString('assets/data/parking_static.json');
      final list = json.decode(raw) as List<dynamic>;
      final lots = <ParkingLot>[];
      for (final e in list) {
        try {
          final p = ParkingLot.fromJson(e as Map<String, dynamic>);
          if (p.lat != 0.0 && p.lon != 0.0) lots.add(p);
        } catch (_) {}
      }
      if (mounted) setState(() => _parkingLots = lots);
      debugPrint('✅ 靜態停車場載入完成：${lots.length} 座');
    } catch (e) {
      debugPrint('⚠️ 停車場靜態 JSON 載入失敗：$e（請先執行 car_static.py）');
    }

    // ── YouBike：從 assets 靜態 JSON 載入 ──
    try {
      final raw = await rootBundle.loadString('assets/data/ubike_static.json');
      final list = json.decode(raw) as List<dynamic>;
      final stations = <UBikeStation>[];
      for (final e in list) {
        try {
          final s = UBikeStation.fromJson(e as Map<String, dynamic>);
          stations.add(s);
        } catch (_) {}
      }
      if (mounted) setState(() => _ubikeStations = stations);
      debugPrint('✅ 靜態 YouBike 載入完成：${stations.length} 站');
    } catch (e) {
      debugPrint('⚠️ YouBike 靜態 JSON 載入失敗：$e（請先執行 ubike_static.py）');
    }
  }

  Future<void> _loadTransportData() async {
    // ── 公車：從 Python server 抓即時資料 ──
    // server 的 _wrap 對 bus（dict 格式）會直接把 Routes/Vehicles 放在頂層
    // 格式：{ "Vehicles": [...], "Routes": [...], "_cache": {...} }
    try {
      final rawBus = await _api.getRaw('/api/bus');
      if (rawBus is Map) {
        // 公車是 dict 格式，_wrap 直接加 _cache 到頂層，Routes/Vehicles 還在原位
        final routes   = rawBus['Routes']   as List<dynamic>? ?? [];
        final vehicles = rawBus['Vehicles'] as List<dynamic>? ?? [];
        final loadedVehicles = <BusVehicle>[];
        for (final v in vehicles) {
          try {
            final bv = BusVehicle.fromJson(v as Map<String, dynamic>);
            if (bv.busLat != null && bv.busLon != null) loadedVehicles.add(bv);
          } catch (_) {}
        }
        if (mounted) setState(() {
          _busStops   = parseBusStops(routes);
          _busVehicles = loadedVehicles;
        });
      }
    } catch (_) {}
  }

  void _startTransportRefresh() {
    // 靜態資料只需載入一次
    _loadStaticTransportData();
    // 公車即時資料定期刷新
    _loadTransportData();
    _transportRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
          (_) => _loadTransportData(),
    );
  }

  // ── GPS 定位 ──
  Future<void> _startLocationTracking() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return Future.error('定位服務已停用。');

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return Future.error('定位權限被拒絕。');
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error('定位權限被永久拒絕，無法請求權限。');
    }

    Position initialPosition = await Geolocator.getCurrentPosition();
    if (mounted) {
      setState(() => _myLocation = LatLng(initialPosition.latitude, initialPosition.longitude));
    }

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1,
    );

    _positionStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position? position) {
        if (position != null && mounted) {
          setState(() => _myLocation = LatLng(position.latitude, position.longitude));
          if (_isTracking) {
            try {
              _mapController.move(_myLocation!, _mapController.camera.zoom);
            } catch (e) {}
          }
          _checkProximityToAttractions(position);
        }
      },
    );
  }

  void _zoomMap(double zoomDelta) {
    try {
      _mapController.move(_mapController.camera.center, _mapController.camera.zoom + zoomDelta);
    } catch (e) {}
  }


  // ★ 載入收藏狀態
  Future<void> _loadFavoritedIds() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('favorites').get();
      if (mounted) setState(() {
        _favoritedIds.clear();
        _favoritedIds.addAll(snap.docs.map((d) => d.id));
      });
    } catch (_) {}
  }

  // ★ 切換收藏
  Future<void> _togglePoiFavorite(PoiMarker m) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final docId = 'poi_${m.id}';
    final isFav = _favoritedIds.contains(docId);
    final ref = FirebaseFirestore.instance.collection('users').doc(uid).collection('favorites').doc(docId);
    try {
      if (isFav) {
        await ref.delete();
        if (mounted) setState(() => _favoritedIds.remove(docId));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已從收藏移除', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFF9E7B6B), behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      } else {
        final typeLabel = m.category == '景點' ? '景點' : m.category == '美食' ? '美食' : '住宿';
        await ref.set({
          'id': docId, 'type': typeLabel, 'title': m.name,
          'sub': m.address.isNotEmpty ? m.address : m.category,
          'image': m.imageUrl, 'score': m.starRating?.toString() ?? '5.0',
          'tags': [typeLabel], 'desc': m.description, 'createdAt': DateTime.now().toIso8601String(),
        });
        if (mounted) setState(() => _favoritedIds.add(docId));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ 已加入收藏！可在「我的收藏」→「${m.category}」查看', style: const TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: const Color(0xFF8BAA88), behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ));
      }
    } catch (e) {
      debugPrint('收藏操作失敗: $e');
    }
  }

  // ★ 開啟詳細資訊頁（依 category 判斷）
  // ── 共用的圖片 URL 列表解析 ──
  List<String> _extractImageUrls(Map<String, dynamic> raw, String fallback) {
    final List<String> urls = [];
    final images = raw['Images'];
    if (images is List) {
      for (final img in images) {
        final url = img is Map
            ? img['url']?.toString() ?? img['Url']?.toString() ?? ''
            : img.toString();
        if (url.isNotEmpty) urls.add(url);
      }
    }
    // 住宿 Picture map
    final pic = raw['Picture'] as Map<String, dynamic>?;
    if (pic != null) {
      for (int i = 1; i <= 5; i++) {
        final u = pic['PictureUrl$i']?.toString() ?? '';
        if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
      }
    }
    if (urls.isEmpty && fallback.isNotEmpty) urls.add(fallback);
    return urls;
  }

  void _openPoiDetail(PoiMarker m) {
    if (m.category == '景點') {
      final raw = _rawAttractionData[m.id];
      final imageUrls = raw != null
          ? _extractImageUrls(raw, m.imageUrl)
          : (m.imageUrl.isNotEmpty ? [m.imageUrl] : <String>[]);
      final model = AttractionModel(
        name: m.name,
        shortDesc: m.description.length > 60
            ? '${m.description.substring(0, 60)}…' : m.description,
        rating: m.starRating?.toString() ?? '',
        hasAI: false,
        tags: (raw?['tags'] as List?)?.map((t) => t.toString()).toList() ?? [],
        images: imageUrls,
        imageBase64: raw?['ImageBase64']?.toString() ?? '', // ✨ 補上這行接住 Base64 字串！
        fullDesc: m.description,
        infoTime: m.openTime,
        infoLoc: m.address,
        infoTrans: raw?['TransportationInfo']?.toString() ?? '',
        comments: [],
        quizzes: [],
      );
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => AttractionDetailScreen(spotData: model)));

    } else if (m.category == '美食') {
      final raw = _rawRestaurantData[m.id];
      final imageUrls = raw != null
          ? _extractImageUrls(raw, m.imageUrl)
          : (m.imageUrl.isNotEmpty ? [m.imageUrl] : <String>[]);
      // 解析 tags from serviceTime
      final serviceTime = raw?['ServiceTimeInfo']?.toString() ?? '';
      final tags = serviceTime.isNotEmpty
          ? serviceTime.split('；').take(3).map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
          : <String>[];
      final priceStr = raw?['TicketInfo']?.toString() ?? '';
      final parsedPrice = int.tryParse(
          priceStr.replaceAll(RegExp(r'[^0-9]'), '').isNotEmpty
              ? priceStr.replaceAll(RegExp(r'[^0-9]'), '')
              : '0') ?? 0;
      final model = FoodModel(
        name: m.name,
        shortDesc: m.description.length > 60
            ? '${m.description.substring(0, 60)}…' : m.description,
        location: m.address,
        price: priceStr,
        parsedPrice: parsedPrice,
        distance: '',
        phone: m.phone,
        category: raw?['Class']?.toString() ?? '餐廳',
        serviceTime: serviceTime,
        websiteUrl: raw?['WebsiteUrl']?.toString() ?? '',
        images: imageUrls,
        tags: tags,
        recommendedDishes: const [],
        fullDesc: m.description,
        othersComments: [],
        hasImage: imageUrls.isNotEmpty,
      );
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => FoodDetailScreen(foodData: model)));

    } else if (m.category == '住宿') {
      final raw = _rawHotelData[m.id];
      final imageUrls = raw != null
          ? _extractImageUrls(raw, m.imageUrl)
          : (m.imageUrl.isNotEmpty ? [m.imageUrl] : <String>[]);
      final model = HotelModel(
        name: m.name,
        desc: m.description,
        address: m.address,
        phone: m.phone,
        price: (raw?['LowestPrice'] as num?)?.toInt() ?? 0,
        rating: m.starRating?.toString() ?? '',
        tags: (raw?['Class'] != null) ? [raw!['Class'].toString()] : [],
        images: imageUrls,
        imageBase64: raw?['ImageBase64']?.toString() ?? '',
        facilities: const [],
        rooms: const [],
        comments: [],
        category: raw?['Class']?.toString() ?? '飯店',
        checkTimeInfo: raw?['CheckTimeInfo']?.toString() ?? '',
        websiteUrl: raw?['WebsiteUrl']?.toString() ?? '',
      );
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => HotelDetailScreen(hotel: model)));
    }
  }

  /// 輕量 POI 詳情頁（美食 & 住宿共用，不依賴外部 FoodModel/HotelModel）
  void _showPoiMiniDetail(PoiMarker m) {
    final raw = m.category == '美食'
        ? _rawRestaurantData[m.id]
        : m.category == '住宿' ? _rawHotelData[m.id] : null;

    // 取圖片列表
    List<String> imageUrls = [if (m.imageUrl.isNotEmpty) m.imageUrl];
    if (raw != null) {
      final imgs = raw['Images'];
      if (imgs is List) {
        for (final img in imgs) {
          final url = img is Map
              ? img['url']?.toString() ?? img['Url']?.toString() ?? ''
              : img.toString();
          if (url.isNotEmpty && !imageUrls.contains(url)) imageUrls.add(url);
        }
      }
      final pic = raw['Picture'] as Map<String, dynamic>?;
      if (pic != null) {
        for (int i = 1; i <= 5; i++) {
          final u = pic['PictureUrl$i']?.toString() ?? '';
          if (u.isNotEmpty && !imageUrls.contains(u)) imageUrls.add(u);
        }
      }
    }

    final rating = m.starRating != null ? m.starRating!.toStringAsFixed(1) : '';
    final price = raw?['LowestPrice']?.toString() ??
        raw?['TicketInfo']?.toString() ?? '';
    final phone = m.phone;
    final address = m.address;
    final openTime = m.openTime;
    final desc = m.description;
    final tags = (raw?['tags'] as List?)?.map((t) => t.toString()).toList() ?? <String>[];

    Navigator.push(context, MaterialPageRoute(builder: (_) =>
        _PoiMiniDetailScreen(
          marker: m,
          imageUrls: imageUrls,
          rating: rating,
          price: price,
          phone: phone,
          address: address,
          openTime: openTime,
          desc: desc,
          tags: tags,
        )));
  }


  // ★ 從景點頁點「導航」後，飛到指定座標並加一個臨時標記
  void _handlePendingNavigation() {
    final name = NavTarget.pendingName;
    final lat = NavTarget.pendingLat;
    final lon = NavTarget.pendingLon;
    if (name == null || lat == null || lon == null) return;
    // 清除，避免下次重入
    NavTarget.pendingName = null;
    NavTarget.pendingLat = null;
    NavTarget.pendingLon = null;

    // 飛到目標
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapController.move(LatLng(lat, lon), 16.0);
      } catch (_) {}
    });

    // 顯示 SnackBar 告知
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('📍 已移動到「$name」的位置', style: const TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: const Color(0xFF8BAA88),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ));
    }
  }


  void _checkProximityToAttractions(Position pos) {
    if (_poiMarkers.isEmpty) return;
    final now = DateTime.now();
    if (_lastProximityAlertTime != null && now.difference(_lastProximityAlertTime!).inSeconds < 60) return;
    for (final m in _poiMarkers) {
      if (m.category != '景點') continue;
      final dist = Geolocator.distanceBetween(pos.latitude, pos.longitude, m.lat, m.lon);
      if (dist <= 100 && m.id != _lastProximityAlertSpotId) {
        _lastProximityAlertSpotId = m.id;
        _lastProximityAlertTime = now;
        // ★ 先檢查用戶是否關閉景點接近提醒
        SystemSettingsScreen.isNotifyEnabled(SystemSettingsScreen.kNotifyProximity).then((enabled) {
          if (enabled && mounted) _showProximityAlert(m);
        });
        break;
      }
    }
  }

  void _showProximityAlert(PoiMarker m) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent, isDismissible: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, -8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          Row(children: [
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.12), shape: BoxShape.circle),
                child: const Icon(Icons.location_on_rounded, color: Color(0xFF8BAA88), size: 26)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('你靠近景點了！📍', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(m.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            ])),
          ]),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () { Navigator.pop(ctx); _openPoiDetail(m); },
            icon: const Icon(Icons.record_voice_over_rounded, color: Colors.white, size: 20),
            label: const Text('AI 語音導覽', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), padding: const EdgeInsets.symmetric(vertical: 14), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          )),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: () { Navigator.pop(ctx); _openPoiDetail(m); },
            icon: const Icon(Icons.workspace_premium_rounded, color: Color(0xFF8BAA88), size: 20),
            label: const Text('知識打卡集章', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), side: const BorderSide(color: Color(0xFF8BAA88), width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          )),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍後再說', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey))),
        ]),
      ),
    );
  }

  void _clearSelection() {
    setState(() {
      _selectedMarkerIndex = null;
      _selectedTransportKind = null;
      _selectedTransportId = null;
    });
  }

  /// 開啟 Google Maps 導航（不需要 url_launcher 套件）
  /// 透過 Flutter 的 MethodChannel 呼叫原生 Android Intent
  Future<void> _launchNavigation(double lat, double lon, String label) async {
    const channel = MethodChannel('com.alibuda/maps');
    try {
      await channel.invokeMethod('openNavigation', {
        'lat': lat,
        'lon': lon,
        'label': label,
      });
    } on PlatformException {
      // fallback: 顯示 SnackBar 提示手動搜尋
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('請在地圖應用搜尋：$label',
              style: const TextStyle(fontFamily: 'MyCustomFont')),
          action: SnackBarAction(
            label: '知道了',
            onPressed: () {},
          ),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('座標：$lat, $lon',
              style: const TextStyle(fontFamily: 'MyCustomFont')),
        ));
      }
    }
  }

  // ── 建立多天行程的分色 Polyline 連線 ──
  List<PolylineLayer> _buildDayPolylines() {
    if (_itineraries.isEmpty) return [];
    final plan = _itineraries[_selectedTripIndex];
    final dayColors = [
      const Color(0xFF8BAA88),
      const Color(0xFF7FA3B0),
      const Color(0xFFD4956A),
      const Color(0xFF9B8EC4),
      const Color(0xFFCE7D7D),
    ];
    final layers = <PolylineLayer>[];
    for (int i = 0; i < plan.dailyPlans.length; i++) {
      final pts = plan.dailyPlans[i].items.map((e) => e.mapPosition).toList();
      if (pts.length < 2) continue;
      layers.add(PolylineLayer(polylines: [
        Polyline(
          points: pts,
          color: dayColors[i % dayColors.length].withOpacity(0.8),
          strokeWidth: 3.5,
          isDotted: true,
        ),
      ]));
    }
    return layers;
  }

  // ── 建立地圖 Markers ──
  List<Marker> _buildFlutterMarkers() {
    final markers = <Marker>[];
    final q = _searchController.text.toLowerCase();

    if (_isItineraryMode) {
      if (_itineraries.isEmpty) return markers;
      final plan = _itineraries[_selectedTripIndex];

      // 每天用不同的顏色標記
      final dayColors = [
        const Color(0xFF8BAA88),  // Day 1 - 綠
        const Color(0xFF7FA3B0),  // Day 2 - 藍
        const Color(0xFFD4956A),  // Day 3 - 橙
        const Color(0xFF9B8EC4),  // Day 4 - 紫
        const Color(0xFFCE7D7D),  // Day 5 - 紅
      ];

      int globalIndex = 0;
      for (int dayIdx = 0; dayIdx < plan.dailyPlans.length; dayIdx++) {
        final day = plan.dailyPlans[dayIdx];
        final dayColor = dayColors[dayIdx % dayColors.length];

        for (int itemIdx = 0; itemIdx < day.items.length; itemIdx++) {
          final item = day.items[itemIdx];
          final seqNum = globalIndex + 1;
          globalIndex++;

          markers.add(Marker(
            point: item.mapPosition,
            width: 80,
            height: 72,
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {
                // 跳到行程詳情
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => ItineraryDetailScreen(
                    tripPlan: plan,
                    onSaved: _reloadItinerariesFromDb,
                  ),
                )).then((_) { if (mounted) _reloadItinerariesFromDb(); });
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 景點名稱小標籤
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: dayColor.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [BoxShadow(color: dayColor.withOpacity(0.3), blurRadius: 4)],
                    ),
                    child: Text(
                      item.title.length > 8 ? '${item.title.substring(0, 8)}…' : item.title,
                      style: const TextStyle(
                        fontFamily: 'MyCustomFont',
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 圓形序號
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: dayColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: dayColor.withOpacity(0.5),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '$seqNum',
                        style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  // 小箭頭針腳
                  Container(
                    width: 2,
                    height: 6,
                    color: dayColor,
                  ),
                ],
              ),
            ),
          ));
        }
      }
    } else {
      // ─── POI 標記（景點/美食/住宿）───
      // 顯示條件：篩選「全部」或篩選 1~3
      final showPoi = _filterIndex == 0 || (_filterIndex >= 1 && _filterIndex <= 3);
      if (showPoi) {
        for (int i = 0; i < _poiMarkers.length; i++) {
          final m = _poiMarkers[i];
          if (q.isNotEmpty && !m.name.toLowerCase().contains(q)) continue;
          // 篩選 1~3 時，只顯示對應分類
          if (_filterIndex == 1 && m.category != '景點') continue;
          if (_filterIndex == 2 && m.category != '美食') continue;
          if (_filterIndex == 3 && m.category != '住宿') continue;

          final isSel = _selectedMarkerIndex == i;
          markers.add(Marker(
            point: LatLng(m.lat, m.lon),
            width: isSel ? 60 : 44,
            height: isSel ? 70 : 54,
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedMarkerIndex = i;
                  _selectedTransportKind = null;
                  _selectedTransportId = null;
                });
                _mapController.move(LatLng(m.lat, m.lon), 15.5);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: EdgeInsets.all(isSel ? 12 : 8),
                    decoration: BoxDecoration(
                      color: isSel ? m.markerColor : Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: m.markerColor, width: 2),
                      boxShadow: [if (isSel) BoxShadow(color: m.markerColor.withOpacity(0.5), blurRadius: 15, spreadRadius: 2)],
                    ),
                    child: Icon(m.markerIcon, color: isSel ? Colors.white : m.markerColor, size: isSel ? 22 : 17),
                  ),
                  Container(width: 2, height: isSel ? 12 : 8, color: m.markerColor),
                ],
              ),
            ),
          ));
        }
      }

      // ─── 交通標記（篩選「全部」或「交通」）───
      final showTransport = _filterIndex == 0 || _filterIndex == 4;
      if (showTransport) {
        _buildParkingMarkers(markers, q);
        _buildUBikeMarkers(markers, q);
        _buildBusMarkers(markers, q);
        _buildBusVehicleMarkers(markers, q);
      }
    }

    // GPS 藍點
    if (!_isItineraryMode && _myLocation != null) {
      markers.add(Marker(
        point: _myLocation!,
        width: 22, height: 22,
        alignment: Alignment.center,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFA5CBD4),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [BoxShadow(color: const Color(0xFFA5CBD4).withOpacity(0.4), blurRadius: 15, spreadRadius: 5)],
            ),
          ),
        ),
      ));
    }

    return markers;
  }

  void _buildParkingMarkers(List<Marker> out, String q) {
    const color = Color(0xFF4A90D9);
    for (final p in _parkingLots) {
      if (q.isNotEmpty && !p.name.toLowerCase().contains(q)) continue;
      final pt = LatLng(p.lat, p.lon);
      final isSel = _selectedTransportKind == 'parking' && _selectedTransportId == p.id;
      out.add(Marker(
        point: pt,
        width: isSel ? 56 : 40,
        height: isSel ? 66 : 50,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedMarkerIndex = null;
              _selectedTransportKind = 'parking';
              _selectedTransportId = p.id;
            });
            _mapController.move(pt, 16.0);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.all(isSel ? 11 : 7),
                decoration: BoxDecoration(
                  color: isSel ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                  boxShadow: [if (isSel) BoxShadow(color: color.withOpacity(0.45), blurRadius: 12, spreadRadius: 2)],
                ),
                child: Icon(Icons.local_parking_rounded, color: isSel ? Colors.white : color, size: isSel ? 20 : 15),
              ),
              Container(width: 2, height: 8, color: color),
            ],
          ),
        ),
      ));
    }
  }

  void _buildUBikeMarkers(List<Marker> out, String q) {
    const color = Color(0xFF2E9E58);
    for (final s in _ubikeStations) {
      if (q.isNotEmpty && !s.name.toLowerCase().contains(q)) continue;
      final pt = LatLng(s.lat, s.lon);
      final isSel = _selectedTransportKind == 'ubike' && _selectedTransportId == s.uid;
      out.add(Marker(
        point: pt,
        width: isSel ? 56 : 40,
        height: isSel ? 66 : 50,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedMarkerIndex = null;
              _selectedTransportKind = 'ubike';
              _selectedTransportId = s.uid;
            });
            _mapController.move(pt, 16.0);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.all(isSel ? 11 : 7),
                decoration: BoxDecoration(
                  color: isSel ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                  boxShadow: [if (isSel) BoxShadow(color: color.withOpacity(0.45), blurRadius: 12, spreadRadius: 2)],
                ),
                child: Icon(Icons.pedal_bike_rounded, color: isSel ? Colors.white : color, size: isSel ? 20 : 15),
              ),
              Container(width: 2, height: 8, color: color),
            ],
          ),
        ),
      ));
    }
  }

  void _buildBusMarkers(List<Marker> out, String q) {
    const color = Color(0xFFD97B2A);
    for (final entry in _busStops.entries) {
      final bs = entry.value;
      if (q.isNotEmpty && !bs.stopName.toLowerCase().contains(q)) continue;
      final pt = LatLng(bs.lat, bs.lon);
      final isSel = _selectedTransportKind == 'bus' && _selectedTransportId == bs.stopId;
      out.add(Marker(
        point: pt,
        width: isSel ? 52 : 38,
        height: isSel ? 62 : 48,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedMarkerIndex = null;
              _selectedTransportKind = 'bus';
              _selectedTransportId = bs.stopId;
            });
            _mapController.move(pt, 16.0);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.all(isSel ? 10 : 6),
                decoration: BoxDecoration(
                  color: isSel ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                  boxShadow: [if (isSel) BoxShadow(color: color.withOpacity(0.45), blurRadius: 12, spreadRadius: 2)],
                ),
                child: Icon(Icons.directions_bus_rounded, color: isSel ? Colors.white : color, size: isSel ? 18 : 14),
              ),
              Container(width: 2, height: 8, color: color),
            ],
          ),
        ),
      ));
    }
  }

  void _buildBusVehicleMarkers(List<Marker> out, String q) {
    const color = Color(0xFFE53935); // 紅色區分車輛與站牌
    for (final v in _busVehicles) {
      if (v.busLat == null || v.busLon == null) continue;
      if (q.isNotEmpty && !v.routeName.toLowerCase().contains(q) && !v.plateNumb.toLowerCase().contains(q)) continue;
      final pt = LatLng(v.busLat!, v.busLon!);
      final isSel = _selectedTransportKind == 'busvehicle' && _selectedTransportId == v.plateNumb;
      final angle = v.azimuth != null ? v.azimuth! * math.pi / 180.0 : 0.0;
      out.add(Marker(
        point: pt,
        width: isSel ? 62 : 46,
        height: isSel ? 72 : 56,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedMarkerIndex = null;
              _selectedTransportKind = 'busvehicle';
              _selectedTransportId = v.plateNumb;
            });
            _mapController.move(pt, 16.0);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.all(isSel ? 10 : 6),
                decoration: BoxDecoration(
                  color: isSel ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                  boxShadow: [
                    if (isSel) BoxShadow(color: color.withOpacity(0.5), blurRadius: 14, spreadRadius: 2),
                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4),
                  ],
                ),
                child: Transform.rotate(
                  angle: angle,
                  child: Icon(Icons.navigation_rounded,
                      color: isSel ? Colors.white : color,
                      size: isSel ? 20 : 16),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 3)],
                ),
                child: Text(v.routeName,
                    style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white,
                        fontSize: 9, fontWeight: FontWeight.w900),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ));
    }
  }

  // ── build ──
  @override
  Widget build(BuildContext context) {
    super.build(context); // ★ AutomaticKeepAliveClientMixin 必須呼叫
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF9F8F4),
      drawer: const _HomeTxtStyleDrawer(),
      body: Stack(
        children: [
          // ── 地圖 ──
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _chiayiCenter,
                initialZoom: 14.0,
                minZoom: 8.0,
                maxZoom: 18.0,
                onPositionChanged: (position, hasGesture) {
                  if (hasGesture && _isTracking) setState(() => _isTracking = false);
                },
                onTap: (tapPosition, point) {
                  _clearSelection();
                  FocusScope.of(context).unfocus();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.explorechiayi',
                ),
                // ── 多天行程：每天用不同顏色 Polyline 連線 ──
                if (_isItineraryMode && _itineraries.isNotEmpty)
                  ..._buildDayPolylines(),
                MarkerLayer(markers: _buildFlutterMarkers()),
              ],
            ),
          ),

          // ── 頂部 UI ──
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            top: _isTopUIHidden ? -250 : 0,
            left: 0, right: 0,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.15)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 4))],
                      ),
                      child: Row(children: [
                        IconButton(
                          onPressed: () { FocusScope.of(context).unfocus(); _scaffoldKey.currentState?.openDrawer(); },
                          icon: const Icon(Icons.menu_rounded, size: 30, color: Color(0xFF7D6E5D)),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              hintText: '搜尋景點、停車場、公車站...',
                              hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 14),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_up_rounded, color: Color(0xFF9E9182), size: 24),
                          onPressed: () { FocusScope.of(context).unfocus(); setState(() => _isTopUIHidden = true); },
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 38,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: _filters.length,
                      itemBuilder: (_, i) {
                        final sel = i == _filterIndex;
                        return GestureDetector(
                          onTap: () => setState(() => _filterIndex = i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.only(right: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(
                              color: sel ? const Color(0xFF8BAA88) : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: sel ? const Color(0xFF8BAA88) : const Color(0xFF8BAA88).withOpacity(0.1)),
                              boxShadow: [if (sel) BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.2), blurRadius: 8, offset: const Offset(0, 4))],
                            ),
                            child: Text(
                              _filters[i],
                              style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                color: sel ? Colors.white : const Color(0xFF7D6E5D),
                                fontSize: 13,
                                fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildToggleButton('探索地圖', Icons.map_rounded, !_isItineraryMode),
                          _buildToggleButton('查看行程', Icons.format_list_bulleted_rounded, _isItineraryMode),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 收起後的展開按鈕
          if (_isTopUIHidden)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 24,
              child: FloatingActionButton.small(
                heroTag: 'showUI',
                backgroundColor: Colors.white,
                elevation: 4,
                onPressed: () => setState(() => _isTopUIHidden = false),
                child: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF8BAA88)),
              ),
            ),

          // 地圖控制按鈕
          Positioned(
            right: 16,
            bottom: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'locateMe',
                  backgroundColor: Colors.white,
                  elevation: 4,
                  onPressed: () {
                    if (_myLocation != null) {
                      setState(() => _isTracking = true);
                      _mapController.move(_myLocation!, 16.0);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('尚未取得定位資訊...')));
                    }
                  },
                  child: Icon(
                    _isTracking ? Icons.my_location_rounded : Icons.location_searching_rounded,
                    color: _isTracking ? const Color(0xFF8BAA88) : const Color(0xFF7D6E5D),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))],
                  ),
                  child: Column(children: [
                    IconButton(icon: const Icon(Icons.add_rounded, color: Color(0xFF7D6E5D)), onPressed: () => _zoomMap(1.0)),
                    Container(height: 1, width: 30, color: Colors.grey.withOpacity(0.2)),
                    IconButton(icon: const Icon(Icons.remove_rounded, color: Color(0xFF7D6E5D)), onPressed: () => _zoomMap(-1.0)),
                  ]),
                ),
              ],
            ),
          ),

          // ── 底部資訊卡 ──
          Positioned(
            bottom: 30, left: 0, right: 0,
            child: _isItineraryMode
                ? _buildTripCardsPager()
                : _buildActiveBottomCard(),
          ),
        ],
      ),
    );
  }

  // 判斷要顯示哪種底部卡
  Widget _buildActiveBottomCard() {
    if (_selectedMarkerIndex != null) return _buildPoiCard();
    if (_selectedTransportKind == 'parking' && _selectedTransportId != null) {
      final p = _parkingLots.where((x) => x.id == _selectedTransportId).firstOrNull;
      if (p != null) return _buildParkingCard(p);
    }
    if (_selectedTransportKind == 'ubike' && _selectedTransportId != null) {
      final s = _ubikeStations.where((x) => x.uid == _selectedTransportId).firstOrNull;
      if (s != null) return _buildUBikeCard(s);
    }
    if (_selectedTransportKind == 'bus' && _selectedTransportId != null) {
      final bs = _busStops[_selectedTransportId];
      if (bs != null) return _buildBusCard(bs);
    }
    if (_selectedTransportKind == 'busvehicle' && _selectedTransportId != null) {
      final v = _busVehicles.where((x) => x.plateNumb == _selectedTransportId).firstOrNull;
      if (v != null) return _buildBusVehicleCard(v);
    }
    return const SizedBox.shrink();
  }

  // ── POI 資訊卡 ──
  Widget _buildPoiCard() {
    if (_selectedMarkerIndex == null || _selectedMarkerIndex! >= _poiMarkers.length) {
      return const SizedBox.shrink();
    }
    final m = _poiMarkers[_selectedMarkerIndex!];
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: m.imageUrl.isNotEmpty
                      ? Image.network(
                    m.imageUrl,
                    width: 70, height: 70, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 70, height: 70,
                      decoration: BoxDecoration(color: m.markerColor.withOpacity(0.15), borderRadius: BorderRadius.circular(16)),
                      child: Icon(m.markerIcon, color: m.markerColor, size: 32),
                    ),
                  )
                      : Container(
                    width: 70, height: 70,
                    decoration: BoxDecoration(color: m.markerColor.withOpacity(0.15), borderRadius: BorderRadius.circular(16)),
                    child: Icon(m.markerIcon, color: m.markerColor, size: 32),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      Row(children: [
                        if (m.starRating != null) ...[
                          const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 14),
                          Text(' ${m.starRating!.toStringAsFixed(1)}  |  ', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                        ],
                        Text(m.category, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: m.markerColor, fontWeight: FontWeight.bold)),
                      ]),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _clearSelection,
                  child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22),
                ),
              ],
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Divider(height: 1)),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openPoiDetail(m),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: m.markerColor, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.info_outline_rounded, size: 18, color: m.markerColor),
                      const SizedBox(width: 6),
                      Text('詳細資訊', style: TextStyle(fontFamily: 'MyCustomFont', color: m.markerColor, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _togglePoiFavorite(m),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: _favoritedIds.contains('poi_${m.id}')
                        ? const Color(0xFF9EB89A) : m.markerColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _favoritedIds.contains('poi_${m.id}')
                            ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: Colors.white, size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _favoritedIds.contains('poi_${m.id}') ? '已收藏' : '加入收藏',
                        style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── 停車場資訊卡 ──
  Widget _buildParkingCard(ParkingLot p) {
    const accent = Color(0xFF4A90D9);
    final remaining = p.remainingSpace;
    final hasLive = p.liveAvailable == 1;
    Color remainColor = Colors.grey;
    if (hasLive && remaining != null) {
      remainColor = remaining > 10 ? const Color(0xFF388E3C) : remaining > 0 ? const Color(0xFFF57C00) : const Color(0xFFD32F2F);
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 標題列
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.local_parking_rounded, color: accent, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 3),
                      Text('${p.type}　${p.address}',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                GestureDetector(onTap: _clearSelection, child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22)),
              ],
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
            // 數據列
            Row(children: [
              _infoTile(
                hasLive && remaining != null ? '$remaining' : '--',
                '剩餘車位',
                bgColor: hasLive && remaining != null
                    ? (remaining > 10 ? const Color(0xFFE8F5E9) : remaining > 0 ? const Color(0xFFFFF3E0) : const Color(0xFFFFEBEE))
                    : const Color(0xFFF5F5F5),
                textColor: remainColor,
              ),
              const SizedBox(width: 8),
              _infoTile('${p.spaceTotal}', '總車位', bgColor: const Color(0xFFF5F5F5), textColor: const Color(0xFF7D6E5D)),
              const SizedBox(width: 8),
              _iconTile(
                p.evCharging == 1 ? Icons.ev_station_rounded : Icons.ev_station_outlined,
                'EV 充電',
                p.evCharging == 1 ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
                p.evCharging == 1 ? const Color(0xFF388E3C) : Colors.grey,
              ),
              const SizedBox(width: 8),
              _iconTile(
                Icons.wc_rounded,
                '廁所',
                p.toilet == 1 ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
                p.toilet == 1 ? const Color(0xFF388E3C) : Colors.grey,
              ),
            ]),
            const SizedBox(height: 10),
            // 按鈕列
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ParkingInfoScreen(initialSearch: p.name))),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    side: const BorderSide(color: accent, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: accent),
                    SizedBox(width: 6),
                    Text('停車場詳情', style: TextStyle(fontFamily: 'MyCustomFont', color: accent, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _launchNavigation(p.lat, p.lon, p.name),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    backgroundColor: accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.navigation_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── YouBike 資訊卡 ──
  Widget _buildUBikeCard(UBikeStation s) {
    const accent = Color(0xFF2E9E58);
    final isOpen = s.serviceStatus == 1;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.pedal_bike_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isOpen ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(isOpen ? '● 正常營運' : '● 暫停營運',
                          style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                              color: isOpen ? const Color(0xFF388E3C) : const Color(0xFFD32F2F),
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              GestureDetector(onTap: _clearSelection, child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22)),
            ]),
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
            Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    const Icon(Icons.directions_bike_rounded, color: accent, size: 20),
                    const SizedBox(height: 4),
                    Text('${s.availableRent}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.w900, color: accent)),
                    const Text('可借車輛', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    const Icon(Icons.lock_rounded, color: Color(0xFF7D6E5D), size: 20),
                    const SizedBox(height: 4),
                    Text('${s.availableReturn}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                    const Text('可還空位', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                  ]),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => YouBikeInfoScreen(initialSearch: s.name))),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    side: const BorderSide(color: accent, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: accent),
                    SizedBox(width: 6),
                    Text('站點詳情', style: TextStyle(fontFamily: 'MyCustomFont', color: accent, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _launchNavigation(s.lat, s.lon, s.name),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    backgroundColor: accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.navigation_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── 公車站資訊卡 ──
  Widget _buildBusCard(BusStop bs) {
    const accent = Color(0xFFD97B2A);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.directions_bus_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bs.stopName, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                    Text('共 ${bs.routes.length} 條路線停靠', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              GestureDetector(onTap: _clearSelection, child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22)),
            ]),
            const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
            // 路線橫向滾動
            SizedBox(
              height: 72,
              child: bs.routes.isEmpty
                  ? const Center(child: Text('目前無路線資訊', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)))
                  : ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: bs.routes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final r = bs.routes[i];
                  return Container(
                    width: 100,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: r.hasBus ? accent.withOpacity(0.10) : const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: r.hasBus ? accent : Colors.transparent, width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(children: [
                          if (r.hasBus) Container(width: 7, height: 7, decoration: const BoxDecoration(color: accent, shape: BoxShape.circle)),
                          if (r.hasBus) const SizedBox(width: 4),
                          Expanded(child: Text(r.routeName,
                              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.w900,
                                  color: r.hasBus ? accent : const Color(0xFF7D6E5D)), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                        Text(r.direction == 0 ? '去程' : '返程',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                        Text(r.estimateTime,
                            style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold,
                                color: r.hasBus ? accent : const Color(0xFF9E9182))),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BusInfoScreen(initialSearch: bs.stopName))),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    side: const BorderSide(color: accent, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: accent),
                    SizedBox(width: 6),
                    Text('站牌詳情', style: TextStyle(fontFamily: 'MyCustomFont', color: accent, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _launchNavigation(bs.lat, bs.lon, bs.stopName),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    backgroundColor: accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.navigation_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── 公車動態車輛資訊卡 ──
  Widget _buildBusVehicleCard(BusVehicle v) {
    const accent = Color(0xFFE53935);
    final dirLabel = v.direction == 0 ? '去程' : '返程';

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.directions_bus_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(v.routeName,
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: accent.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                        child: Text(dirLabel,
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: accent, fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 3),
                    Row(children: [
                      Container(width: 7, height: 7, decoration: const BoxDecoration(color: accent, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      const Text('行駛中', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: accent, fontWeight: FontWeight.bold)),
                    ]),
                  ],
                ),
              ),
              GestureDetector(onTap: _clearSelection, child: const Icon(Icons.close_rounded, color: Colors.grey, size: 22)),
            ]),
            const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
            // 車牌 + 目前站
            Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
                  child: Column(children: [
                    const Icon(Icons.credit_card_rounded, color: Color(0xFF7D6E5D), size: 18),
                    const SizedBox(height: 4),
                    Text(v.plateNumb.isNotEmpty ? v.plateNumb : '--',
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                    const Text('車牌號碼', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: v.stopName.isNotEmpty ? accent.withOpacity(0.08) : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(children: [
                    Icon(Icons.location_on_rounded, color: v.stopName.isNotEmpty ? accent : Colors.grey, size: 18),
                    const SizedBox(height: 4),
                    Text(v.stopName.isNotEmpty ? v.stopName : '行駛中',
                        style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900,
                            color: v.stopName.isNotEmpty ? accent : const Color(0xFF7D6E5D)),
                        maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                    const Text('附近站', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12)),
                  child: Column(children: [
                    const Icon(Icons.access_time_rounded, color: Color(0xFF388E3C), size: 18),
                    const SizedBox(height: 4),
                    Text(v.estimateTime.isNotEmpty ? v.estimateTime : '--',
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF388E3C)),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const Text('到站狀態', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                  ]),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => BusInfoScreen(initialSearch: v.routeName))),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  side: const BorderSide(color: accent, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: accent),
                  SizedBox(width: 6),
                  Text('查看路線詳情', style: TextStyle(fontFamily: 'MyCustomFont', color: accent, fontWeight: FontWeight.bold, fontSize: 13)),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 小工具 ──
  Widget _infoTile(String value, String label, {required Color bgColor, required Color textColor}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text(value, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 20, fontWeight: FontWeight.w900, color: textColor)),
          Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
        ]),
      ),
    );
  }

  Widget _iconTile(IconData icon, String label, Color bg, Color iconColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: iconColor)),
        ]),
      ),
    );
  }

  void _showCreateTripDialog() {
    final titleCtrl = TextEditingController();
    final budgetCtrl = TextEditingController(text: '2000');
    // ★ 用 ValueNotifier 控制 loading 狀態，不需要 StatefulWidget
    final isSaving = ValueNotifier<bool>(false);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: const Color(0xFFF9F8F4),
        title: const Text('建立新行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                hintText: '例如：嘉義三日深度遊',
                hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey),
                labelText: '行程名稱',
                labelStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold),
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 2)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: const Color(0xFF8BAA88).withOpacity(0.3))),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: budgetCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                prefixText: 'NT\$ ',
                labelText: '預估預算',
                labelStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold),
                filled: true, fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 2)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: const Color(0xFF8BAA88).withOpacity(0.3))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: isSaving,
            builder: (_, saving, __) => ElevatedButton(
              onPressed: saving ? null : () async {
                final title = titleCtrl.text.trim().isEmpty ? '新行程' : titleCtrl.text.trim();
                final budget = int.tryParse(budgetCtrl.text) ?? 2000;
                final now = DateTime.now();
                isSaving.value = true;
                try {
                  // ★ 修復：統一走 ItinerarySaveService（本地 + Firebase 一次同步，id 一致）
                  //   原本先插本地、再另外呼叫 Firebase 且忘帶 userId，
                  //   導致 Firebase 存入 user_id 為空字串、與本地 id 不一致。
                  final uid = _currentUid;
                  await ItinerarySaveService.instance.saveManualItinerary(
                    title: title,
                    estimatedBudget: budget,
                    startDate: now,
                    endDate: now.add(const Duration(days: 1)),
                    plans: [{'dayLabel': 'Day 1', 'items': []}],
                    userId: uid,
                  );
                  // ★ 從 DB reload，記憶體與 DB 完全一致
                  await _reloadItinerariesFromDb();
                  if (mounted) {
                    setState(() => _selectedTripIndex = 0);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  debugPrint('⚠️ 建立行程失敗：$e');
                  isSaving.value = false;
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('建立失敗，請重試：$e',
                          style: const TextStyle(fontFamily: 'MyCustomFont')),
                      backgroundColor: const Color(0xFFD97B2A),
                    ));
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7D6E5D),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: saving
                  ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
                  : const Text('建立', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteTrip(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: const Color(0xFFF9F8F4),
        title: const Text('刪除行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900, fontSize: 20)),
        content: Text('確定要刪除「${_itineraries[index].title}」嗎？此操作無法復原。', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 15)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () async {
              final tripId = _itineraries[index].id;
              if (ctx.mounted) Navigator.pop(ctx);
              try {
                // ★ 必須用 FirebaseSyncService，才會同時打 Firebase 墓碑（deleted_at）
                //   只呼叫 LocalDbService 的話 Firebase 不知道已刪，下次 sync 會把行程復活
                await FirebaseSyncService.instance.deleteItinerary(tripId);
              } catch (e) {
                debugPrint('⚠️ 本地刪除失敗：$e');
              }
              // ★ reload from DB，確保 UI 與 DB 完全一致
              await _reloadItinerariesFromDb();
              debugPrint('✅ 行程已從本地刪除：$tripId');
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7FA3B0), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
            child: const Text('刪除', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showLoginRequired(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('請先登入才能使用此功能喔！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
            backgroundColor: Color(0xFF7D6E5D)
        )
    );
  }

  // ── 替換原本的 _buildAppDrawer ──
  Widget _buildAppDrawer(BuildContext context) {
    return const _HomeTxtStyleDrawer();
  }

  Widget _buildToggleButton(String title, IconData icon, bool isSelected) {
    return GestureDetector(
      onTap: () => setState(() { _isItineraryMode = title == '查看行程'; _selectedMarkerIndex = null; }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF8BAA88) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: isSelected ? Colors.white : const Color(0xFF7D6E5D)),
          const SizedBox(width: 6),
          Text(title, style: TextStyle(fontFamily: 'MyCustomFont', color: isSelected ? Colors.white : const Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 13)),
        ]),
      ),
    );
  }

  Widget _buildTripCardsPager() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 20, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_itineraries.isNotEmpty)
                GestureDetector(
                  onTap: () => _confirmDeleteTrip(_selectedTripIndex),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF7FA3B0).withOpacity(0.5)),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.delete_outline_rounded, size: 16, color: Color(0xFF7FA3B0)),
                      SizedBox(width: 6),
                      Text('刪除行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7FA3B0), fontSize: 13, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _showCreateTripDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7D6E5D),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: const Color(0xFF7D6E5D).withOpacity(0.3), blurRadius: 8)],
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.add_rounded, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text('新增行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ],
          ),
        ),
        if (_itineraries.isEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 15)]),
            child: Column(children: [
              Icon(Icons.map_outlined, size: 48, color: const Color(0xFF8BAA88).withOpacity(0.5)),
              const SizedBox(height: 12),
              const Text('還沒有任何行程', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('點擊「新增行程」開始規劃', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13)),
            ]),
          )
        else
          SizedBox(
            height: 152,
            child: PageView.builder(
              controller: _tripPageController,
              onPageChanged: (i) => setState(() => _selectedTripIndex = i),
              itemCount: _itineraries.length,
              itemBuilder: (context, index) {
                final trip = _itineraries[index];
                final isSel = index == _selectedTripIndex;
                final totalStops = trip.dailyPlans.fold(0, (sum, day) => sum + day.items.length);
                final allSpots = trip.dailyPlans
                    .expand((d) => d.items)
                    .map((e) => e.title)
                    .where((t) => t.isNotEmpty)
                    .toList();

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: EdgeInsets.only(right: 16, top: isSel ? 0 : 12, bottom: isSel ? 0 : 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: isSel ? const Color(0xFF8BAA88) : Colors.transparent, width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(isSel ? 0.1 : 0.05), blurRadius: 15, offset: const Offset(0, 8))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 上半部：點擊進詳情 ──
                      GestureDetector(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ItineraryDetailScreen(tripPlan: trip, onSaved: _reloadItinerariesFromDb))).then((_) { if (mounted) _reloadItinerariesFromDb(); }),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(child: Text(trip.title,
                                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)),
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                  )),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                                    child: Text('共 $totalStops 站', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(children: [
                                const Icon(Icons.account_balance_wallet_rounded, size: 13, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text('預算 NT\$ ${trip.estimatedBudget}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                                const Spacer(),
                                const Text('查看詳情', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                                const SizedBox(width: 3),
                                const Icon(Icons.arrow_forward_ios_rounded, size: 10, color: Color(0xFF8BAA88)),
                              ]),
                            ],
                          ),
                        ),
                      ),
                      // ── 分隔線 ──
                      Divider(height: 1, color: Colors.grey.withOpacity(0.12)),
                      // ── 分享按鈕 ──
                      GestureDetector(
                        onTap: () async {
                          // 跳轉到社群發布頁面（在社群 context 下發布）
                          final result = await Navigator.push<dynamic>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CreatePostScreen(
                                postType: '行程',
                                prefillTitle: trip.title,
                                prefillItineraryId: trip.id,
                                prefillSpots: allSpots,
                                prefillDays: trip.dailyPlans.length,
                                prefillBudget: trip.estimatedBudget,
                                prefillDailyPlans: trip.dailyPlans,
                              ),
                              fullscreenDialog: true,
                            ),
                          );
                          if (result != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Row(children: [
                                  Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                                  SizedBox(width: 8),
                                  Text('🎉 行程已發布至社群分享牆！', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                                ]),
                                backgroundColor: Color(0xFF8BAA88),
                              ),
                            );
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.only(top: 14, bottom: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A90D9).withOpacity(0.04),
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(22),
                              bottomRight: Radius.circular(22),
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.share_rounded, size: 14, color: Color(0xFF4A90D9)),
                              SizedBox(width: 5),
                              Text('分享至社群', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF4A90D9), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════
//  停車場詳情頁
// ════════════════════════════════════════════════

Future<void> _navigateTo(double lat, double lon, String label) async {
  const channel = MethodChannel('com.alibuda/maps');
  try {
    await channel.invokeMethod('openNavigation', {'lat': lat, 'lon': lon, 'label': label});
  } catch (_) {
    // 無法開啟地圖時靜默忽略（detail screens 沒有 context 可以 showSnackBar）
  }
}

class ParkingDetailScreen extends StatelessWidget {
  final ParkingLot parking;
  const ParkingDetailScreen({super.key, required this.parking});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4A90D9);
    final p = parking;
    final hasLive = p.liveAvailable == 1;
    final remaining = p.remainingSpace;

    Color remainColor = Colors.grey;
    Color remainBg = const Color(0xFFF5F5F5);
    if (hasLive && remaining != null) {
      if (remaining > 10) { remainColor = const Color(0xFF388E3C); remainBg = const Color(0xFFE8F5E9); }
      else if (remaining > 0) { remainColor = const Color(0xFFF57C00); remainBg = const Color(0xFFFFF3E0); }
      else { remainColor = const Color(0xFFD32F2F); remainBg = const Color(0xFFFFEBEE); }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: accent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(p.name, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [accent, accent.withOpacity(0.7)]),
                ),
                child: const Center(child: Icon(Icons.local_parking_rounded, color: Colors.white38, size: 80)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 即時狀態
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)]),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('即時狀態', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(color: remainBg, borderRadius: BorderRadius.circular(16)),
                            child: Column(children: [
                              Text(hasLive && remaining != null ? '$remaining' : '--',
                                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 32, fontWeight: FontWeight.w900, color: remainColor)),
                              Text('剩餘車位', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: remainColor.withOpacity(0.8))),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(16)),
                            child: Column(children: [
                              Text('${p.spaceTotal}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 32, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                              const Text('總車位', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
                            ]),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  // 基本資訊
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)]),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('基本資訊', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 14),
                      _detailRow(Icons.business_rounded, '類型', p.type),
                      _detailRow(Icons.location_on_rounded, '地址', p.address),
                      _detailRow(Icons.payments_outlined, '收費說明', p.fareDescription),
                      _detailRow(Icons.phone_rounded, '電話', p.telephone),
                      _detailRow(Icons.manage_accounts_rounded, '營運方式', parking.type),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  // 設備
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)]),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('設備設施', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 14),
                      Row(children: [
                        _facilityChip(Icons.ev_station_rounded, 'EV 充電', p.evCharging == 1),
                        const SizedBox(width: 10),
                        _facilityChip(Icons.wc_rounded, '廁所', p.toilet == 1),
                        const SizedBox(width: 10),
                        _facilityChip(Icons.live_tv_rounded, '即時資訊', p.liveAvailable == 1),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _navigateTo(p.lat, p.lon, p.name),
                      icon: const Icon(Icons.navigation_rounded, color: Colors.white),
                      label: const Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: const Color(0xFF8BAA88)),
        const SizedBox(width: 10),
        Text('$label　', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
        Expanded(child: Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _facilityChip(IconData icon, String label, bool active) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          Icon(icon, color: active ? const Color(0xFF388E3C) : Colors.grey, size: 22),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: active ? const Color(0xFF388E3C) : Colors.grey)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════
//  YouBike 站點詳情頁
// ════════════════════════════════════════════════
class UBikeDetailScreen extends StatelessWidget {
  final UBikeStation station;
  const UBikeDetailScreen({super.key, required this.station});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF2E9E58);
    final s = station;
    final isOpen = s.serviceStatus == 1;
    final total = s.availableRent + s.availableReturn;
    final rentPct = total > 0 ? s.availableRent / total : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: accent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(s.name, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900)),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [accent, accent.withOpacity(0.65)]),
                ),
                child: const Center(child: Icon(Icons.pedal_bike_rounded, color: Colors.white38, size: 80)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 狀態標籤
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isOpen ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(isOpen ? '● 正常營運中' : '● 暫停營運',
                        style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold,
                            color: isOpen ? const Color(0xFF388E3C) : const Color(0xFFD32F2F))),
                  ),
                  const SizedBox(height: 16),
                  // 即時數據卡
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)]),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('即時車位狀態', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(16)),
                            child: Column(children: [
                              const Icon(Icons.directions_bike_rounded, color: accent, size: 24),
                              const SizedBox(height: 6),
                              Text('${s.availableRent}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 32, fontWeight: FontWeight.w900, color: accent)),
                              const Text('可借車輛', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(16)),
                            child: Column(children: [
                              const Icon(Icons.lock_rounded, color: Color(0xFF7D6E5D), size: 24),
                              const SizedBox(height: 6),
                              Text('${s.availableReturn}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 32, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                              const Text('可還空位', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                            ]),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 16),
                      // 使用率進度條
                      Row(children: [
                        const Text('可借比例　', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: rentPct,
                              backgroundColor: const Color(0xFFF5F5F5),
                              valueColor: AlwaysStoppedAnimation<Color>(accent),
                              minHeight: 8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${(rentPct * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold, color: accent)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  // 站點資訊
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)]),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('站點資訊', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                      const SizedBox(height: 14),
                      _detailRow(Icons.qr_code_rounded, '站點 UID', s.uid),
                      _detailRow(Icons.location_on_rounded, '座標',
                          '${s.lat.toStringAsFixed(4)}, ${s.lon.toStringAsFixed(4)}'),
                    ]),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _navigateTo(s.lat, s.lon, s.name),
                      icon: const Icon(Icons.navigation_rounded, color: Colors.white),
                      label: const Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: const Color(0xFF8BAA88)),
        const SizedBox(width: 10),
        Text('$label　', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
        Expanded(child: Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

// ════════════════════════════════════════════════
//  公車站詳情頁
// ════════════════════════════════════════════════
class BusStopDetailScreen extends StatelessWidget {
  final BusStop busStop;
  const BusStopDetailScreen({super.key, required this.busStop});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFD97B2A);
    final bs = busStop;

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 180,
            pinned: true,
            backgroundColor: accent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(bs.stopName, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [accent, accent.withOpacity(0.65)]),
                ),
                child: const Center(child: Icon(Icons.directions_bus_rounded, color: Colors.white38, size: 80)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 站牌資訊
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10)]),
                    child: Row(children: [
                      const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF8BAA88)),
                      const SizedBox(width: 8),
                      Text('站牌 ID：${bs.stopId}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
                      const Spacer(),
                      Text('共 ${bs.routes.length} 條路線', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  const Text('路線到站時間', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                  const SizedBox(height: 10),
                  // 路線清單
                  ...bs.routes.map((r) {
                    final dirLabel = r.direction == 0 ? '去程' : '返程';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: r.hasBus ? accent : Colors.transparent, width: 1.5),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
                      ),
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: r.hasBus ? accent : const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(r.routeName,
                              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.w900,
                                  color: r.hasBus ? Colors.white : const Color(0xFF7D6E5D))),
                        ),
                        const SizedBox(width: 12),
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(dirLabel, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                          Text(r.estimateTime,
                              style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold,
                                  color: r.hasBus ? accent : const Color(0xFF7D6E5D))),
                        ]),
                        const Spacer(),
                        if (r.hasBus)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: accent.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(width: 6, height: 6, decoration: const BoxDecoration(color: accent, shape: BoxShape.circle)),
                              const SizedBox(width: 4),
                              const Text('即將到站', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: accent, fontWeight: FontWeight.bold)),
                            ]),
                          ),
                      ]),
                    );
                  }),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _navigateTo(bs.lat, bs.lon, bs.stopName),
                      icon: const Icon(Icons.navigation_rounded, color: Colors.white),
                      label: const Text('導航前往', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onTap; // 💡 新增這行來接收動作

  const _DrawerItem({required this.icon, required this.title, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF7D6E5D)),
      title: Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.w500)),
      onTap: onTap ?? () => Navigator.pop(context),
    );
  }
}

// ════════════════════════════════════════════════
//  行程詳情頁（原版保留）
// ════════════════════════════════════════════════
class ItineraryDetailScreen extends StatefulWidget {
  final TripPlan tripPlan;
  /// ★ 當使用者返回時，把修改後的行程回傳並存回 DB
  final Future<void> Function()? onSaved;
  const ItineraryDetailScreen({super.key, required this.tripPlan, this.onSaved});

  @override
  State<ItineraryDetailScreen> createState() => _ItineraryDetailScreenState();
}

class _ItineraryDetailScreenState extends State<ItineraryDetailScreen> {
  bool _isEditing = false;
  bool _showAddMenu = false;
  late int _currentBudget;
  late DateTime _startDate;
  late DateTime _endDate;
  int _selectedDayIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentBudget = widget.tripPlan.estimatedBudget;
    _startDate = widget.tripPlan.startDate;
    _endDate = widget.tripPlan.endDate;
  }

  // ★ 返回時自動儲存修改到 SQLite
  Future<void> _saveChanges() async {
    try {
      final plans = widget.tripPlan.dailyPlans.map((day) => {
        'dayLabel': day.dayLabel,
        'items': day.items.map((item) => {
          'time':     item.time,
          'title':    item.title,
          'location': item.location,
          'category': item.category,
          'duration': item.duration,
          'transport_from': item.transportFrom,
          'transportTimes': {
            'car':     item.transportTimes[TransportType.car]     ?? '10min',
            'transit': item.transportTimes[TransportType.transit] ?? '15min',
            'bike':    item.transportTimes[TransportType.bike]    ?? '15min',
            'walk':    item.transportTimes[TransportType.walk]    ?? '25min',
          },
          'selectedTransport': item.selectedTransport.name,
          'tips':   item.tips,
          'ticket': item.ticket,
          'lat': item.mapPosition.latitude,
          'lon': item.mapPosition.longitude,
        }).toList(),
      }).toList();

      await ItinerarySaveService.instance.updateItinerary(
        id: widget.tripPlan.id,
        title: widget.tripPlan.title,
        estimatedBudget: _currentBudget,
        startDate: _startDate,
        endDate: _endDate,
        plans: plans,
      );
      await widget.onSaved?.call();
      debugPrint('✅ 行程詳情已儲存：${widget.tripPlan.title}');
    } catch (e) {
      debugPrint('⚠️ 行程儲存失敗：$e');
    }
  }

  Future<void> _pickDateRange() async {
    const Color cream = Color(0xFFF9F8F4);
    const Color brown = Color(0xFF7D6E5D);
    const Color green = Color(0xFF8BAA88);

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      saveText: 'Save',
      cancelText: 'Cancel',
      helpText: '✦  Select Trip Dates  ✦',
      locale: const Locale('en', 'US'),
      builder: (context, child) {
        final topPadding = MediaQuery.of(context).padding.top;

        return Theme(
          data: ThemeData(
            useMaterial3: true,
            fontFamily: 'MyCustomFont',
            colorScheme: const ColorScheme.light(
              primary: green,
              onPrimary: Colors.white,
              surface: cream,
              onSurface: brown,
            ),
            scaffoldBackgroundColor: cream,
            appBarTheme: const AppBarTheme(
              backgroundColor: cream,
              foregroundColor: brown,
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                backgroundColor: brown,
                foregroundColor: Colors.white,
                disabledBackgroundColor: brown.withOpacity(0.3),
                disabledForegroundColor: Colors.white.withOpacity(0.5),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                textStyle: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ),
            datePickerTheme: DatePickerThemeData(
              backgroundColor: cream,
              headerBackgroundColor: cream,
              headerForegroundColor: brown,
              dividerColor: Colors.transparent,
              headerHelpStyle: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: brown, letterSpacing: 1.0),
              headerHeadlineStyle: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.w900, color: brown),
              rangeSelectionBackgroundColor: green.withOpacity(0.15),
              todayBorder: const BorderSide(color: green, width: 2),
              cancelButtonStyle: TextButton.styleFrom(foregroundColor: Colors.white),
              confirmButtonStyle: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ),
          child: Stack(
            children: [
              child!,
              Positioned(
                top: topPadding - 8,
                right: 0,
                width: 86,
                height: 56,
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.center,
                    child: const Material(
                      type: MaterialType.transparency,
                      child: Text(
                        'Save',
                        style: TextStyle(
                          fontFamily: 'MyCustomFont',
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: 0.5,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }

  void _editBudget() {
    final ctrl = TextEditingController(text: _currentBudget.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: const Color(0xFFF9F8F4),
        title: const Text('修改預估預算', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            prefixText: 'NT\$ ',
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF8BAA88))),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _currentBudget = int.tryParse(ctrl.text) ?? _currentBudget);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88)),
            child: const Text('確認', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ★ 防止 dailyPlans 為空時 RangeError
    final hasDays = widget.tripPlan.dailyPlans.isNotEmpty;
    if (_selectedDayIndex >= widget.tripPlan.dailyPlans.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedDayIndex = 0);
      });
    }
    final currentDayPlan = hasDays
        ? widget.tripPlan.dailyPlans[_selectedDayIndex.clamp(0, widget.tripPlan.dailyPlans.length - 1)]
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _saveChanges();
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF9F8F4),
        body: Stack(
          children: [
            CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildHeader(context)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.tripPlan.title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(Icons.calendar_month_rounded, color: Color(0xFF8BAA88), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              '${_startDate.year}/${_startDate.month}/${_startDate.day} - ${_endDate.month}/${_endDate.day}',
                              style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_calendar_rounded, size: 18, color: Colors.grey),
                              onPressed: _pickDateRange,
                            ),
                            const Spacer(),
                            ElevatedButton.icon(
                              onPressed: () async {
                                final ok = await CalendarEventService.instance
                                    .addItineraryToCalendar(
                                  itineraryId: widget.tripPlan.id,
                                  title: widget.tripPlan.title,
                                  startDate: _startDate,
                                  endDate: _endDate,
                                  budget: _currentBudget,
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? '✅ 行程已加入活動月曆！'
                                          : '⚠️ 此行程已在月曆中',
                                      style: const TextStyle(fontFamily: 'MyCustomFont'),
                                    ),
                                    backgroundColor: ok
                                        ? const Color(0xFF8BAA88)
                                        : const Color(0xFFBCAAA4),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.event_available_rounded, color: Colors.white, size: 16),
                              label: const Text('加入月曆', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8BAA88),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8BAA88).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.account_balance_wallet_rounded, color: Color(0xFF8BAA88), size: 20),
                              const SizedBox(width: 10),
                              const Text('預估總預算', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                              const Spacer(),
                              Text('NT\$ $_currentBudget', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF8BAA88))),
                              IconButton(
                                icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.grey),
                                onPressed: _editBudget,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 42,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: widget.tripPlan.dailyPlans.length,
                            itemBuilder: (ctx, i) {
                              final isSel = i == _selectedDayIndex;
                              return GestureDetector(
                                onTap: () => setState(() => _selectedDayIndex = i),
                                child: Container(
                                  margin: const EdgeInsets.only(right: 12),
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isSel ? const Color(0xFF7D6E5D) : Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: isSel ? Colors.transparent : const Color(0xFF8BAA88).withOpacity(0.3)),
                                    boxShadow: [
                                      if (isSel) BoxShadow(color: const Color(0xFF7D6E5D).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
                                    ],
                                  ),
                                  child: Text(
                                    widget.tripPlan.dailyPlans[i].dayLabel,
                                    style: TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      color: isSel ? Colors.white : const Color(0xFF7D6E5D),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: currentDayPlan == null
                        ? Container(
                      padding: const EdgeInsets.all(32),
                      child: const Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.calendar_today_rounded, size: 48, color: Color(0xFF8BAA88)),
                        SizedBox(height: 12),
                        Text('此行程尚無每日規劃', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 15, fontWeight: FontWeight.bold)),
                        SizedBox(height: 6),
                        Text('請透過 AI 助理生成行程，或手動新增景點', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 12)),
                      ]),
                    )
                        : ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: (oldIndex, newIndex) {
                        setState(() {
                          if (newIndex > oldIndex) newIndex -= 1;
                          final item = currentDayPlan.items.removeAt(oldIndex);
                          currentDayPlan.items.insert(newIndex, item);
                        });
                      },
                      children: [
                        for (int i = 0; i < currentDayPlan.items.length; i++)
                          _buildTimelineItem(
                            currentDayPlan.items[i],
                            i,
                            i == currentDayPlan.items.length - 1,
                            ValueKey('${currentDayPlan.items[i].title}_$i'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
            _buildFloatingAddMenu(),
          ],
        ),
      ), // Scaffold
    ); // PopScope
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
              onTap: () async {
                await _saveChanges(); // ★ 返回前先存檔
                if (context.mounted) Navigator.pop(context);
              },
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
                  Text('ITINERARY', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF8BAA88), letterSpacing: 1.5)),
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
                    Icon(Icons.map_rounded, size: 14, color: Color(0xFF8BAA88)),
                    SizedBox(width: 6),
                    Text('行程詳情', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => setState(() => _isEditing = !_isEditing),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _isEditing ? const Color(0xFF7D6E5D) : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: Icon(
                  _isEditing ? Icons.check_rounded : Icons.swap_vert_rounded,
                  size: 20,
                  color: _isEditing ? Colors.white : const Color(0xFF7D6E5D),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(ItineraryItem item, int index, bool isLast, Key key) {
    // category icon / color
    final Color catColor;
    final IconData catIcon;
    switch (item.category) {
      case '餐廳':
        catColor = const Color(0xFFD4956A);
        catIcon  = Icons.restaurant_rounded;
        break;
      case '住宿':
        catColor = const Color(0xFF7FA3B0);
        catIcon  = Icons.hotel_rounded;
        break;
      default:
        catColor = const Color(0xFF8BAA88);
        catIcon  = Icons.landscape_rounded;
    }

    return IntrinsicHeight(
      key: key,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(item.time, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF9E9182))),
            ),
          ),
          Column(
            children: [
              const SizedBox(height: 22),
              Container(
                width: 14, height: 14,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: catColor, width: 3),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: catColor.withOpacity(0.3),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: catColor.withOpacity(0.2)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── 類別標籤 + 標題 ──
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: catColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(catIcon, size: 11, color: catColor),
                                const SizedBox(width: 3),
                                Text(item.category, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: catColor, fontWeight: FontWeight.w900)),
                              ]),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(item.title, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF7D6E5D))),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.location_on_outlined, size: 16, color: Colors.grey),
                            const SizedBox(width: 4),
                            Expanded(child: Text('地點: ${item.location}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold))),
                            const Text('跳轉介紹', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF8BAA88), fontWeight: FontWeight.w900, decoration: TextDecoration.underline)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.access_time_rounded, size: 16, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text('預計停留: ${item.duration}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),

                        // ── 交通區塊 ──
                        Row(
                          children: [
                            const Text('交通方式', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w900)),
                            if (item.transportFrom.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '從 ${item.transportFrom}',
                                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildTransportOption(TransportType.car,     Icons.directions_car_rounded,     item.transportTimes[TransportType.car]     ?? '-', item),
                            _buildTransportOption(TransportType.transit, Icons.directions_transit_rounded, item.transportTimes[TransportType.transit] ?? '-', item),
                            _buildTransportOption(TransportType.bike,    Icons.pedal_bike_rounded,         item.transportTimes[TransportType.bike]    ?? '-', item),
                            _buildTransportOption(TransportType.walk,    Icons.directions_walk_rounded,    item.transportTimes[TransportType.walk]    ?? '-', item),
                          ],
                        ),

                        if (item.tips.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(12)),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                                  child: const Text('Tips', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Color(0xFF8BAA88), fontWeight: FontWeight.w900)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: item.tips.map((t) => Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Text('• $t', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                                    )).toList(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (item.ticket != null && item.ticket!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(4)),
                                child: const Text('票價', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Color(0xFFD97B2A), fontWeight: FontWeight.w900)),
                              ),
                              const SizedBox(width: 8),
                              Text(item.ticket!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_isEditing)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_indicator_rounded, color: Color(0xFF9E9182), size: 24),
                          ),
                          const SizedBox(height: 16),
                          GestureDetector(
                            onTap: () => setState(() => widget.tripPlan.dailyPlans[_selectedDayIndex].items.removeAt(index)),
                            child: const Icon(Icons.delete_outline_rounded, color: Color(0xFF7FA3B0), size: 22),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportOption(TransportType type, IconData icon, String time, ItineraryItem item) {
    final isSel = item.selectedTransport == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => item.selectedTransport = type),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSel ? const Color(0xFF8BAA88) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSel ? const Color(0xFF8BAA88) : Colors.grey.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, color: isSel ? Colors.white : Colors.grey, size: 20),
              const SizedBox(height: 4),
              Text(time, style: TextStyle(fontFamily: 'MyCustomFont', color: isSel ? Colors.white : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingAddMenu() {
    return Positioned(
      bottom: 30,
      right: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _showAddMenu ? 1.0 : 0.0,
            child: IgnorePointer(
              ignoring: !_showAddMenu,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _actionPill(Icons.landscape_rounded, '增加新景點', category: '景點'),
                  const SizedBox(height: 10),
                  _actionPill(Icons.restaurant_rounded, '增加新餐廳', category: '餐廳'),
                  const SizedBox(height: 10),
                  _actionPill(Icons.hotel_rounded, '增加住宿', category: '住宿'),
                  const SizedBox(height: 10),
                  _actionPill(Icons.edit_calendar_rounded, '自定義活動', category: '自訂'),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _showAddMenu = !_showAddMenu),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _showAddMenu ? Colors.white : const Color(0xFF8BAA88),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF8BAA88), width: 2),
                boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Icon(
                _showAddMenu ? Icons.close_rounded : Icons.add_rounded,
                color: _showAddMenu ? const Color(0xFF8BAA88) : Colors.white,
                size: 32,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionPill(IconData icon, String text, {required String category}) {
    return GestureDetector(
      onTap: () async {
        setState(() => _showAddMenu = false);
        final result = await Navigator.push<ItineraryItem>(
          context,
          MaterialPageRoute(
            builder: (_) => AddItineraryItemScreen(category: category),
          ),
        );
        if (result != null) {
          setState(() {
            // Insert sorted by time
            final items = widget.tripPlan.dailyPlans[_selectedDayIndex].items;
            final idx = items.indexWhere((e) => e.time.compareTo(result.time) > 0);
            if (idx == -1) {
              items.add(result);
            } else {
              items.insert(idx, result);
            }
          });
          // ★ 新增後立即存入 DB，不等使用者按返回
          await _saveChanges();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF7D6E5D),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: const Color(0xFF7D6E5D).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  新增行程項目頁（支援下拉搜尋 + 時間選擇 + 回傳 ItineraryItem）
// ════════════════════════════════════════════════════════════════════

/// 簡化版 POI 資訊，供下拉選單使用
class _PoiOption {
  final String name;
  final String address;
  final double lat;
  final double lon;
  const _PoiOption({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
  });
}

class AddItineraryItemScreen extends StatefulWidget {
  /// '景點' | '餐廳' | '住宿' | '自訂'
  final String category;
  const AddItineraryItemScreen({super.key, required this.category});
  @override
  State<AddItineraryItemScreen> createState() => _AddItineraryItemScreenState();
}

class _AddItineraryItemScreenState extends State<AddItineraryItemScreen> {
  // ── controllers ──
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _durationCtrl = TextEditingController(text: '1 小時');
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _ticketCtrl = TextEditingController();

  // ── state ──
  TransportType _selectedTransport = TransportType.transit;
  TimeOfDay _selectedTime = const TimeOfDay(hour: 9, minute: 0);
  List<_PoiOption> _allOptions = [];
  List<_PoiOption> _filtered = [];
  _PoiOption? _selectedPoi;
  bool _isLoading = true;
  bool _showDropdown = false;

  // ── Overlay ──
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  final FocusNode _searchFocus = FocusNode();

  // ── asset paths ──
  static const String _attractionsAsset = 'assets/data/attractions_fixed_final.json';
  static const String _restaurantsAsset = 'assets/data/app_restaurants.json';
  static const String _hotelsAsset      = 'assets/data/app_hotels.json';

  String get _categoryEnLabel {
    switch (widget.category) {
      case '餐廳': return 'RESTAURANT';
      case '住宿': return 'HOTEL';
      case '自訂': return 'CUSTOM';
      default:     return 'ATTRACTION';
    }
  }

  @override
  void initState() {
    super.initState();
    _loadOptions();
    _searchCtrl.addListener(_onSearchChanged);
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) _removeOverlay();
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _durationCtrl.dispose();
    _noteCtrl.dispose();
    _ticketCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── 根據 category 載入對應 JSON ──
  Future<void> _loadOptions() async {
    try {
      final List<_PoiOption> options = [];

      Future<List<_PoiOption>> _parseAsset(String path, _PoiOption? Function(dynamic) mapper) async {
        try {
          final raw = await rootBundle.loadString(path);
          final decoded = jsonDecode(raw);
          final List items = decoded is List ? decoded : (decoded as Map).values.toList();
          return items.map(mapper).whereType<_PoiOption>().toList();
        } catch (e) {
          debugPrint('⚠️ 載入 $path 失敗：$e');
          return [];
        }
      }

      if (widget.category == '景點' || widget.category == '自訂') {
        options.addAll(await _parseAsset(_attractionsAsset, (j) {
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) return null;
          return _PoiOption(
            name: j['AttractionName']?.toString() ?? '',
            address: j['Address']?.toString() ?? '',
            lat: lat, lon: lon,
          );
        }));
      }
      if (widget.category == '餐廳' || widget.category == '自訂') {
        options.addAll(await _parseAsset(_restaurantsAsset, (j) {
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) return null;
          return _PoiOption(
            name: j['RestaurantName']?.toString() ?? '',
            address: j['Address']?.toString() ?? '',
            lat: lat, lon: lon,
          );
        }));
      }
      if (widget.category == '住宿' || widget.category == '自訂') {
        options.addAll(await _parseAsset(_hotelsAsset, (j) {
          final lat = (j['PositionLat'] as num?)?.toDouble();
          final lon = (j['PositionLon'] as num?)?.toDouble();
          if (lat == null || lon == null) return null;
          return _PoiOption(
            name: j['HotelName']?.toString() ?? '',
            address: j['Address']?.toString() ?? '',
            lat: lat, lon: lon,
          );
        }));
      }

      if (mounted) {
        setState(() {
          _allOptions = options;
          _filtered = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ _loadOptions 失敗：$e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged() {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      _removeOverlay();
      setState(() { _filtered = []; _showDropdown = false; });
      return;
    }
    final results = _allOptions
        .where((o) => o.name.contains(q) || o.address.contains(q))
        .take(30)
        .toList();
    setState(() { _filtered = results; _showDropdown = results.isNotEmpty; });
    if (results.isNotEmpty) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: MediaQuery.of(context).size.width - 48,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 56),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            shadowColor: Colors.black26,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _DropdownList(
                options: _filtered,
                catIcon: _catIcon,
                catColor: _catColor,
                onSelect: _selectPoi,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _selectPoi(_PoiOption poi) {
    _removeOverlay();
    setState(() {
      _selectedPoi = poi;
      _searchCtrl.text = poi.name;
      _showDropdown = false;
      _filtered = [];
    });
    _searchFocus.unfocus();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (ctx, child) => Theme(
        data: ThemeData(
          useMaterial3: true,
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF8BAA88),
            onPrimary: Colors.white,
            surface: Color(0xFFF9F8F4),
            onSurface: Color(0xFF7D6E5D),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF7D6E5D)),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  String get _timeString =>
      '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}';

  // ── 儲存並回傳 ──
  void _save() {
    final name = _searchCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('請輸入或選擇地點名稱', style: TextStyle(fontFamily: 'MyCustomFont')),
          backgroundColor: Color(0xFFD97B2A),
        ),
      );
      return;
    }

    final poi = _selectedPoi;
    final lat = poi?.lat ?? 23.4800;
    final lon = poi?.lon ?? 120.4500;
    final address = poi?.address ?? '';

    final tips = _noteCtrl.text.trim().isNotEmpty
        ? _noteCtrl.text.trim().split('\n').where((s) => s.isNotEmpty).toList()
        : <String>[];

    final ticket = _ticketCtrl.text.trim().isEmpty ? null : _ticketCtrl.text.trim();

    final item = ItineraryItem(
      time: _timeString,
      title: name,
      location: address,
      duration: _durationCtrl.text.trim().isEmpty ? '1 小時' : _durationCtrl.text.trim(),
      transportTimes: const {
        TransportType.car:     '10min',
        TransportType.transit: '15min',
        TransportType.bike:    '15min',
        TransportType.walk:    '25min',
      },
      selectedTransport: _selectedTransport,
      tips: tips,
      ticket: ticket,
      mapPosition: LatLng(lat, lon),
      category: widget.category == '自訂' ? '景點' : widget.category,
    );

    Navigator.pop(context, item);
  }

  // ── UI ──
  Color get _catColor {
    switch (widget.category) {
      case '餐廳': return const Color(0xFFD4956A);
      case '住宿': return const Color(0xFF7FA3B0);
      case '自訂': return const Color(0xFF9E9182);
      default:     return const Color(0xFF8BAA88);
    }
  }

  IconData get _catIcon {
    switch (widget.category) {
      case '餐廳': return Icons.restaurant_rounded;
      case '住宿': return Icons.hotel_rounded;
      case '自訂': return Icons.edit_calendar_rounded;
      default:     return Icons.landscape_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: Column(
        children: [
          _buildHeader(context),
          if (_isLoading)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: _catColor),
                    const SizedBox(height: 16),
                    Text('載入資料中…', style: TextStyle(fontFamily: 'MyCustomFont', color: _catColor)),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 時間選擇 ──
                    _sectionLabel(Icons.access_time_rounded, '出發時間'),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: _pickTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.withOpacity(0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.schedule_rounded, color: _catColor, size: 20),
                            const SizedBox(width: 12),
                            Text(
                              _timeString,
                              style: TextStyle(
                                fontFamily: 'MyCustomFont',
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: _catColor,
                              ),
                            ),
                            const Spacer(),
                            const Icon(Icons.arrow_drop_down_rounded, color: Colors.grey),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── 地點搜尋下拉 ──
                    _sectionLabel(_catIcon, '地點名稱'),
                    const SizedBox(height: 12),
                    CompositedTransformTarget(
                      link: _layerLink,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                            decoration: InputDecoration(
                              hintText: widget.category == '住宿'
                                  ? '搜尋飯店、民宿名稱…'
                                  : widget.category == '餐廳'
                                  ? '搜尋餐廳名稱…'
                                  : '搜尋景點名稱…',
                              hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey),
                              filled: true,
                              fillColor: Colors.white,
                              prefixIcon: Icon(_catIcon, color: _catColor, size: 20),
                              suffixIcon: _searchCtrl.text.isNotEmpty
                                  ? IconButton(
                                icon: const Icon(Icons.clear_rounded, color: Colors.grey),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  _removeOverlay();
                                  setState(() { _selectedPoi = null; _showDropdown = false; });
                                },
                              )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: _catColor, width: 1.5),
                              ),
                            ),
                          ),
                          // 已選中的地址提示
                          if (_selectedPoi != null && _selectedPoi!.address.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8, left: 4),
                              child: Row(
                                children: [
                                  Icon(Icons.location_on_rounded, size: 14, color: _catColor),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      _selectedPoi!.address,
                                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _catColor),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── 停留時間 ──
                    _sectionLabel(Icons.hourglass_empty_rounded, '預計停留時間'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _durationCtrl,
                      decoration: _inputDeco('例如：1.5 小時'),
                    ),

                    const SizedBox(height: 24),

                    // ── 交通方式 ──
                    _sectionLabel(Icons.directions_rounded, '交通方式（從上一站出發）'),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _transportSelector(TransportType.walk, Icons.directions_walk_rounded, '步行'),
                        const SizedBox(width: 8),
                        _transportSelector(TransportType.transit, Icons.directions_bus_rounded, '公車'),
                        const SizedBox(width: 8),
                        _transportSelector(TransportType.car, Icons.local_taxi_rounded, '計程車'),
                        const SizedBox(width: 8),
                        _transportSelector(TransportType.bike, Icons.pedal_bike_rounded, '單車'),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // ── 票價 ──
                    _sectionLabel(Icons.confirmation_number_outlined, '票價（選填）'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _ticketCtrl,
                      decoration: _inputDeco('例如：NT\$200 / 免費'),
                    ),

                    const SizedBox(height: 24),

                    // ── 個人筆記 ──
                    _sectionLabel(Icons.edit_note_rounded, '個人筆記 / Tips'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _noteCtrl,
                      maxLines: 3,
                      decoration: _inputDeco('例如：必買伴手禮、注意事項…（每行一條）'),
                    ),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
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
                  border: Border.all(color: _catColor.withOpacity(0.2)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF7D6E5D)),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('ADD ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), letterSpacing: 1.5)),
                  Text(_categoryEnLabel, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 26, fontWeight: FontWeight.bold, color: _catColor, letterSpacing: 1.5)),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _catColor.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _catColor.withOpacity(0.3), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_catIcon, size: 14, color: _catColor),
                    const SizedBox(width: 6),
                    Text('新增${widget.category}', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: _catColor)),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _save,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _catColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: _catColor.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: const Text('儲存', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _catColor),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
      ],
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey.withOpacity(0.2))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey.withOpacity(0.2))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: _catColor, width: 1.5)),
  );

  Widget _transportSelector(TransportType type, IconData icon, String label) {
    final isSelected = _selectedTransport == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTransport = type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? _catColor : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? _catColor : Colors.grey.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, color: isSelected ? Colors.white : Colors.grey),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontFamily: 'MyCustomFont', color: isSelected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════
//  下拉選單元件（內建搜尋列）
// ════════════════════════════════════════════════════════
class _DropdownList extends StatefulWidget {
  final List<_PoiOption> options;
  final IconData catIcon;
  final Color catColor;
  final void Function(_PoiOption) onSelect;

  const _DropdownList({
    required this.options,
    required this.catIcon,
    required this.catColor,
    required this.onSelect,
  });

  @override
  State<_DropdownList> createState() => _DropdownListState();
}

class _DropdownListState extends State<_DropdownList> {
  late List<_PoiOption> _visible;
  final TextEditingController _filterCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _visible = widget.options;
    _filterCtrl.addListener(_filter);
  }

  @override
  void didUpdateWidget(_DropdownList old) {
    super.didUpdateWidget(old);
    _filter(); // refresh when parent updates options
  }

  void _filter() {
    final q = _filterCtrl.text.trim();
    setState(() {
      _visible = q.isEmpty
          ? widget.options
          : widget.options.where((o) => o.name.contains(q) || o.address.contains(q)).toList();
    });
  }

  @override
  void dispose() {
    _filterCtrl.removeListener(_filter);
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      constraints: const BoxConstraints(maxHeight: 300),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 下拉內搜尋列 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.15))),
            ),
            child: TextField(
              controller: _filterCtrl,
              autofocus: false,
              style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: '在結果中再搜尋…',
                hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13),
                prefixIcon: Icon(Icons.search_rounded, size: 18, color: widget.catColor),
                suffixIcon: _filterCtrl.text.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 16, color: Colors.grey),
                  padding: EdgeInsets.zero,
                  onPressed: () { _filterCtrl.clear(); },
                )
                    : null,
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: widget.catColor, width: 1.5),
                ),
              ),
            ),
          ),
          // ── 結果筆數 ──
          if (_visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '找不到符合的結果',
                style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey.shade400, fontSize: 13),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: _visible.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.withOpacity(0.12)),
                itemBuilder: (_, i) {
                  final opt = _visible[i];
                  return InkWell(
                    onTap: () => widget.onSelect(opt),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      child: Row(
                        children: [
                          Icon(widget.catIcon, color: widget.catColor, size: 18),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  opt.name,
                                  style: const TextStyle(
                                    fontFamily: 'MyCustomFont',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF7D6E5D),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (opt.address.isNotEmpty)
                                  Text(
                                    opt.address,
                                    style: const TextStyle(
                                      fontFamily: 'MyCustomFont',
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: Colors.grey.shade300, size: 18),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
// ═══════════════════════════════════════════════════════════════
//  輕量 POI 詳情頁（美食 & 住宿共用）
//  不依賴 FoodModel / HotelModel，避免版本衝突
// ═══════════════════════════════════════════════════════════════
class _PoiMiniDetailScreen extends StatefulWidget {
  final PoiMarker marker;
  final List<String> imageUrls;
  final String rating, price, phone, address, openTime, desc;
  final List<String> tags;

  const _PoiMiniDetailScreen({
    required this.marker,
    required this.imageUrls,
    required this.rating,
    required this.price,
    required this.phone,
    required this.address,
    required this.openTime,
    required this.desc,
    required this.tags,
  });

  @override
  State<_PoiMiniDetailScreen> createState() => _PoiMiniDetailScreenState();
}

class _PoiMiniDetailScreenState extends State<_PoiMiniDetailScreen> {
  int _imgIdx = 0;

  @override
  Widget build(BuildContext context) {
    final m = widget.marker;
    final color = m.markerColor;

    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── 頂部圖片 AppBar ──
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: const Color(0xFFF9F8F4),
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.85),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF7D6E5D)),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.imageUrls.isNotEmpty)
                    PageView.builder(
                      itemCount: widget.imageUrls.length,
                      onPageChanged: (i) => setState(() => _imgIdx = i),
                      itemBuilder: (_, i) => Image.network(
                        widget.imageUrls[i],
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: color.withOpacity(0.15),
                          child: Icon(m.markerIcon, size: 60, color: color),
                        ),
                      ),
                    )
                  else
                    Container(
                      color: color.withOpacity(0.15),
                      child: Icon(m.markerIcon, size: 60, color: color),
                    ),
                  // 底部漸層
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black.withOpacity(0.4), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                  // 圖片計數點
                  if (widget.imageUrls.length > 1)
                    Positioned(
                      bottom: 12,
                      left: 0, right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(widget.imageUrls.length, (i) =>
                            Container(
                              width: i == _imgIdx ? 16 : 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: i == _imgIdx ? Colors.white : Colors.white54,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            )),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── 內容區 ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 分類標籤
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: color.withOpacity(0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(m.markerIcon, size: 12, color: color),
                      const SizedBox(width: 4),
                      Text(m.category, style: TextStyle(fontFamily: 'MyCustomFont', color: color, fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Text(m.name,
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D), height: 1.3)),
                  if (widget.rating.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.star_rounded, color: Color(0xFFD4A017), size: 16),
                      const SizedBox(width: 4),
                      Text(widget.rating, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
                    ]),
                  ],
                  const SizedBox(height: 20),
                  // 資訊卡
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withOpacity(0.15)),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10)],
                    ),
                    child: Column(children: [
                      if (widget.address.isNotEmpty) _row(Icons.location_on_rounded, '地址', widget.address, color),
                      if (widget.address.isNotEmpty && widget.phone.isNotEmpty)
                        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
                      if (widget.phone.isNotEmpty) _row(Icons.phone_rounded, '電話', widget.phone, color),
                      if (widget.phone.isNotEmpty && widget.openTime.isNotEmpty)
                        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
                      if (widget.openTime.isNotEmpty) _row(Icons.access_time_rounded, '時間', widget.openTime, color),
                      if (widget.openTime.isNotEmpty && widget.price.isNotEmpty)
                        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1)),
                      if (widget.price.isNotEmpty) _row(Icons.attach_money_rounded, '價格', widget.price, color),
                    ]),
                  ),
                  if (widget.tags.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.tags.map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: color.withOpacity(0.25)),
                        ),
                        child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: color, fontSize: 11, fontWeight: FontWeight.bold)),
                      )).toList(),
                    ),
                  ],
                  if (widget.desc.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('簡介', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                    const SizedBox(height: 10),
                    Text(widget.desc, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, color: Color(0xFF4A4036), height: 1.8)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value, Color color) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, size: 14, color: color),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Color(0xFF7D6E5D), fontWeight: FontWeight.w600)),
        ],
      )),
    ],
  );
}

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