package com.example.alibuda // 保持和你原本的一模一樣

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.speech.tts.TextToSpeech
import java.util.Locale

class MainActivity : FlutterActivity() {
    private lateinit var tts: TextToSpeech
    private val CHANNEL = "com.alibuda/tts" // 這是你定義的通道名稱

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. 初始化 TTS
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts.language = Locale.TRADITIONAL_CHINESE
            }
        }

        // 2. 設定 MethodChannel 橋樑
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        val rate = (call.argument<Double>("rate") ?: 1.0).toFloat()
                        tts.setSpeechRate(rate)
                        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "ali_tts")
                        result.success(null)
                    }
                    "stop" -> {
                        tts.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // 3. 釋放資源，防止當機
    override fun onDestroy() {
        if (::tts.isInitialized) {
            tts.stop()
            tts.shutdown()
        }
        super.onDestroy()
    }
}