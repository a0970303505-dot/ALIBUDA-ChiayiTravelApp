// ═══════════════════════════════════════════════════════════════
//  traffic_api_service.dart  v2 – 緩存版
//  改動重點：
//   1. _CacheEntry / CacheMeta：本地記憶體緩存結構
//   2. 所有 fetch* 方法加上 forceRefresh 參數
//   3. _cachedGet：統一緩存邏輯，HIT 時不打 server
//   4. CacheMeta 暴露給 UI 顯示「N 秒前更新」
//   5. latestMeta(key)：讓 traffic_screen 讀取各頁緩存狀態
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'package:http/http.dart' as http;

// ▶ 修改這裡：換成你部署 server 的實際 IP 或網域
//   本機測試：http://10.0.2.2:8000  (Android 模擬器連 host)
//   實體機測試：http://192.168.x.x:8000
//   正式部署：https://your-domain.com
const String kApiBase = 'http://10.0.2.2:8000';

// ══════════════════════════════════════════════════════════════
//  緩存元資料（供 UI 顯示「幾秒前更新」）
// ══════════════════════════════════════════════════════════════
class CacheMeta {
  /// 資料實際從 server 抓回來的本機時間
  final DateTime fetchedAt;

  /// server 告知的 TTL（秒）
  final int ttlSeconds;

  /// 是否命中 server 端緩存（true = server 沒去打 TDX，直接回傳 JSON 檔快取）
  final bool serverCacheHit;

  const CacheMeta({
    required this.fetchedAt,
    required this.ttlSeconds,
    required this.serverCacheHit,
  });

  /// 距上次真正從 server 拿到資料，已過了幾秒
  int get ageSeconds => DateTime.now().difference(fetchedAt).inSeconds;

  /// 是否超過 TTL（本地端判斷，決定要不要重打 server）
  bool get isExpiredLocally => ageSeconds >= ttlSeconds;

  /// UI 顯示文字，例如「3 分前更新」或「剛剛更新」
  String get displayText {
    final sec = ageSeconds;
    if (sec < 10) return '剛剛更新';
    if (sec < 60) return '$sec 秒前更新';
    final min = sec ~/ 60;
    if (min < 60) return '$min 分前更新';
    return '${min ~/ 60} 小時前更新';
  }

  /// 更新時間字串，例如「14:32」
  String get timeLabel =>
      '${fetchedAt.hour.toString().padLeft(2, '0')}:${fetchedAt.minute.toString().padLeft(2, '0')} 更新';
}

// ══════════════════════════════════════════════════════════════
//  本地記憶體緩存結構
// ══════════════════════════════════════════════════════════════
class _CacheEntry<T> {
  final T data;
  final CacheMeta meta;

  const _CacheEntry(this.data, this.meta);

  bool get isExpired => meta.isExpiredLocally;
}

// ══════════════════════════════════════════════════════════════
//  資料模型（與原版相同，完整保留）
// ══════════════════════════════════════════════════════════════
class BusEntry {
  final String routeName;
  final String departureStop;
  final String destinationStop;
  final String stopName;
  final String estimateTime;
  final String stopStatus;
  final String plateNumb;
  final int direction;

  const BusEntry({
    required this.routeName,
    required this.departureStop,
    required this.destinationStop,
    required this.stopName,
    required this.estimateTime,
    required this.stopStatus,
    required this.plateNumb,
    required this.direction,
  });

  factory BusEntry.fromJson(Map<String, dynamic> j) => BusEntry(
    routeName: j['RouteName'] ?? '',
    departureStop: j['DepartureStopName'] ?? '',
    destinationStop: j['DestinationStopName'] ?? '',
    stopName: j['StopName'] ?? '',
    estimateTime: j['EstimateTime'] ?? '',
    stopStatus: j['StopStatus'] ?? '',
    plateNumb: j['PlateNumb'] ?? '',
    direction: (j['Direction'] as num?)?.toInt() ?? 0,
  );
}

class TimetableStop {
  final int stopSequence;
  final String stationId;
  final String stationName;
  final String arrivalTime;
  final String departureTime;

  const TimetableStop({
    required this.stopSequence,
    required this.stationId,
    required this.stationName,
    required this.arrivalTime,
    required this.departureTime,
  });

  factory TimetableStop.fromJson(Map<String, dynamic> j) => TimetableStop(
    stopSequence: (j['StopSequence'] as num?)?.toInt() ?? 0,
    stationId: j['StationID'] ?? '',
    stationName: j['StationName'] ?? '',
    arrivalTime: j['ArrivalTime'] ?? '',
    departureTime: j['DepartureTime'] ?? '',
  );
}

class TrainEntry {
  final String trainNo;
  final String trainTypeName;
  final String startingStationName;
  final String endingStationName;
  final String stationName;
  final String delayTime;
  final String direction;
  final String tripDuration;
  final List<TimetableStop> timetable;

