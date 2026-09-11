// ═══════════════════════════════════════════════════════════════
//  weather_service.dart
//  優先用 GPS + OpenWeatherMap 取得當前位置即時天氣
//  失敗時 fallback 到 FastAPI server（嘉義市東區預報）
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

// ── 天氣資料模型 ────────────────────────────────────────────────
class WeatherData {
  final String locationId;
  final double? temperature;
  final int precipitation;
  final String? weather;
  final String weatherCode;
  final int? humidity;
  final DateTime fetchedAt;

  const WeatherData({
    required this.locationId,
    this.temperature,
    required this.precipitation,
    this.weather,
    required this.weatherCode,
    this.humidity,
    required this.fetchedAt,
  });

  /// 從 OpenWeatherMap /weather 建立
  factory WeatherData.fromOwm(Map<String, dynamic> j) {
    final main        = j['main']    as Map<String, dynamic>? ?? {};
    final weatherList = j['weather'] as List<dynamic>?        ?? [];
    final wi          = weatherList.isNotEmpty ? weatherList.first as Map<String, dynamic> : <String, dynamic>{};
    final rain        = j['rain']    as Map<String, dynamic>?;

    final double? temp  = (main['temp'] as num?)?.toDouble();
    final int     owmId = (wi['id']   as num?)?.toInt() ?? 800;

    int precip = 0;
    if (rain != null && (rain['1h'] as num? ?? 0) > 0) {
      precip = 80;
    } else if (owmId >= 200 && owmId < 700) {
      precip = 60;
    }

    return WeatherData(
      locationId:    j['name']?.toString() ?? '目前位置',
      temperature:   temp,
      precipitation: precip,
      weather:       wi['description']?.toString(),
      weatherCode:   _owmIdToCode(owmId),
      humidity:      (main['humidity'] as num?)?.toInt(),
      fetchedAt:     DateTime.now(),
    );
  }

  /// 從 FastAPI server 格式建立（fallback 用）
  factory WeatherData.fromFastApi(Map<String, dynamic> j) {
    double? temp;
    if (j['Temperature'] != null) temp = double.tryParse(j['Temperature'].toString());
    int precip = 0;
    if (j['ProbabilityOfPrecipitation'] != null) {
      precip = int.tryParse(j['ProbabilityOfPrecipitation'].toString()) ?? 0;
    }
    int? hum;
    if (j['RelativeHumidity'] != null) hum = int.tryParse(j['RelativeHumidity'].toString());
    return WeatherData(
      locationId:    j['LocationID']?.toString() ?? '',
      temperature:   temp,
      precipitation: precip,
      weather:       j['Weather']?.toString(),
      weatherCode:   j['WeatherCode']?.toString() ?? '01',
      humidity:      hum,
      fetchedAt:     DateTime.now(),
    );
  }

  static String _owmIdToCode(int id) {
    if (id == 800)                    return '01';
    if (id == 801)                    return '02';
    if (id == 802)                    return '03';
    if (id == 803 || id == 804)       return '04';
    if (id >= 300 && id < 400)        return '08';
    if (id >= 500 && id < 510)        return '09';
    if (id == 511)                    return '12';
    if (id >= 520 && id < 532)        return '08';
    if (id >= 200 && id < 300)        return '15';
    if (id >= 600 && id < 700)        return '11';
    return '04';
  }

  // ── UI getter（home_screen.dart 完全不用動）──────────────────

  bool get isRainy =>
      precipitation >= 40 ||
          (weather != null && (weather!.contains('雨') || weather!.contains('雷')));

  bool get isPrepareRainy => precipitation >= 30;

  String get displayTemp => temperature != null ? '${temperature!.round()}°C' : '--°C';

  String get displayDesc => weather ?? _codeToDesc(weatherCode);

  IconData get weatherIcon  => _codeToIcon(weatherCode);
  Color    get weatherColor => _codeToColor(weatherCode);
  String   get weatherEmoji => _codeToEmoji(weatherCode);

  static String _codeToDesc(String code) {
    switch (code) {
      case '01': return '晴天';      case '02': return '晴時多雲';
      case '03': return '多雲時晴';  case '04': return '多雲';
      case '05': return '多雲時陰';  case '06': return '陰時多雲';
      case '07': return '陰天';      case '08': return '短暫陣雨';
      case '09': return '陣雨';      case '10': return '短暫雨';
      case '11': return '雨天';      case '12': return '大雨';
      case '13': return '豪雨';      case '14': return '短暫雷雨';
      case '15': return '雷陣雨';    case '16': return '大雷雨';
      default:   return '多雲';
    }
  }

  static IconData _codeToIcon(String code) {
    final c = int.tryParse(code) ?? 1;
    if (c == 1)  return Icons.wb_sunny_rounded;
    if (c <= 4)  return Icons.wb_cloudy_rounded;
    if (c <= 7)  return Icons.cloud_rounded;
    if (c >= 14) return Icons.thunderstorm_rounded;
    return Icons.grain_rounded;
  }

  static Color _codeToColor(String code) {
    final c = int.tryParse(code) ?? 1;
    if (c == 1)  return const Color(0xFFFFB347);
    if (c <= 4)  return const Color(0xFF8BAA88);
    if (c <= 7)  return const Color(0xFF9E9182);
    return const Color(0xFF7FA3B0);
  }

