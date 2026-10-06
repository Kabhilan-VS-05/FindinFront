import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/tts_service.dart';
import '../services/vibration_service.dart';
import '../services/detector_service.dart';
import '../services/depth_service.dart';
import '../widgets/detection_overlay.dart';

enum _AlertMode { voice, vibrate }
enum _AppState { intro, active }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // ─── Services ──────────────────────────────────────────────────────────────
  final _tts       = TtsService();
  final _vibration = VibrationService();
  final _detector  = DetectorService();
  final _depth     = DepthService();

  // ─── Platform channels ─────────────────────────────────────────────────────
  static const _volumeChannel = EventChannel('find_in_front/volume_buttons');
  static const _beepChannel   = MethodChannel('find_in_front/beep');
  StreamSubscription? _volumeSub;

  // ─── Camera ────────────────────────────────────────────────────────────────
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _cameraReady = false;
  bool _isSwitching = false;

  // ─── App state ─────────────────────────────────────────────────────────────
  _AppState _appState = _AppState.intro;
  _AlertMode _alertMode = _AlertMode.vibrate; // default: silent + vibrate
  DetectionResult? _detection;
  ObstacleResult? _obstacle;

  // Independent guards — detection and depth run concurrently, neither blocks
  // the other. Each service also throttles itself internally.
  bool _detBusy = false;
  bool _depthBusy = false;

  // ─── Proximity feedback (parking-sensor beep / vibrate) ─────────────────────
  // Closeness 0..1 from each source, with a timestamp so stale values decay.
  double _depthCloseness = 0.0, _detCloseness = 0.0;
  double _pan = 0.0; // azimuth of nearest obstacle, -1..1
  bool _showHeatmap = false; // depth heatmap overlay (calibration)
  DateTime _depthAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _detAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _proximityTimer;
  DateTime _lastPulse = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _minCloseness = 0.30; // below this: silent

  // ─── Triple-tap to activate ────────────────────────────────────────────────
  int _tapCount = 0;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  // ─── Long-press to switch camera ───────────────────────────────────────────
  Timer? _longPressTimer;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _tts.init();
    try {
      await _detector.init();
    } catch (e) {
      debugPrint('Detector init failed: $e');
    }
    try {
      await _depth.init();
    } catch (e) {
      debugPrint('Depth init failed: $e');
    }
    _listenVolume();

    // Audio onboarding — a blind user can't read "tap 3 times".
    await Future.delayed(const Duration(milliseconds: 600));
    _tts.speak('Find In Front ready. '
        'Tap the screen three times to start. '
        'Volume up for sound, volume down for vibration.');
  }

  void _listenVolume() {
    _volumeSub = _volumeChannel.receiveBroadcastStream().listen((event) {
      if (!mounted) return;
      if (event == 'up') {
        setState(() => _alertMode = _AlertMode.voice);
        // Confirm with a centred beep (sound mode).
        _beepChannel.invokeMethod('beep',
            {'freq': 900, 'pan': 0.0, 'ms': 120, 'gain': 0.7}).catchError((_) {});
        _tts.speak('Sound mode');
      } else if (event == 'down') {
        setState(() => _alertMode = _AlertMode.vibrate);
        _vibration.alert(); // confirm with a buzz (vibrate mode)
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_appState != _AppState.active) return;
    if (state == AppLifecycleState.inactive) {
      _proximityTimer?.cancel();
      _controller?.stopImageStream();
      _controller?.dispose();
      _controller = null;
      if (mounted) setState(() => _cameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _proximityTimer?.cancel();
    _volumeSub?.cancel();
    _controller?.dispose();
    _tts.dispose();
    _detector.dispose();
    _depth.dispose();
    super.dispose();
  }

  // ─── Triple-tap activation ─────────────────────────────────────────────────
  void _onTap() {
    if (_appState == _AppState.active) return;
    final now = DateTime.now();
    if (now.difference(_lastTap) > const Duration(milliseconds: 600)) {
      _tapCount = 1;
    } else {
      _tapCount++;
    }
    _lastTap = now;
    setState(() {}); // refresh dot indicators
    if (_tapCount >= 3) {
      _tapCount = 0;
      _activateCamera();
    }
  }

  Future<void> _activateCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (status.isPermanentlyDenied) openAppSettings();
      return;
    }
    setState(() => _appState = _AppState.active);
    await _startCamera();
    _tts.speak('Camera on. Double tap to hear the object name.');
  }

  // ─── Camera start / switch ─────────────────────────────────────────────────
  Future<void> _startCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;
    if (_cameraIndex >= _cameras.length) _cameraIndex = 0;

    await _controller?.dispose();
    _controller = CameraController(
      _cameras[_cameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _controller!.initialize();
    if (!mounted) return;

    setState(() {
      _cameraReady = true;
      _isSwitching = false;
    });

    _controller!.startImageStream(_onFrame);
    _startProximityFeedback();
  }

  void _onLongPressStart(LongPressStartDetails _) {
    if (_appState != _AppState.active || _cameras.length < 2) return;
    _longPressTimer = Timer(const Duration(seconds: 3), _switchCamera);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    _longPressTimer?.cancel();
  }

  Future<void> _switchCamera() async {
    if (_isSwitching || _cameras.length < 2) return;
    await _controller?.stopImageStream();
    setState(() {
      _isSwitching = true;
      _cameraReady = false;
      _detection = null;
      _obstacle = null;
    });
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera();
    // Confirm switch with a buzz (no speech).
    _vibration.alert();
  }

  // ─── Frame processing ──────────────────────────────────────────────────────
  // Detection (fast, names objects) and depth (heavy, finds walls/obstacles)
  // run on independent guards. Each reads the frame synchronously before its
  // first await, so the buffer is safe. Neither can stall the other.
  void _onFrame(CameraImage image) {
    final cam = _cameras[_cameraIndex];

    // Detection — fast; updates on-screen name + a proximity estimate.
    if (!_detBusy && _detector.isReady) {
      _detBusy = true;
      _detector.detect(image, cam).then((det) {
        if (!mounted) return;
        setState(() => _detection = det);
        if (det != null) {
          // Box-size distance → closeness (1.5m = 0, 0.2m ≈ 1.0)
          _detCloseness = ((1.5 - det.distanceMeters) / 1.3).clamp(0.0, 1.0);
          _detAt = DateTime.now();
        }
      }).catchError((e) {
        debugPrint('detect error: $e');
      }).whenComplete(() => _detBusy = false);
    }

    // Depth — heavier; the real obstacle/wall signal.
    if (!_depthBusy && _depth.isReady) {
      _depthBusy = true;
      _depth.detectObstacle(image, cam).then((obs) {
        if (!mounted || obs == null) return;
        setState(() => _obstacle = obs);
        _depthCloseness = obs.closeness;
        _pan = obs.pan;
        _depthAt = DateTime.now();
      }).catchError((e) {
        debugPrint('depth error: $e');
      }).whenComplete(() => _depthBusy = false);
    }
  }

  // ─── Proximity feedback loop — parking-sensor style ─────────────────────────
  // A light 60ms ticker reads the closest live signal and pulses a beep (or
  // vibration) whose RATE and PITCH rise as obstacles get closer. No speech.
  void _startProximityFeedback() {
    _proximityTimer?.cancel();
    _proximityTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted || _appState != _AppState.active) return;
      final now = DateTime.now();

      // Decay stale readings so a passed obstacle goes quiet.
      final dc = now.difference(_depthAt).inMilliseconds < 1200 ? _depthCloseness : 0.0;
      final oc = now.difference(_detAt).inMilliseconds < 800 ? _detCloseness : 0.0;
      final c = dc > oc ? dc : oc; // nearest signal wins

      if (c < _minCloseness) return; // nothing close → silence

      // Map closeness → beep interval: far ≈ 700ms, very close ≈ 90ms.
      final t = ((c - _minCloseness) / (1.0 - _minCloseness)).clamp(0.0, 1.0);
      final interval = (700 - t * 610).toInt(); // ms between pulses
      if (now.difference(_lastPulse).inMilliseconds < interval) return;
      _lastPulse = now;

      // Only depth gives a reliable azimuth; object distance pans centre.
      final pan = now.difference(_depthAt).inMilliseconds < 1200 ? _pan : 0.0;
      _pulse(t, pan);
    });
  }

  // Sonification (research-backed): frequency → distance, panning → azimuth,
  // loudness/rate → closeness.
  void _pulse(double intensity, double pan) {
    if (_alertMode == _AlertMode.voice) {
      final freq = (500 + intensity * 700).toInt(); // 500Hz far → 1200Hz near
      final gain = (0.45 + intensity * 0.45);        // louder when closer
      _beepChannel.invokeMethod('beep', {
        'freq': freq,
        'pan': pan,
        'ms': 70,
        'gain': gain,
      }).catchError((_) {});
    } else {
      // Deaf-blind: stronger/longer buzz the closer it is.
      _vibration.pulse((30 + intensity * 90).toInt());
    }
  }

  // Calibration controls (top area): heatmap toggle + wall sensitivity.
  // Small/translucent — for sighted setup, ignored by blind users.
  Widget _buildCalibrationControls() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 52),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _chip(
                _showHeatmap ? Icons.layers : Icons.layers_clear,
                _showHeatmap ? 'Depth ON' : 'Depth',
                () => setState(() => _showHeatmap = !_showHeatmap),
              ),
              const SizedBox(width: 8),
              _chip(Icons.remove, 'less', () {
                setState(() => _depth.sensitivity =
                    (_depth.sensitivity + 0.05).clamp(0.30, 0.85));
              }),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                color: Colors.black54,
                child: Text('sens ${_depth.sensitivity.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              _chip(Icons.add, 'more', () {
                setState(() => _depth.sensitivity =
                    (_depth.sensitivity - 0.05).clamp(0.30, 0.85));
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      ),
    );
  }

  // On-demand naming: double-tap speaks what's currently in front.
  void _speakCurrentObject() {
    final d = _detection;
    if (d == null) {
      _tts.speak('Nothing recognised');
      return;
    }
    final dist = d.distanceMeters < 1.0
        ? 'very close'
        : '${d.distanceMeters.toStringAsFixed(1)} meters';
    _tts.speak('${d.label}, $dist');
  }

  // ─── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _appState == _AppState.intro
          ? _buildIntro()
          : _buildCamera(),
    );
  }

  // Intro: black screen, tap 3 times to start
  Widget _buildIntro() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Tap progress dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 16, height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _tapCount ? Colors.white : Colors.white24,
                ),
              )),
            ),
            const SizedBox(height: 40),
            const Text(
              'Tap 3 times\nto start',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w300,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Long-press 3 sec to switch camera',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              'Vol ▲ = voice  ·  Vol ▼ = vibrate',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  // Active: camera + overlay
  Widget _buildCamera() {
    if (!_cameraReady || _controller == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              _isSwitching ? 'Switching camera…' : 'Starting camera…',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      onDoubleTap: _speakCurrentObject,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          DetectionOverlay(
            detection: _detection,
            obstacle: _obstacle,
            closeness: _depthCloseness > _detCloseness ? _depthCloseness : _detCloseness,
            pan: _pan,
            isVoiceMode: _alertMode == _AlertMode.voice,
            showHeatmap: _showHeatmap,
            debugStatus: '${_detector.statusMessage} · ${_depth.statusMessage}',
          ),
          _buildCalibrationControls(),
        ],
      ),
    );
  }
}