  const TrainEntry({
    required this.trainNo,
    required this.trainTypeName,
    required this.startingStationName,
    required this.endingStationName,
    required this.stationName,
    required this.delayTime,
    required this.direction,
    required this.tripDuration,
    required this.timetable,
  });

  factory TrainEntry.fromJson(Map<String, dynamic> j) => TrainEntry(
    trainNo: j['TrainNo'] ?? '',
    trainTypeName: j['TrainTypeName'] ?? '',
    startingStationName: j['StartingStationName'] ?? '',
    endingStationName: j['EndingStationName'] ?? '',
    stationName: j['StationName'] ?? '',
    delayTime: j['DelayTime'] ?? '沒有',
    direction: j['Direction']?.toString() ?? '0',
    tripDuration: j['TripDuration'] ?? '沒有',
    timetable: (j['Timetable'] as List<dynamic>?)
        ?.map((e) => TimetableStop.fromJson(e as Map<String, dynamic>))
        .toList() ??
        [],
  );
}

class UbikeEntry {
  final String stationUid;
  final String stationName;
  final int availableRentBikes;
  final int availableReturnBikes;
  final bool isActive;

  const UbikeEntry({
    required this.stationUid,
    required this.stationName,
    required this.availableRentBikes,
    required this.availableReturnBikes,
    required this.isActive,
  });

  factory UbikeEntry.fromJson(Map<String, dynamic> j) => UbikeEntry(
    stationUid: j['StationUID'] ?? '',
    stationName: j['StationName'] ?? '',
    availableRentBikes: (j['AvailableRentBikes'] as num?)?.toInt() ?? 0,
    availableReturnBikes: (j['AvailableReturnBikes'] as num?)?.toInt() ?? 0,
    isActive: j['ServiceStatus'] == 1,
  );
}

class ParkingEntry {
  final String carParkId;
  final String carParkName;
  final String carParkType;
  final int spaceTotal;
  final int? remainingSpace;
  final String fareDescription;
  final String address;

  const ParkingEntry({
    required this.carParkId,
    required this.carParkName,
    required this.carParkType,
    required this.spaceTotal,
    this.remainingSpace,
    required this.fareDescription,
    required this.address,
  });

  factory ParkingEntry.fromJson(Map<String, dynamic> j) => ParkingEntry(
    carParkId: j['CarParkID'] ?? '',
    carParkName: j['CarParkName'] ?? '',
    carParkType: j['CarParkType'] ?? '',
    spaceTotal: (j['SpaceTotal'] as num?)?.toInt() ?? 0,
    remainingSpace: j['RemainingSpace'] != null
        ? (j['RemainingSpace'] as num).toInt()
        : null,
    fareDescription: j['FareDescription'] ?? '',
    address: j['Address'] ?? '',
  );
}

class WeatherEntry {
  final String locationId;
  final double? temperature;
  final int probabilityOfPrecipitation;
  final String? weather;
  final String? weatherCode;
  final int? relativeHumidity;

  const WeatherEntry({
    required this.locationId,
    this.temperature,
    required this.probabilityOfPrecipitation,
    this.weather,
    this.weatherCode,
    this.relativeHumidity,
  });

  factory WeatherEntry.fromJson(Map<String, dynamic> j) => WeatherEntry(
    locationId: j['LocationID'] ?? '',
    temperature: j['Temperature'] != null
        ? (j['Temperature'] as num).toDouble()
        : null,
    probabilityOfPrecipitation:
    (j['ProbabilityOfPrecipitation'] as num?)?.toInt() ?? 0,
    weather: j['Weather'],
    weatherCode: j['WeatherCode'],
    relativeHumidity: j['RelativeHumidity'] != null
        ? (j['RelativeHumidity'] as num).toInt()
        : null,
  );
}

// ══════════════════════════════════════════════════════════════
//  TrafficApiService（緩存版）
// ══════════════════════════════════════════════════════════════
class TrafficApiService {
  static final TrafficApiService _instance = TrafficApiService._();
  factory TrafficApiService() => _instance;
  TrafficApiService._();

  final _client = http.Client();

  // ── 本地緩存 store ───────────────────────────────────────────
  // key: 'bus' | 'busRoutes' | 'train' | 'ubike' | 'parking' | 'weather'
  final Map<String, _CacheEntry<dynamic>> _cache = {};

  // ── 各 key 的本地 TTL（秒）與 server 路徑 ───────────────────
  //  本地 TTL 設成跟 server TTL 一樣：
  //  Flutter 若在 TTL 內切換頁面回來，直接用本地緩存，完全不打 server。
  static const Map<String, int> _localTtl = {
    'bus':       60,
    'busRoutes': 60,
    'train':     90,
    'ubike':    180,
    'parking':   60,
    'weather':  600,
  };

  // ── 最新 meta（供 UI 顯示更新時間）──────────────────────────
  CacheMeta? latestMeta(String key) => _cache[key]?.meta;

  // ── 清除所有本地緩存（供手動強制刷新）────────────────────────
  void clearCache() => _cache.clear();