  static String _codeToEmoji(String code) {
    final c = int.tryParse(code) ?? 1;
    if (c == 1)  return '☀️';
    if (c <= 3)  return '🌤️';
    if (c <= 7)  return '☁️';
    if (c >= 14) return '⛈️';
    return '🌧️';
  }

  String get rainAlternativePrompt =>
      '今天天氣：$displayDesc，降雨機率 ${precipitation}%，氣溫 $displayTemp。'
          '請為原本的戶外行程提供 3 個室內或雨天備案景點/活動建議，'
          '以繁體中文條列，每條含景點名稱與簡短說明（50字以內），格式：\n'
          '1. 【景點名】- 說明\n2. 【景點名】- 說明\n3. 【景點名】- 說明';
}

// ── WeatherService 單例 ─────────────────────────────────────────
class WeatherService {
  static WeatherService? _instance;
  static WeatherService get instance => _instance ??= WeatherService._();
  WeatherService._();

  // OWM
  static const String _owmApiKey = 'YOUR_OPENWEATHERMAP_API_KEY';
  static const String _owmBase   = 'https://api.openweathermap.org/data/2.5/weather';

  // FastAPI fallback
  static const String _fapiEndpoint = 'http://10.0.2.2:8000/api/weather';

  static const String _cacheKey      = 'weather_cache_json';
  static const String _cacheTsKey    = 'weather_cache_ts';
  static const int    _cacheTtlMinutes = 30;

  WeatherData? _cached;
  DateTime?    _lastFetch;

  Future<WeatherData?> getChiayiWeather({bool forceRefresh = false}) async {
    // 記憶體快取
    if (!forceRefresh && _cached != null && _lastFetch != null) {
      if (DateTime.now().difference(_lastFetch!).inMinutes < _cacheTtlMinutes) {
        return _cached;
      }
    }
    // 磁碟快取
    if (!forceRefresh) {
      final fromDisk = await _loadFromDisk();
      if (fromDisk != null) {
        _cached = fromDisk;
        _lastFetch = DateTime.now();
        return fromDisk;
      }
    }

    // ① 嘗試 GPS + OWM
    WeatherData? data = await _tryOwm();

    // ② OWM 失敗 → fallback FastAPI
    if (data == null) {
      debugPrint('⚠️ [Weather] OWM 失敗，改用 FastAPI server');
      data = await _tryFastApi();
    }

    if (data != null) {
      _cached    = data;
      _lastFetch = DateTime.now();
      await _saveToDisk(data);
    }

    return data ?? _cached ?? await _loadFromDisk(ignoreExpiry: true);
  }

  // ── GPS + OWM ────────────────────────────────────────────────
  Future<WeatherData?> _tryOwm() async {
    try {
      final pos = await _getPosition();
      if (pos == null) return null;
      final uri = Uri.parse(
        '$_owmBase?lat=${pos.latitude}&lon=${pos.longitude}'
            '&appid=$_owmApiKey&units=metric&lang=zh_tw',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        return WeatherData.fromOwm(jsonDecode(resp.body) as Map<String, dynamic>);
      }
      debugPrint('⚠️ [OWM] status ${resp.statusCode}');
    } catch (e) {
      debugPrint('⚠️ [OWM] $e');
    }
    return null;
  }

  Future<Position?> _getPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return null;
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
      timeLimit: const Duration(seconds: 10),
    );
  }

  // ── FastAPI fallback ─────────────────────────────────────────
  Future<WeatherData?> _tryFastApi() async {
    try {
      final resp = await http.get(Uri.parse(_fapiEndpoint))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final List<dynamic> list = decoded is List
            ? decoded
            : (decoded['data'] as List<dynamic>? ?? []);
        if (list.isEmpty) return null;
        for (final target in ['嘉義市_東區', '嘉義市_西區', '嘉義市']) {
          final match = list.firstWhere(
                (j) => (j['LocationID'] as String? ?? '').startsWith(target),
            orElse: () => null,
          );
          if (match != null) {
            return WeatherData.fromFastApi(match as Map<String, dynamic>);
          }
        }
        return WeatherData.fromFastApi(list.first as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('⚠️ [FastAPI] $e');
    }
    return null;
  }

  // ── 磁碟快取 ─────────────────────────────────────────────────
  Future<WeatherData?> _loadFromDisk({bool ignoreExpiry = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts   = prefs.getInt(_cacheTsKey);
      final json = prefs.getString(_cacheKey);
      if (ts == null || json == null) return null;
      if (!ignoreExpiry) {
        if (DateTime.now().millisecondsSinceEpoch - ts >
            _cacheTtlMinutes * 60 * 1000) return null;
      }
      final m = jsonDecode(json) as Map<String, dynamic>;
      return WeatherData(
        locationId:    m['locationId']    ?? '',
        temperature:   (m['temperature'] as num?)?.toDouble(),
        precipitation: m['precipitation'] ?? 0,
        weather:       m['weather'],
        weatherCode:   m['weatherCode']   ?? '01',
        humidity:      m['humidity'],
        fetchedAt:     DateTime.fromMillisecondsSinceEpoch(ts),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToDisk(WeatherData d) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode({
        'locationId':    d.locationId,
        'temperature':   d.temperature,
        'precipitation': d.precipitation,
        'weather':       d.weather,
        'weatherCode':   d.weatherCode,
        'humidity':      d.humidity,
      }));
      await prefs.setInt(_cacheTsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  void clearCache() {
    _cached    = null;
    _lastFetch = null;
  }
}