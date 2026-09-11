import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GeminiService {
  static GeminiService? _instance;
  late final GenerativeModel _model;
  
  // 兩個對話各自維護 ChatSession（保有上下文記憶）
  ChatSession? _generalSession;
  ChatSession? _itinerarySession;

  GeminiService._() {
    _model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: dotenv.env['GEMINI_API_KEY']!,
      generationConfig: GenerationConfig(
        temperature: 0.8,
        maxOutputTokens: 1024,
      ),
      systemInstruction: Content.system(
        '你是嘉義旅遊專屬 AI 助手「阿布」。'
        '你對嘉義的景點、美食、住宿、交通、文化歷史非常熟悉。'
        '回答時使用繁體中文，語氣親切活潑，可以適當使用 emoji，'
        '回答精簡有重點，避免過長的條列式清單。',
      ),
    );
  }

  static GeminiService get instance => _instance ??= GeminiService._();

  // 一般對話（保有上下文）
  Future<String> sendGeneralMessage(String userMessage) async {
    _generalSession ??= _model.startChat();
    final response = await _generalSession!.sendMessage(
      Content.text(userMessage),
    );
    return response.text ?? '抱歉，我現在有點忙，請再試一次！';
  }

  // 行程規劃對話（保有上下文）
  Future<String> sendItineraryMessage(String userMessage) async {
    _itinerarySession ??= _model.startChat(history: [
      Content.model([TextPart(
        '你現在的任務是協助用戶規劃嘉義旅遊行程。'
        '請依序收集：天數、人數（大人/小孩）、預算、交通方式、旅遊風格、特殊需求。'
        '收集完 6 項資訊後，生成一份詳細的行程表，格式為每天分段（早/中/晚），'
        '包含景點名稱、預計停留時間、交通建議。',
      )]),
    ]);
    final response = await _itinerarySession!.sendMessage(
      Content.text(userMessage),
    );
    return response.text ?? '抱歉，行程規劃暫時無法回應，請再試一次！';
  }

  // 重置行程對話（重新規劃時用）
  void resetItinerarySession() => _itinerarySession = null;
  void resetGeneralSession() => _generalSession = null;
}