  // ── 清除單一 key 的本地緩存 ────────────────────────────────
  void clearKey(String key) => _cache.remove(key);

  // ══════════════════════════════════════════════════════════
  //  底層 HTTP
  // ══════════════════════════════════════════════════════════
  Future<dynamic> _getRaw(String path, {bool force = false}) async {
    final uri = Uri.parse('$kApiBase$path${force ? '?force=true' : ''}');
    final res = await _client.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes));
    throw Exception('API 錯誤 [$path]: HTTP ${res.statusCode}');
  }

  // ══════════════════════════════════════════════════════════
  //  核心緩存邏輯
  // ══════════════════════════════════════════════════════════
  Future<T> _cachedGet<T>({
    required String cacheKey,
    required String apiPath,
    required T Function(dynamic json) parser,
    bool forceRefresh = false,
  }) async {
    final ttl = _localTtl[cacheKey] ?? 60;

    // 1. 本地緩存命中（且非強制刷新）
    if (!forceRefresh) {
      final entry = _cache[cacheKey];
      if (entry != null && !entry.isExpired) {
        return entry.data as T;
      }
    }

    // 2. 打 server（server 自己也有緩存，只有 JSON 檔更新時才會重讀）
    final json = await _getRaw(apiPath, force: forceRefresh);

    // 3. 解析 server 回的 _cache meta
    bool serverHit = false;
    dynamic rawData = json;
    if (json is Map<String, dynamic>) {
      final cacheMeta = json['_cache'];
      if (cacheMeta is Map) {
        serverHit = cacheMeta['from_cache'] == true;
      }
      // 判斷格式：有 data key 就取 data，否則整個 map 給 parser 處理
      if (json.containsKey('data')) {
        rawData = json['data'];
      } else {
        // 把 _cache 移除，剩下的給 parser
        rawData = Map.from(json)..remove('_cache');
      }
    }

    final parsed = parser(rawData);

    // 4. 存本地緩存
    _cache[cacheKey] = _CacheEntry(
      parsed,
      CacheMeta(
        fetchedAt: DateTime.now(),
        ttlSeconds: ttl,
        serverCacheHit: serverHit,
      ),
    );

    return parsed;
  }

  // ══════════════════════════════════════════════════════════
  //  公開 fetch 方法（都有 forceRefresh 參數）
  // ══════════════════════════════════════════════════════════

  Future<List<BusEntry>> fetchBus({bool forceRefresh = false}) =>
      _cachedGet<List<BusEntry>>(
        cacheKey: 'bus',
        apiPath: '/api/bus',
        forceRefresh: forceRefresh,
        parser: (json) {
          if (json is Map) {
            final vehicles = json['Vehicles'] as List<dynamic>? ?? [];
            return vehicles
                .map((e) => BusEntry.fromJson(e as Map<String, dynamic>))
                .toList();
          }
          return (json as List)
              .map((e) => BusEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        },
      );

  Future<List<Map<String, dynamic>>> fetchBusRoutes(
      {bool forceRefresh = false}) =>
      _cachedGet<List<Map<String, dynamic>>>(
        cacheKey: 'busRoutes',
        apiPath: '/api/bus',
        forceRefresh: forceRefresh,
        parser: (json) {
          if (json is Map) {
            final routes = json['Routes'] as List<dynamic>? ?? [];
            return routes
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
          return <Map<String, dynamic>>[];
        },
      );

  Future<List<TrainEntry>> fetchTrain({bool forceRefresh = false}) =>
      _cachedGet<List<TrainEntry>>(
        cacheKey: 'train',
        apiPath: '/api/train',
        forceRefresh: forceRefresh,
        parser: (json) =>
            (json as List).map((e) => TrainEntry.fromJson(e)).toList(),
      );

  Future<List<UbikeEntry>> fetchUbike({bool forceRefresh = false}) =>
      _cachedGet<List<UbikeEntry>>(
        cacheKey: 'ubike',
        apiPath: '/api/ubike',
        forceRefresh: forceRefresh,
        parser: (json) =>
            (json as List).map((e) => UbikeEntry.fromJson(e)).toList(),
      );

  Future<List<ParkingEntry>> fetchParking({bool forceRefresh = false}) =>
      _cachedGet<List<ParkingEntry>>(
        cacheKey: 'parking',
        apiPath: '/api/parking',
        forceRefresh: forceRefresh,
        parser: (json) =>
            (json as List).map((e) => ParkingEntry.fromJson(e)).toList(),
      );

  Future<List<WeatherEntry>> fetchWeather({bool forceRefresh = false}) =>
      _cachedGet<List<WeatherEntry>>(
        cacheKey: 'weather',
        apiPath: '/api/weather',
        forceRefresh: forceRefresh,
        parser: (json) =>
            (json as List).map((e) => WeatherEntry.fromJson(e)).toList(),
      );

  // 取得原始 JSON（供地圖標記使用，保留完整欄位如座標）
  Future<dynamic> getRaw(String path) => _getRaw(path);
}