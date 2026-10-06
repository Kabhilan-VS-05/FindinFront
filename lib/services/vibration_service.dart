import 'package:vibration/vibration.dart';

class VibrationService {
  Future<bool> get _hasVibrator async => await Vibration.hasVibrator();

  Future<void> alert() async {
    if (await _hasVibrator) {
      Vibration.vibrate(duration: 300);
    }
  }

  /// Short proximity buzz; [ms] grows as the obstacle gets closer.
  bool _canVibrate = false;
  bool _checked = false;
  Future<void> pulse(int ms) async {
    if (!_checked) {
      _canVibrate = await Vibration.hasVibrator();
      _checked = true;
    }
    if (_canVibrate) Vibration.vibrate(duration: ms.clamp(20, 250));
  }

  Future<void> strongAlert() async {
    if (await _hasVibrator) {
      Vibration.vibrate(pattern: [0, 300, 100, 300]);
    }
  }
}
