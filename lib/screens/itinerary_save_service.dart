// ═══════════════════════════════════════════════════════════════
//  itinerary_save_service.dart
//  行程存檔輔助服務
//  當 AI 生成完行程後，解析文字 → 建立 SavedItinerary → 存到本地
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'local_db_service.dart';
import 'firebase_sync_service.dart';

class ItinerarySaveService {
  static ItinerarySaveService? _instance;
  static ItinerarySaveService get instance => _instance ??= ItinerarySaveService._();
  ItinerarySaveService._();

  // ── 從 AI 文字行程建立並儲存 ─────────────────────────────────
  // ★ aiText 必須是符合 _parseSavedItineraries 期望的 JSON 字串：
  //   [ { "dayLabel": "Day 1", "items": [ { "time":..., "title":..., "lat":..., "lon":..., ... } ] } ]
  Future<String> saveAiItinerary({
    required String aiText,
    required int days,
    required String title,
    int estimatedBudget = 0,
    String userId = '',           // ★ 新增 userId
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now();

    String plansJson;
    try {
      final decoded = jsonDecode(aiText);
      if (decoded is List) {
        for (final d in decoded) {
          if (d is! Map || d['dayLabel'] == null || d['items'] == null) {
            throw const FormatException('invalid day structure');
          }
        }
        plansJson = aiText;
      } else {
        throw const FormatException('not a list');
      }
    } catch (_) {
      final fallback = List.generate(days, (i) => {
        'dayLabel': 'Day ${i + 1}',
        'items': <Map<String, dynamic>>[],
      });
      plansJson = jsonEncode(fallback);
    }

    final itinerary = SavedItinerary(
      id: id,
      userId: userId,             // ★
      title: title,
      estimatedBudget: estimatedBudget,
      startDate: now,
      endDate: now.add(Duration(days: days - 1)),
      plansJson: plansJson,
      isFromAi: true,
      createdAt: now,
      updatedAt: now,
    );

    await FirebaseSyncService.instance.saveItinerary(itinerary);
    debugPrint('✅ AI 行程已儲存並同步：$title (id=$id)');
    return id;
  }

  Future<String> saveManualItinerary({
    required String title,
    required int estimatedBudget,
    required DateTime startDate,
    required DateTime endDate,
    required List<Map<String, dynamic>> plans,
    String? id,
    bool isFromAi = false,
    String userId = '',           // ★ 新增 userId
  }) async {
    final resolvedId = id ?? const Uuid().v4();
    final now = DateTime.now();

    final itinerary = SavedItinerary(
      id: resolvedId,
      userId: userId,             // ★
      title: title,
      estimatedBudget: estimatedBudget,
      startDate: startDate,
      endDate: endDate,
      plansJson: jsonEncode(plans),
      isFromAi: isFromAi,
      createdAt: now,
      updatedAt: now,
    );

    await FirebaseSyncService.instance.saveItinerary(itinerary);
    debugPrint('✅ 行程已儲存並同步：$title (id=$resolvedId, userId=$userId)');
    return resolvedId;
  }

  // ── 更新行程 ────────────────────────────────────────────────
  Future<void> updateItinerary({
    required String id,
    required String title,
    required int estimatedBudget,
    required DateTime startDate,
    required DateTime endDate,
    required List<Map<String, dynamic>> plans,
  }) async {
    final existing = await LocalDbService.instance.getItinerary(id);
    if (existing == null) return;

    final updated = SavedItinerary(
      id: id,
      userId: existing.userId,   // ★ 必須帶入原本的 userId，否則存回去變空字串撈不到
      title: title,
      estimatedBudget: estimatedBudget,
      startDate: startDate,
      endDate: endDate,
      plansJson: jsonEncode(plans),
      isFromAi: existing.isFromAi,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );

    // ★ 改用 FirebaseSyncService：本地 + 雲端同時寫
    await FirebaseSyncService.instance.updateItinerary(updated);
    debugPrint('✅ 行程已更新並同步：$title (id=$id)');
  }

  // ── ItineraryItem → JSON Map (for saving) ────────────────────
  // 用於在 map_screen.dart 中將 ItineraryItem 序列化
  static Map<String, dynamic> itineraryItemToMap(dynamic item) {
    return {
      'time': item.time,
      'title': item.title,
      'location': item.location,
      'duration': item.duration,
      'transportTimes': {
        'car': item.transportTimes['car'] ?? '10min',
        'transit': item.transportTimes['transit'] ?? '15min',
        'bike': item.transportTimes['bike'] ?? '10min',
        'walk': item.transportTimes['walk'] ?? '20min',
      },
      'selectedTransport': item.selectedTransport.name,
      'tips': item.tips,
      'ticket': item.ticket,
      'lat': item.mapPosition.latitude,
      'lon': item.mapPosition.longitude,
    };
  }
}