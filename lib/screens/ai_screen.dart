// ═══════════════════════════════════════════════════════════════
//  ai_screen.dart  (完整重寫版 v3 - 專屬頭貼快取同步版)
//  新增功能：
//  1. 側邊欄與對話氣泡完美套用真實雲端頭貼 (移除小丑🤡與火雞🦃)
//  2. 導入 0 秒無閃爍快取頭貼元件 _UserAvatar
// ═══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_db_service.dart';
import 'itinerary_save_service.dart';
import 'map_screen.dart' show PoiMarker;  // 只引入 PoiMarker 做跳轉用
import 'app_state.dart';
import 'system_settings_screen.dart';
import 'help_support_screen.dart';
import 'login_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  全域狀態
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
//  從 Firebase 直接讀取雲端頭像 (完全防閃爍版)
// ═══════════════════════════════════════════════════════════════
class _UserAvatar extends StatefulWidget {
  final User? user;
  final double radius;
  const _UserAvatar({required this.user, this.radius = 20});

  @override
  State<_UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<_UserAvatar> {
  bool _isLoading = true;
  Uint8List? _cloudAvatarBytes;
  String? _cloudPhotoUrl;

  @override
  void initState() {
    super.initState();
    _loadAvatarWithCache();
  }

  Future<void> _loadAvatarWithCache() async {
    if (widget.user == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'avatar_cache_${widget.user!.uid}';

      final cachedBase64 = prefs.getString(cacheKey);
      if (cachedBase64 != null && cachedBase64.isNotEmpty) {
        if (mounted) {
          setState(() {
            _cloudAvatarBytes = base64Decode(cachedBase64);
          });
        }
      }

      final querySnap = await FirebaseFirestore.instance
          .collection('users')
          .where('uid', isEqualTo: widget.user!.uid)
          .limit(1)
          .get();

      if (querySnap.docs.isNotEmpty) {
        final data = querySnap.docs.first.data();

        if (data.containsKey('avatarBase64') && (data['avatarBase64'] as String).isNotEmpty) {
          final cloudBase64 = data['avatarBase64'] as String;
          if (cloudBase64 != cachedBase64) {
            await prefs.setString(cacheKey, cloudBase64);
            if (mounted) {
              setState(() {
                _cloudAvatarBytes = base64Decode(cloudBase64);
              });
            }
          }
        } else {
          await prefs.remove(cacheKey);
        }

        if (data.containsKey('photoUrl') && mounted) {
          setState(() {
            _cloudPhotoUrl = data['photoUrl'];
          });
        }
      }
    } catch (e) {
      debugPrint('讀取頭像失敗: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoUrl = _cloudPhotoUrl ?? widget.user?.photoURL;
    final name = widget.user?.displayName ?? widget.user?.email ?? '旅';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '旅';

    if (_isLoading) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundColor: const Color(0xFF8BAA88),
        child: Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)),
      );
    }

    ImageProvider? finalImage;
    if (_cloudAvatarBytes != null) {
      finalImage = MemoryImage(_cloudAvatarBytes!);
    } else if (!_isLoading && photoUrl != null && photoUrl.isNotEmpty) {
      finalImage = NetworkImage(photoUrl);
    }

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF8BAA88),
      backgroundImage: finalImage,
      child: finalImage == null ? Text(initial, style: TextStyle(color: Colors.white, fontSize: widget.radius * 0.8, fontWeight: FontWeight.bold)) : null,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Gemini AI 服務層
// ═══════════════════════════════════════════════════════════════
class GeminiService {
  static GeminiService? _instance;
  static GeminiService get instance => _instance ??= GeminiService._();

  static const String _apiKey = 'YOUR_GEMINI_API_KEY';  // ← 替換為你的 Key
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent';

  static const String _generalSystemPrompt =
      '你是嘉義旅遊專屬 AI 助手「阿布」。'
      '你對嘉義的景點（阿里山、奮起湖、檜意森活村、嘉義公園、北回歸線標誌公園等）、'
      '美食（雞肉飯、方塊酥、火雞肉飯、阿里山茶、砂鍋魚頭等）、'
      '住宿、交通、文化歷史非常熟悉。'
      '回答時請使用繁體中文，語氣親切活潑，可以適當使用 emoji，'
      '回答精簡有重點，不要過長，避免太多條列式清單。'
      '如果用戶問的不是嘉義相關問題，你可以正常回答，但要帶回嘉義旅遊的話題。'
      '用戶隨時可以插話問任何問題，請自然回應再繼續原本話題。';

