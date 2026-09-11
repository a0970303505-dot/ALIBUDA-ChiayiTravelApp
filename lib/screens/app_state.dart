// 檔案：app_state.dart
import 'package:flutter/material.dart';

class AppStateManager {
  // ─── 給 Home、Favorites、Profile 切換底部 Tab 用的 ───
  static final ValueNotifier<int> currentTabNotifier = ValueNotifier<int>(0);

  // ─── 以下全部都是給 AI 頁面專用的 ───
  static final ValueNotifier<List<String>?> aiFavoritesNotifier =
  ValueNotifier<List<String>?>(null);

  static final ValueNotifier<List<Map<String, dynamic>>?> aiItineraryPoiNotifier =
  ValueNotifier<List<Map<String, dynamic>>?>(null);

  static final ValueNotifier<Map<String, dynamic>?> aiGeneratedTripNotifier =
  ValueNotifier<Map<String, dynamic>?>(null);
}