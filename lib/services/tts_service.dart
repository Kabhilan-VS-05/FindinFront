import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(() => _isSpeaking = false);
  }

  Future<void> speak(String text) async {
    if (_isSpeaking) return;
    _isSpeaking = true;
    await _tts.speak(text);
  }

  Future<void> stop() async {
    _isSpeaking = false;
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