  static const String _itinerarySystemPrompt =
      '你是嘉義旅遊專屬 AI 助手「阿布」，任務是協助用戶規劃嘉義旅遊行程。\n'
      '請依序、自然地收集以下 7 項資訊（每次只問一個問題）：\n'
      '1. 旅遊天數；2. 人數（大人/小孩）；3. 總預算；4. 交通方式；5. 旅遊風格；6. 特殊需求；7. 出發地點（從哪裡出發，用於計算交通時間）。\n'
      '【重要】用戶可以隨時插話問其他問題，自然回答後繼續收集資訊，不要重置進度。\n'
      '當你收集完所有 7 項資訊後，先用 2～3 句話親切總結行程亮點，\n'
      '然後輸出一個 JSON 區塊（用 ```json 和 ``` 包起來），格式如下：\n'
      '```json\n'
      '{\n'
      '  "title": "行程標題",\n'
      '  "budget": 3000,\n'
      '  "departure": "出發地點名稱",\n'
      '  "days": [\n'
      '    {\n'
      '      "dayLabel": "Day 1",\n'
      '      "items": [\n'
      '        {\n'
      '          "time": "08:30",\n'
      '          "title": "早餐 - 劉里長雞肉飯",\n'
      '          "location": "嘉義市東區公明路190號",\n'
      '          "category": "餐廳",\n'
      '          "duration": "1 小時",\n'
      '          "transport": "transit",\n'
      '          "transport_from": "出發地點",\n'
      '          "transport_minutes_car": 15,\n'
      '          "transport_minutes_transit": 25,\n'
      '          "transport_minutes_bike": 20,\n'
      '          "transport_minutes_walk": 40,\n'
      '          "tips": "建議一開門就去，人潮較少",\n'
      '          "ticket": null\n'
      '        },\n'
      '        {\n'
      '          "time": "10:00",\n'
      '          "title": "檜意森活村",\n'
      '          "location": "嘉義市東區林森東路1號",\n'
      '          "category": "景點",\n'
      '          "duration": "1.5 小時",\n'
      '          "transport": "walk",\n'
      '          "transport_from": "劉里長雞肉飯",\n'
      '          "transport_minutes_car": 5,\n'
      '          "transport_minutes_transit": 8,\n'
      '          "transport_minutes_bike": 6,\n'
      '          "transport_minutes_walk": 12,\n'
      '          "tips": "日式木造建築群，假日有市集",\n'
      '          "ticket": null\n'
      '        }\n'
      '      ]\n'
      '    }\n'
      '  ]\n'
      '}\n'
      '```\n'
      '[ITINERARY_COMPLETE]\n\n'
      '【行程安排規則 - 非常重要，必須嚴格遵守】\n'
      '1. 每天必須安排 6～8 個項目，從早上出發到晚上結束，時間要排到 21:00 以後才合理\n'
      '2. 早上出發時間隨機在 07:30～09:30 之間（每天可不同）\n'
      '3. 每天必須包含：早餐(category=餐廳)、上午景點 1～2 個(category=景點)、午餐(category=餐廳)、下午景點 1～2 個(category=景點)、晚餐(category=餐廳)、晚上活動或夜市(category=景點)\n'
      '4. 若行程超過 1 天，最後一天必須安排住宿(category=住宿)，請推薦嘉義真實旅館/民宿名稱\n'
      '5. transport_from 是「從哪裡出發到這一站」，第一站填收集到的出發地點，之後填上一站名稱\n'
      '6. transport_minutes_car/transit/bike/walk 填入從 transport_from 到本站的預估分鐘數(整數)\n'
      '7. transport 建議值：car/transit/bike/walk，依照用戶說的交通方式填入最適合的\n'
      '8. ticket 若免費填 null，有費用填「全票 XX 元」格式\n'
      '9. 景點、餐廳、住宿都要用嘉義真實地名，不可虛構\n'
      '10. 使用繁體中文，語氣親切，適當使用 emoji\n'
      '11. JSON 後緊接 [ITINERARY_COMPLETE] 標記，不可省略\n'
      '12. 🌟【絕對強制】如果對話紀錄的開場白或過程中，有提到用戶「已經挑選了」某些景點、美食或住宿，你「必須、一定、絕對」要把這些地點全部安排進最後生成的行程 JSON 中！';

  GeminiService._();

  Future<String> sendMessage({
    required String mode,
    required List<ChatMessage> chatHistory,
  }) async {
    final systemPrompt = mode == 'itinerary' ? _itinerarySystemPrompt : _generalSystemPrompt;

    final history = <Map<String, dynamic>>[];
    for (var msg in chatHistory) {
      if (msg.text.isNotEmpty && msg.type != ChatMessageType.tripCard && msg.type != ChatMessageType.recommendation) {
        history.add({
          'role': msg.isUser ? 'user' : 'model',
          'parts': [{'text': msg.text}],
        });
      }
    }

    if (history.isNotEmpty && history.first['role'] == 'model') {
      history.insert(0, {
        'role': 'user',
        'parts': [{'text': '哈囉，我想請你幫忙！'}]
      });
    }

    if (history.isEmpty) {
      history.add({'role': 'user', 'parts': [{'text': '你好'}]});
    }

    final body = jsonEncode({
      'system_instruction': {
        'parts': [{'text': systemPrompt}]
      },
      'contents': history,
      'generationConfig': {
        'temperature': 0.8,
        'maxOutputTokens': 4096,
      },
    });

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['candidates'][0]['content']['parts'][0]['text'] as String;
        return reply;
      } else {
        return '連線問題 (${response.statusCode})，請稍後再試 🙏';
      }
    } catch (e) {
      return '哎呀！網路好像有點問題，請稍後再試 🙏';
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  資料模型
// ═══════════════════════════════════════════════════════════════
enum ChatMessageType { text, tripCard, recommendation }
enum ChatMode { none, general, itinerary }

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final ChatMessageType type;
  final String? recType;
  final List<Map<String, dynamic>>? attractionCards;

  ChatMessage({
    String? id,
    required this.isUser,
    required this.text,
    this.type = ChatMessageType.text,
    this.recType,
    this.attractionCards,
  }) : id = id ?? const Uuid().v4();
}

// ═══════════════════════════════════════════════════════════════
//  AiScreen 主頁
// ═══════════════════════════════════════════════════════════════
class AiScreen extends StatefulWidget {
  final List<String>? selectedFavorites;
  const AiScreen({super.key, this.selectedFavorites});

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late AnimationController _breathingController;

  ChatMode _currentMode = ChatMode.none;
  String? _currentSessionId;

  List<ChatSession> _allSessions = [];
  List<ChatMessage> _currentMessages = [];

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> _pendingFavorites = [];
  bool _isLoading = false;

  Map<String, dynamic> _attractionsData = {};
  bool _attractionsLoaded = false;
  List<dynamic> _foodData = [];
  bool _foodLoaded = false;
  List<dynamic> _hotelData = [];
  bool _hotelLoaded = false;

  @override
  void initState() {
    super.initState();
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _loadSessions();
    _loadAttractionsData();
    _loadFoodData();
    _loadHotelData();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AppStateManager.aiFavoritesNotifier.value?.isNotEmpty == true) {
        _processIncomingFavorites(AppStateManager.aiFavoritesNotifier.value!);
      }
    });

    AppStateManager.aiFavoritesNotifier.addListener(_listenToFavoritesSync);
  }

  @override
  void dispose() {
    AppStateManager.aiFavoritesNotifier.removeListener(_listenToFavoritesSync);
    _textController.dispose();
    _scrollController.dispose();
    _breathingController.dispose();
    super.dispose();
  }

  Future<void> _loadAttractionsData() async {
    try {
      final raw = await rootBundle.loadString('assets/data/attractions_fixed_final.json');
      _attractionsData = json.decode(raw) as Map<String, dynamic>;
      _attractionsLoaded = true;
    } catch (e) {
      debugPrint('⚠️ 載入景點資料失敗：$e');
    }
  }

  Future<void> _loadFoodData() async {
    try {
      final raw = await rootBundle.loadString('assets/data/app_restaurants.json');
      _foodData = json.decode(raw) as List<dynamic>;
      _foodLoaded = true;
    } catch (e) {
      debugPrint('⚠️ 載入美食資料失敗：$e');
    }
  }

  Future<void> _loadHotelData() async {
    try {
      final raw = await rootBundle.loadString('assets/data/app_hotels.json');
      _hotelData = json.decode(raw) as List<dynamic>;
      _hotelLoaded = true;
    } catch (e) {
      debugPrint('⚠️ 載入住宿資料失敗：$e');
    }
  }

  Future<void> _loadSessions() async {
    final sessions = await LocalDbService.instance.getAllSessions();
    if (mounted) setState(() => _allSessions = sessions);
  }

  void _listenToFavoritesSync() {
    final places = AppStateManager.aiFavoritesNotifier.value;
    if (places != null && places.isNotEmpty) {
      _processIncomingFavorites(places);
    }
  }

  Future<void> _processIncomingFavorites(List<String> places) async {
    setState(() {
      _pendingFavorites = List.from(places);
    });
    AppStateManager.aiFavoritesNotifier.value = null;

    await _openNewChat(ChatMode.itinerary);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 已成功帶入收藏景點！開始您的專屬行程規劃！',
              style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
          backgroundColor: Color(0xFF8BAA88),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _openNewChat(ChatMode mode) async {
    final sessionId = const Uuid().v4();
    final modeStr = mode == ChatMode.itinerary ? 'itinerary' : 'general';

    final now = DateTime.now();
    final session = ChatSession(
      id: sessionId,
      mode: modeStr,
      title: mode == ChatMode.itinerary ? '行程規劃 ${_formatDate(now)}' : '一般對話 ${_formatDate(now)}',
      createdAt: now,
      updatedAt: now,
    );

    await LocalDbService.instance.insertSession(session);
    await _loadSessions();

    String openingText;
    if (mode == ChatMode.itinerary) {
      if (_pendingFavorites.isNotEmpty) {
        final names = _pendingFavorites.map((p) => '「$p」').join('、');
        openingText = '準備好探索嘉義了嗎？✨\n我看到您已經挑選了：\n$names\n\n為了幫您把這些喜愛的地點排進最完美的行程，請先告訴我：\n\n1️⃣ 您預計這趟旅行是「幾天幾夜」呢？';
        _pendingFavorites.clear();
      } else {
        openingText = '準備好探索嘉義了嗎？✨\n讓我為您量身打造專屬旅程！\n\n請先告訴我：\n1️⃣ 您預計旅遊「幾天幾夜」呢？';
      }
    } else {
      openingText = '哈囉！我是您的專屬 AI 助手阿布 🌿\n無論是關於嘉義的歷史文化、景點介紹，或是任何旅遊上的問題，我都在這裡為您解答！\n\n💡 您隨時可以點下方快捷鍵，或直接輸入問題。';
    }

    final openingMsg = ChatMessage(isUser: false, text: openingText);
    await _saveMessageToDB(sessionId, openingMsg);

    setState(() {
      _currentSessionId = sessionId;
      _currentMode = mode;
      _currentMessages = [openingMsg];
    });

    _scrollToBottom();
  }

  Future<void> _switchToSession(ChatSession session) async {
    final records = await LocalDbService.instance.getMessagesForSession(session.id);
    final msgs = records.map((r) {
      List<Map<String, dynamic>>? cards;
      if (r.messageType == 'recommendation' && r.text.isNotEmpty) {
        try {
          final decoded = jsonDecode(r.text) as List<dynamic>;
          cards = decoded.cast<Map<String, dynamic>>();
        } catch (_) {}
      }
      return ChatMessage(
        id: r.id,
        isUser: r.isUser,
        text: r.messageType == 'recommendation' ? '' : r.text,
        type: _parseMessageType(r.messageType),
        recType: r.recType,
        attractionCards: cards,
      );
    }).toList();

    setState(() {
      _currentSessionId = session.id;
      _currentMode = session.mode == 'itinerary' ? ChatMode.itinerary : ChatMode.general;
      _currentMessages = msgs;
    });

    Navigator.pop(context);
    _scrollToBottom();
  }

  ChatMessageType _parseMessageType(String? t) {
    if (t == 'tripCard') return ChatMessageType.tripCard;
    if (t == 'recommendation') return ChatMessageType.recommendation;
    return ChatMessageType.text;
  }

  Future<void> _saveMessageToDB(String sessionId, ChatMessage msg) async {
    final String textToSave =
    (msg.type == ChatMessageType.recommendation && msg.attractionCards != null)
        ? jsonEncode(msg.attractionCards)
        : msg.text;

    await LocalDbService.instance.insertMessage(ChatMessageRecord(
      id: msg.id,
      sessionId: sessionId,
      isUser: msg.isUser,
      text: textToSave,
      messageType: msg.type.name,
      recType: msg.recType,
      createdAt: DateTime.now(),
    ));
    await LocalDbService.instance.updateSessionTime(sessionId);
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isLoading) return;
    if (_currentSessionId == null) return;

    final userMsg = ChatMessage(isUser: true, text: text);
    await _saveMessageToDB(_currentSessionId!, userMsg);

    setState(() {
      _currentMessages.add(userMsg);
      _isLoading = true;
    });
    _textController.clear();
    _scrollToBottom();

    final reply = await GeminiService.instance.sendMessage(
      mode: _currentMode == ChatMode.itinerary ? 'itinerary' : 'general',
      chatHistory: _currentMessages,
    );

    if (!mounted) return;

    final isItineraryComplete = reply.contains('[ITINERARY_COMPLETE]');

    Map<String, dynamic>? parsedJson;
    String chatSummary = '';

    if (isItineraryComplete) {
      String raw = reply.replaceAll('[ITINERARY_COMPLETE]', '').trim();

      String? jsonStr;
      int jsonStart = -1;
      int jsonEnd   = -1;

      final tagA = '```json';
      final tagB = '```';
      final closingTag = '```';

      int openIdx = raw.indexOf(tagA);
      int afterOpen = openIdx >= 0 ? openIdx + tagA.length : -1;

      if (openIdx < 0) {
        openIdx = raw.indexOf(tagB);
        afterOpen = openIdx >= 0 ? openIdx + tagB.length : -1;
      }

      if (afterOpen >= 0) {
        final closeIdx = raw.indexOf(closingTag, afterOpen);
        if (closeIdx > afterOpen) {
          jsonStr   = raw.substring(afterOpen, closeIdx).trim();
          jsonStart = openIdx;
          jsonEnd   = closeIdx + closingTag.length;
        }
      }

      if (jsonStr == null) {
        final braceOpen = raw.indexOf('{\n  "title"');
        if (braceOpen < 0) {
          final braceOpen2 = raw.indexOf('{"title"');
          if (braceOpen2 >= 0) {
            final braceClose = raw.lastIndexOf('}');
            if (braceClose > braceOpen2) {
              jsonStr   = raw.substring(braceOpen2, braceClose + 1);
              jsonStart = braceOpen2;
              jsonEnd   = braceClose + 1;
            }
          }
        } else {
          final braceClose = raw.lastIndexOf('}');
          if (braceClose > braceOpen) {
            jsonStr   = raw.substring(braceOpen, braceClose + 1);
            jsonStart = braceOpen;
            jsonEnd   = braceClose + 1;
          }
        }
      }

      if (jsonStr != null && jsonStr.isNotEmpty) {
        try {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            parsedJson = decoded;
          }
        } catch (e) {
          debugPrint('⚠️ JSON 解析失敗: $e');
        }
      }

      if (jsonStart > 0) {
        chatSummary = raw.substring(0, jsonStart).trim();
      } else if (parsedJson != null) {
        chatSummary = '';
      } else {
        chatSummary = raw
            .split('\n')
            .where((line) =>
        !line.trimLeft().startsWith('```') &&
            !line.trimLeft().startsWith('{') &&
            !line.trimLeft().startsWith('"') &&
            !line.trimLeft().startsWith('}'))
            .join('\n')
            .trim();
      }
    } else {
      chatSummary = reply.trim();
    }

    if (chatSummary.isNotEmpty) {
      final aiMsg = ChatMessage(isUser: false, text: chatSummary);
      await _saveMessageToDB(_currentSessionId!, aiMsg);
      setState(() {
        _currentMessages.add(aiMsg);
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }

    if (isItineraryComplete) {
      if (parsedJson == null) {
        final errMsg = ChatMessage(
          isUser: false,
          text: '⚠️ 抱歉，行程資料解析失敗，請重新規劃行程！',
        );
        if (_currentSessionId != null) await _saveMessageToDB(_currentSessionId!, errMsg);
        setState(() => _currentMessages.add(errMsg));
        _scrollToBottom();
        return;
      }

      final title  = parsedJson['title']?.toString() ?? 'AI 嘉義行程 ${_formatDate(DateTime.now())}';
      final budget = parsedJson['budget'] is num ? (parsedJson['budget'] as num).toInt() : 0;
      final days   = parsedJson['days'] is List ? (parsedJson['days'] as List).length : 1;

      final tripData = _buildTripDataFromJson(parsedJson, title: title, budget: budget);

      await ItinerarySaveService.instance.saveAiItinerary(
        aiText: jsonEncode(tripData['days']),
        days: days,
        title: title,
        estimatedBudget: budget,
      );

      AppStateManager.aiGeneratedTripNotifier.value = tripData;

      await Future.delayed(const Duration(milliseconds: 300));

      final tripCard = ChatMessage(isUser: false, text: title, type: ChatMessageType.tripCard);
      await _saveMessageToDB(_currentSessionId!, tripCard);
      setState(() => _currentMessages.add(tripCard));
    }

    _scrollToBottom();
  }

  Map<String, dynamic> _buildTripDataFromJson(
      Map<String, dynamic> json, {required String title, required int budget}
      ) {
    final daysData = json['days'] as List<dynamic>? ?? [];
    final departure = json['departure']?.toString() ?? '';
    final List<Map<String, dynamic>> dayPlans = [];

    for (final d in daysData) {
      final dayLabel = d['dayLabel']?.toString() ?? 'Day ${dayPlans.length + 1}';
      final rawItems = d['items'] as List<dynamic>? ?? [];
      final List<Map<String, dynamic>> items = [];
      String prevLocation = departure;

      for (final item in rawItems) {
        final itemTitle    = item['title']?.toString() ?? '嘉義景點';
        final location     = item['location']?.toString() ?? itemTitle;
        final transport    = item['transport']?.toString() ?? 'transit';
        final ticket       = item['ticket']?.toString();
        final category     = item['category']?.toString() ?? '景點';
        final transportFrom = item['transport_from']?.toString() ?? prevLocation;

        final carMin     = (item['transport_minutes_car']     as num?)?.toInt() ?? 10;
        final transitMin = (item['transport_minutes_transit'] as num?)?.toInt() ?? 15;
        final bikeMin    = (item['transport_minutes_bike']    as num?)?.toInt() ?? 15;
        final walkMin    = (item['transport_minutes_walk']    as num?)?.toInt() ?? 25;

        final List<String> tipsList;
        final rawTips = item['tips'];
        if (rawTips is List) {
          tipsList = rawTips
              .where((t) => t != null && t.toString().trim().isNotEmpty)
              .map((t) => t.toString().trim())
              .toList();
        } else if (rawTips is String && rawTips.trim().isNotEmpty) {
          tipsList = [rawTips.trim()];
        } else {
          tipsList = [];
        }

        final matched = _matchPoiFromText(itemTitle) ?? _matchPoiFromText(location);

        items.add({
          'time':     item['time']?.toString() ?? '09:00',
          'title':    itemTitle,
          'location': matched?['location'] ?? location,
          'category': category,
          'duration': item['duration']?.toString() ?? '1.5 小時',
          'transport_from': transportFrom,
          'transportTimes': {
            'car':     '${carMin}min',
            'transit': '${transitMin}min',
            'bike':    '${bikeMin}min',
            'walk':    '${walkMin}min',
          },
          'selectedTransport': transport,
          'tips':   tipsList,
          'ticket': (ticket == 'null' || ticket == null) ? null : ticket,
          'lat': matched?['lat'] ?? 23.4800,
          'lon': matched?['lon'] ?? 120.4500,
        });

        prevLocation = itemTitle;
      }

      dayPlans.add({'dayLabel': dayLabel, 'items': items});
    }

    return {
      'title': title,
      'estimatedBudget': budget,
      'departure': departure,
      'days': dayPlans,
    };
  }

  Map<String, dynamic>? _matchPoiFromText(String text) {
    for (final entry in _attractionsData.entries) {
      final v = entry.value as Map<String, dynamic>;
      final name = v['AttractionName']?.toString() ?? '';
      if (name.isNotEmpty && text.contains(name.substring(0, math.min(name.length, 4)))) {
        return {
          'location': name,
          'lat': (v['PositionLat'] as num?)?.toDouble() ?? 23.4800,
          'lon': (v['PositionLon'] as num?)?.toDouble() ?? 120.4500,
        };
      }
    }
    for (final e in _foodData) {
      final v = e as Map<String, dynamic>;
      final name = v['RestaurantName']?.toString() ?? '';
      if (name.isNotEmpty && text.contains(name.substring(0, math.min(name.length, 4)))) {
        return {
          'location': name,
          'lat': (v['PositionLat'] as num?)?.toDouble() ?? 23.4800,
          'lon': (v['PositionLon'] as num?)?.toDouble() ?? 120.4500,
        };
      }
    }
    return null;
  }

  Future<void> _handleQuickAction(String action) async {
    if (_currentMode == ChatMode.none) {
      await _openNewChat(ChatMode.general);
      if (_currentSessionId == null) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (action == '推薦景點') {
      _showAttractionRecommendations();
    } else if (action == '推薦美食') {
      _showFoodRecommendations();
    } else if (action == '推薦住宿') {
      _showHotelRecommendations();
    } else {
      _sendMessage('請幫我$action');
    }
  }

  Future<void> _showAttractionRecommendations() async {
    if (!_attractionsLoaded || _attractionsData.isEmpty) {
      _sendMessage('請推薦嘉義景點');
      return;
    }

    final List<Map<String, dynamic>> cards = [];
    final entries = _attractionsData.entries.toList()..shuffle();
    for (final entry in entries) {
      final v = entry.value as Map<String, dynamic>;
      final images = v['Images'] as List<dynamic>?;
      if (images != null && images.isNotEmpty) {
        cards.add({
          'id': entry.key,
          ...v,
        });
        if (cards.length >= 5) break;
      }
    }

    final recMsg = ChatMessage(
      isUser: false,
      text: '',
      type: ChatMessageType.recommendation,
      recType: 'attraction',
      attractionCards: cards,
    );

    if (_currentSessionId != null) {
      await _saveMessageToDB(_currentSessionId!, recMsg);
    }
    setState(() => _currentMessages.add(recMsg));
    _scrollToBottom();
  }

  Future<void> _showFoodRecommendations() async {
    if (!_foodLoaded || _foodData.isEmpty) {
      _sendMessage('請推薦嘉義美食');
      return;
    }
    final List<Map<String, dynamic>> cards = [];
    final shuffled = List<dynamic>.from(_foodData)..shuffle();
    for (final e in shuffled) {
      final v = e as Map<String, dynamic>;
      final images = v['Images'];
      String imageUrl = '';
      if (images is List && images.isNotEmpty) {
        final first = images[0];
        if (first is Map) {
          imageUrl = first['url']?.toString() ?? first['Url']?.toString() ?? '';
        } else if (first is String) {
          imageUrl = first;
        }
      }
      cards.add({
        ...v,
        '_cardType': 'food',
        '_imageUrl': imageUrl,
        'AttractionName': v['RestaurantName']?.toString() ?? '',
        'Tags': v['Tags'] ?? [],
        'Star_rating': v['Star_rating'] ?? 0,
        'Price_Name': v['Price_Name'] ?? '',
        'PositionLat': v['PositionLat'],
        'PositionLon': v['PositionLon'],
        'Address': v['Address'] ?? '',
        'Description': v['Description'] ?? '',
      });
      if (cards.length >= 5) break;
    }

    final recMsg = ChatMessage(
      isUser: false,
      text: '',
      type: ChatMessageType.recommendation,
      recType: 'food',
      attractionCards: cards,
    );
    if (_currentSessionId != null) await _saveMessageToDB(_currentSessionId!, recMsg);
    setState(() => _currentMessages.add(recMsg));
    _scrollToBottom();
  }

  Future<void> _showHotelRecommendations() async {
    if (!_hotelLoaded || _hotelData.isEmpty) {
      _sendMessage('請推薦嘉義住宿');
      return;
    }
    final List<Map<String, dynamic>> cards = [];
    final shuffled = List<dynamic>.from(_hotelData)..shuffle();
    for (final e in shuffled) {
      final v = e as Map<String, dynamic>;
      final picture = v['Picture'];
      String imageUrl = '';
      if (picture is Map) {
        imageUrl = picture['PictureUrl1']?.toString() ?? '';
      }
      final rawHotelStar = v['Star'];
      final double hotelStar = rawHotelStar is num
          ? rawHotelStar.toDouble()
          : double.tryParse(rawHotelStar?.toString() ?? '') ?? 0.0;
      cards.add({
        ...v,
        '_cardType': 'hotel',
        '_imageUrl': imageUrl,
        'AttractionName': v['HotelName']?.toString() ?? '',
        'Tags': v['Class'] != null ? [v['Class'].toString()] : [],
        'Star_rating': hotelStar,
        'Price_Name': v['Grade']?.toString() ?? '',
        'PositionLat': v['PositionLat'],
        'PositionLon': v['PositionLon'],
        'Address': v['Address'] ?? '',
        'Description': v['Description'] ?? '',
      });
      if (cards.length >= 5) break;
    }

    final recMsg = ChatMessage(
      isUser: false,
      text: '',
      type: ChatMessageType.recommendation,
      recType: 'hotel',
      attractionCards: cards,
    );
    if (_currentSessionId != null) await _saveMessageToDB(_currentSessionId!, recMsg);
    setState(() => _currentMessages.add(recMsg));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatDate(DateTime dt) =>
      '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDFCF5),
      drawer: _buildAppDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            if (_currentMode == ChatMode.none) _buildCustomStyledHeader(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _currentMode == ChatMode.none
                    ? _buildDashboardView()
                    : _buildChatView(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppDrawer() {
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
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.85), width: 2.5),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 10)],
                ),
                child: ClipOval(child: _UserAvatar(user: user, radius: 32)),
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

          // ── 對話紀錄標題 ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('對話紀錄', style: TextStyle(
                    fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900,
                    color: Color(0xFF7D6E5D), fontSize: 14)),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() => _currentMode = ChatMode.none);
                  },
                  icon: const Icon(Icons.home_rounded, size: 16, color: Color(0xFF8BAA88)),
                  label: const Text('主頁', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontSize: 12)),
                ),
              ],
            ),
          ),

          // ── 對話紀錄列表 ──────────────────────────────────────
          Expanded(
            child: _allSessions.isEmpty
                ? const Center(
                child: Text('還沒有對話紀錄', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)))
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _allSessions.length,
              itemBuilder: (context, i) {
                final s = _allSessions[i];
                final isActive = s.id == _currentSessionId;
                return Dismissible(
                  key: Key(s.id),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) async {
                    return await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFFFDFCF5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        title: const Text('刪除對話？', style: TextStyle(
                            fontFamily: 'MyCustomFont', fontWeight: FontWeight.w900,
                            color: Color(0xFF7D6E5D))),
                        content: Text('「${s.title}」及其所有訊息將被永久刪除。',
                            style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消', style: TextStyle(
                                fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88))),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade400,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('刪除', style: TextStyle(
                                fontFamily: 'MyCustomFont', color: Colors.white)),
                          ),
                        ],
                      ),
                    ) ?? false;
                  },
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete_rounded, color: Colors.red),
                  ),
                  onDismissed: (_) async {
                    await LocalDbService.instance.deleteSession(s.id);
                    await _loadSessions();
                    if (_currentSessionId == s.id) {
                      setState(() {
                        _currentMode = ChatMode.none;
                        _currentSessionId = null;
                        _currentMessages = [];
                      });
                    }
                  },
                  child: ListTile(
                    dense: true,
                    selected: isActive,
                    selectedTileColor: const Color(0xFF8BAA88).withOpacity(0.1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: Icon(
                      s.mode == 'itinerary' ? Icons.map_rounded : Icons.chat_bubble_outline_rounded,
                      color: isActive ? const Color(0xFF8BAA88) : Colors.grey,
                      size: 20,
                    ),
                    title: Text(s.title, style: TextStyle(
                        fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold,
                        color: isActive ? const Color(0xFF8BAA88) : const Color(0xFF7D6E5D)),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_formatDate(s.updatedAt),
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                    onTap: () => _switchToSession(s),
                  ),
                );
              },
            ),
          ),

          // ── 帳號 / 設定 選單 ────────────────────────────────
          const Divider(indent: 20, endIndent: 20, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 8, 24, 6),
                  child: Text('帳號', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFFB0A898), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                _AiDrawerItem(icon: Icons.person_rounded, label: '個人資料', color: const Color(0xFF8BAA88),
                    onTap: () {
                      Navigator.pop(context);
                      final u = FirebaseAuth.instance.currentUser;
                      if (u == null) {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                        return;
                      }
                      AppStateManager.currentTabNotifier.value = 6;
                    }),
                _AiDrawerItem(icon: Icons.favorite_rounded, label: '我的收藏', color: const Color(0xFFE8A0A0),
                    onTap: () {
                      Navigator.pop(context);
                      final u = FirebaseAuth.instance.currentUser;
                      if (u == null) {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                        return;
                      }
                      AppStateManager.currentTabNotifier.value = 3;
                    }),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 12, 24, 6),
                  child: Text('設定', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                      color: Color(0xFFB0A898), fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                _AiDrawerItem(icon: Icons.settings_rounded, label: '系統設定', color: const Color(0xFF9E9182),
                    onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const SystemSettingsScreen())); }),
                _AiDrawerItem(icon: Icons.help_rounded, label: '幫助與支援', color: const Color(0xFFB09070),
                    onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpSupportScreen())); }),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildCustomStyledHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Color(0xFF7D6E5D), size: 30),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.1)),
            ),
            child: const Icon(Icons.notifications_none_rounded, color: Color(0xFF7D6E5D), size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardView() {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? '旅人';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hi $displayName,', style: const TextStyle(
                  fontFamily: 'MyCustomFont', fontSize: 32,
                  fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 8),
              const Text('需要任何旅遊建議嗎？\n您的專屬 AI 阿布隨時在線為您服務。',
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14,
                      color: Colors.grey, height: 1.5, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: AnimatedBuilder(
              animation: _breathingController,
              builder: (context, child) {
                return Container(
                  width: 150 + (_breathingController.value * 30),
                  height: 150 + (_breathingController.value * 30),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8BAA88), Color(0xFF7FA3B0)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [BoxShadow(
                      color: const Color(0xFF8BAA88).withOpacity(0.3),
                      blurRadius: 40 + (_breathingController.value * 30),
                      spreadRadius: 10 + (_breathingController.value * 15),
                    )],
                  ),
                  child: Center(child: Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white.withOpacity(0.8),
                    size: 60 + (_breathingController.value * 10),
                  )),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Row(
            children: [
              _buildMainActionCard(Icons.chat_bubble_outline_rounded, '一般對話詢問', '嘉義資訊、天氣、問答',
                      () => _openNewChat(ChatMode.general)),
              const SizedBox(width: 16),
              _buildMainActionCard(Icons.edit_location_alt_rounded, '規劃行程', '多日遊、景點美食安排',
                      () => _openNewChat(ChatMode.itinerary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMainActionCard(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 15, offset: const Offset(0, 5))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFF8BAA88).withOpacity(0.1), shape: BoxShape.circle),
                child: Icon(icon, color: const Color(0xFF8BAA88), size: 28),
              ),
              const SizedBox(height: 20),
              Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 16,
                  fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 6),
              Text(subtitle, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                  color: Colors.grey, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        _buildChatHeader(),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(20),
            itemCount: _currentMessages.length + (_isLoading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _currentMessages.length && _isLoading) {
                return _buildLoadingBubble();
              }
              return _buildChatBubble(_currentMessages[index]);
            },
          ),
        ),
        _buildQuickActions(),
        _buildChatInput(),
      ],
    );
  }

  Widget _buildChatHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() {
              _currentMode = ChatMode.none;
            }),
            child: Row(
              children: [
                const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF7D6E5D), size: 16),
                const SizedBox(width: 6),
                Text('返回', style: TextStyle(fontFamily: 'MyCustomFont',
                    color: const Color(0xFF7D6E5D).withOpacity(0.8), fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => _showNewChatDialog(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF8BAA88).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.add_rounded, size: 16, color: Color(0xFF8BAA88)),
                  SizedBox(width: 4),
                  Text('新對話', style: TextStyle(fontFamily: 'MyCustomFont',
                      color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
              ),
              child: const Icon(Icons.history_rounded, size: 18, color: Color(0xFF7D6E5D)),
            ),
          ),
        ],
      ),
    );
  }

  void _showNewChatDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFFFDFCF5),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('開始新對話', style: TextStyle(fontFamily: 'MyCustomFont',
                fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
            const SizedBox(height: 20),
            _newChatOption(Icons.chat_bubble_outline_rounded, '一般對話詢問', '問嘉義景點、美食、天氣...', () {
              Navigator.pop(ctx);
              _openNewChat(ChatMode.general);
            }),
            const SizedBox(height: 12),
            _newChatOption(Icons.edit_location_alt_rounded, '規劃旅遊行程', '打造專屬多日遊行程', () {
              Navigator.pop(ctx);
              _openNewChat(ChatMode.itinerary);
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _newChatOption(IconData icon, String title, String sub, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF8BAA88), size: 28),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontFamily: 'MyCustomFont',
                    fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                Text(sub, style: const TextStyle(fontFamily: 'MyCustomFont',
                    fontSize: 12, color: Colors.grey)),
              ],
            ),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Container(
      height: 76,
      padding: const EdgeInsets.only(bottom: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          _quickChip('推薦景點', Icons.landscape_rounded),
          _quickChip('推薦美食', Icons.restaurant_rounded),
          _quickChip('推薦住宿', Icons.hotel_rounded),
          _quickChip('天氣資訊', Icons.wb_sunny_rounded),
          _quickChip('交通建議', Icons.directions_bus_rounded),
          if (_currentMode == ChatMode.itinerary)
            _quickChip('調整行程', Icons.edit_rounded),
        ],
      ),
    );
  }

  Widget _quickChip(String label, IconData icon) {
    return GestureDetector(
      onTap: _isLoading ? null : () async { await _handleQuickAction(label); },
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _isLoading
              ? Colors.grey.withOpacity(0.1)
              : const Color(0xFF8BAA88).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _isLoading
              ? Colors.grey.withOpacity(0.2)
              : const Color(0xFF8BAA88).withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: _isLoading ? Colors.grey : const Color(0xFF8BAA88)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                fontWeight: FontWeight.bold,
                color: _isLoading ? Colors.grey : const Color(0xFF7D6E5D))),
          ],
        ),
      ),
    );
  }

  Widget _buildChatBubble(ChatMessage msg) {
    if (msg.type == ChatMessageType.tripCard) {
      return _buildTripCardResponse(msg.text.isEmpty ? 'AI 嘉義行程' : msg.text);
    }
    if (msg.type == ChatMessageType.recommendation) {
      return _buildAttractionRecommendationCards(msg.attractionCards ?? [], recType: msg.recType ?? 'attraction');
    }
    return _buildTextBubble(msg);
  }

  Widget _buildTextBubble(ChatMessage msg) {
    final user = FirebaseAuth.instance.currentUser;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        mainAxisAlignment: msg.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!msg.isUser) ...[
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: const Color(0xFF8BAA88).withOpacity(0.2), shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF8BAA88), size: 18),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: msg.isUser ? const Color(0xFF8BAA88) : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(msg.isUser ? 20 : 4),
                  bottomRight: Radius.circular(msg.isUser ? 4 : 20),
                ),
                border: msg.isUser ? null : Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 4))],
              ),
              child: SelectableText(
                msg.text,
                style: TextStyle(
                  fontFamily: 'MyCustomFont',
                  color: msg.isUser ? Colors.white : const Color(0xFF7D6E5D),
                  fontSize: 15, height: 1.6,
                ),
              ),
            ),
          ),
          if (msg.isUser) ...[
            // 🌟 完美替換小丑，套用真實快取自訂頭貼
            Container(
              margin: const EdgeInsets.only(left: 12),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF8BAA88), width: 1.5)),
              child: _UserAvatar(user: user, radius: 14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: const Color(0xFF8BAA88).withOpacity(0.2), shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF8BAA88), size: 18),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20), topRight: Radius.circular(20),
                bottomLeft: Radius.circular(4), bottomRight: Radius.circular(20),
              ),
              border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
            ),
            child: AnimatedBuilder(
              animation: _breathingController,
              builder: (context, child) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final double phase = (i / 3);
                    final double raw = (_breathingController.value + phase) % 1.0;
                    final double opacity = 0.3 + 0.7 * (raw < 0.5 ? raw * 2 : 2 - raw * 2);
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFF8BAA88).withOpacity(opacity.clamp(0.3, 1.0)),
                        shape: BoxShape.circle,
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttractionRecommendationCards(List<Map<String, dynamic>> cards, {String recType = 'attraction'}) {
    final String label;
    final IconData icon;
    switch (recType) {
      case 'food':
        label = '✨ 為您推薦嘉義美食';
        icon = Icons.restaurant_rounded;
        break;
      case 'hotel':
        label = '✨ 為您推薦嘉義住宿';
        icon = Icons.hotel_rounded;
        break;
      default:
        label = '✨ 為您推薦嘉義景點';
        icon = Icons.landscape_rounded;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 48, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(label, style: const TextStyle(
                fontFamily: 'MyCustomFont', fontSize: 14,
                fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
          ),
          SizedBox(
            height: 260,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: cards.length,
              itemBuilder: (context, index) {
                return _buildAttractionCard(cards[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttractionCard(Map<String, dynamic> data) {
    String imageUrl = data['_imageUrl']?.toString() ?? '';
    if (imageUrl.isEmpty) {
      final images = data['Images'] as List<dynamic>?;
      if (images != null && images.isNotEmpty) {
        final first = images[0];
        if (first is Map) {
          imageUrl = first['url']?.toString() ?? first['Url']?.toString() ?? '';
        } else if (first is String) {
          imageUrl = first;
        }
      }
    }
    final name = data['AttractionName']?.toString() ?? '';
    final rawTags = data['Tags'];
    final String tags;
    if (rawTags is List) {
      tags = rawTags.take(2).map((t) => t.toString()).join(' · ');
    } else {
      tags = rawTags?.toString() ?? '';
    }
    final rawStar = data['Star_rating'];
    final double starRating = rawStar is num
        ? rawStar.toDouble()
        : double.tryParse(rawStar?.toString() ?? '') ?? 0.0;
    final priceName = data['Price_Name']?.toString() ?? '';

    return GestureDetector(
      onTap: () => _onAttractionCardTap(data),
      child: Container(
        width: 180,
        margin: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.2)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: imageUrl.isNotEmpty
                  ? Image.network(imageUrl, height: 110, width: double.infinity, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholderImage())
                  : _placeholderImage(),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 14,
                      fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  if (tags.isNotEmpty)
                    Text(tags, style: const TextStyle(fontFamily: 'MyCustomFont',
                        fontSize: 10, color: Colors.grey),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFD700)),
                      Text(' ${starRating.toStringAsFixed(1)}',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                      if (priceName.isNotEmpty) ...[
                        const Text(' · ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                        Expanded(child: Text(priceName, style: const TextStyle(
                            fontFamily: 'MyCustomFont', fontSize: 10, color: Color(0xFF8BAA88)),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ]
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _onAttractionCardTap(data),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8BAA88),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        elevation: 0,
                      ),
                      child: const Text('查看詳情', style: TextStyle(fontFamily: 'MyCustomFont',
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderImage() {
    return Container(
      height: 110, color: const Color(0xFF8BAA88).withOpacity(0.15),
      child: const Center(child: Icon(Icons.landscape_rounded, color: Color(0xFF8BAA88), size: 40)),
    );
  }

  // 與 profile_screen 風格統一的側邊欄選單項目
  Widget _AiDrawerItem({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
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
              const Icon(Icons.chevron_right_rounded, color: Color(0xFFCFC8C0), size: 18),
            ]),
          ),
        ),
      ),
    );
  }

  void _onAttractionCardTap(Map<String, dynamic> data) {
    AppStateManager.aiItineraryPoiNotifier.value = [data];
    AppStateManager.currentTabNotifier.value = 1;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('正在地圖上顯示「${data['AttractionName']}」📍',
            style: const TextStyle(fontFamily: 'MyCustomFont')),
        backgroundColor: const Color(0xFF8BAA88),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildTripCardResponse(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 48, bottom: 24, right: 20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
          boxShadow: [BoxShadow(color: const Color(0xFF8BAA88).withOpacity(0.1), blurRadius: 15, offset: const Offset(0, 8))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF8BAA88), Color(0xFF7FA3B0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.map_rounded, color: Colors.white, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('專屬您的嘉義之旅 ✨', style: TextStyle(
                            fontFamily: 'MyCustomFont', color: Colors.white,
                            fontSize: 15, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(title, style: const TextStyle(
                            fontFamily: 'MyCustomFont', color: Colors.white70, fontSize: 11),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(10)),
                    child: const Text('AI 生成', style: TextStyle(fontFamily: 'MyCustomFont',
                        color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _tripHighlightRow(Icons.place_rounded, '包含嘉義精華景點與美食'),
                  const SizedBox(height: 8),
                  _tripHighlightRow(Icons.account_balance_wallet_rounded, '符合您的交通與預算需求'),
                  const SizedBox(height: 8),
                  _tripHighlightRow(Icons.edit_calendar_rounded, '可在地圖行程頁自由編輯調整'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        AppStateManager.currentTabNotifier.value = 1;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('🗺️ 已自動填入行程規劃，請開啟行程模式查看！',
                                style: TextStyle(fontFamily: 'MyCustomFont')),
                            backgroundColor: Color(0xFF8BAA88),
                            duration: Duration(seconds: 3),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8BAA88),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.route_rounded, color: Colors.white, size: 18),
                      label: const Text('開啟地圖行程規劃', style: TextStyle(
                          fontFamily: 'MyCustomFont', color: Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => AppStateManager.currentTabNotifier.value = 1,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Color(0xFF8BAA88), width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: const Text('查看完整地圖', style: TextStyle(fontFamily: 'MyCustomFont',
                          color: Color(0xFF8BAA88), fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tripHighlightRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF9E9182)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontFamily: 'MyCustomFont',
            color: Color(0xFF7D6E5D), fontSize: 13, fontWeight: FontWeight.bold))),
      ],
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -4))],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: !_isLoading,
              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D)),
              decoration: InputDecoration(
                hintText: _isLoading ? 'AI 阿布思考中...' : '告訴我您的想法...',
                hintStyle: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFFFDFCF5),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
              ),
              onSubmitted: _isLoading ? null : _sendMessage,
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _isLoading ? null : () => _sendMessage(_textController.text),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _isLoading ? Colors.grey.shade300 : const Color(0xFF8BAA88),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isLoading ? Icons.hourglass_top_rounded : Icons.send_rounded,
                color: Colors.white, size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}