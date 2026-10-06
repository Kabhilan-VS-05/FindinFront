import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'distance_estimator.dart';

class DetectionResult {
  final String label;
  final double score;
  final double top, left, bottom, right; // normalized 0..1
  final double distanceMeters;

  const DetectionResult({
    required this.label,
    required this.score,
    required this.top,
    required this.left,
    required this.bottom,
    required this.right,
    required this.distanceMeters,
  });

  bool get isClose => distanceMeters <= 1.5;
}

enum _ModelType { yolov8, efficientDet, unknown }

class DetectorService {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;
  final DistanceEstimator _distanceEst = CameraDistanceEstimator();

  List<String> _labels = [];
  _ModelType _modelType = _ModelType.unknown;
  int _inputH = 320;
  int _inputW = 320;
  bool _isUint8Input = false; // true for EfficientDet, false for YOLOv8 float

  // EfficientDet tensor index mapping
  int _idxBoxes = 0, _idxClasses = 1, _idxScores = 2, _idxCount = 3;
  int _edTopK = 25;
  // Pre-allocated output containers indexed 0..N-1
  final List<Object> _outputs = [];

  // YOLOv8 anchor count
  int _yoloAnchors = 8400;

  // Throttle to 5 FPS
  static const _minInterval = Duration(milliseconds: 200);
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  bool _running = false;
  static const double _confThreshold = 0.30; // slightly lower to catch more

  // Status visible to UI for debugging
  String statusMessage = 'Initializing...';

  bool get isReady => _isolate != null && _modelType != _ModelType.unknown;

  Future<void> init() async {
    try {
      await _loadLabels();
      await _loadModel();
    } catch (e, st) {
      statusMessage = 'Init error: $e';
      debugPrint('FindInFront init error: $e\n$st');
    }
  }

  Future<void> _loadLabels() async {
    final raw = await rootBundle.loadString('assets/models/coco_labels.txt');
    _labels = raw.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    debugPrint('FindInFront: loaded ${_labels.length} labels');
  }

  Future<void> _loadModel() async {
    // Prefer the higher-accuracy Lite2; fall back to Lite0 if absent.
    String? modelPath;
    for (final name in [
      'efficientdet_lite2.tflite',
      'efficientdet_lite0.tflite',
      'yolov8n.tflite',
    ]) {
      try {
        modelPath = await _copyAssetToDevice('assets/models/$name');
        break;
      } catch (_) {}
    }
    if (modelPath == null) {
      statusMessage = 'No model found in assets';
      return;
    }

    final options = InterpreterOptions()..threads = 4;
    _interpreter = Interpreter.fromFile(File(modelPath), options: options);
    _interpreter!.allocateTensors();

    final inTensor = _interpreter!.getInputTensor(0);
    final inShape = inTensor.shape;
    _inputH = inShape[1];
    _inputW = inShape[2];

    // uint8 = TensorType index 3; float32 = 1
    // tflite_flutter exposes .type as TfLiteType / int
    final typeVal = inTensor.type.index;
    _isUint8Input = (typeVal == 3); // UINT8

    final outTensors = _interpreter!.getOutputTensors();

    debugPrint('FindInFront: model=$modelPath');
    debugPrint('FindInFront: input shape=$inShape type=$typeVal (uint8=$_isUint8Input)');
    for (int i = 0; i < outTensors.length; i++) {
      debugPrint('  out[$i] shape=${outTensors[i].shape}');
    }

    if (outTensors.length == 1 &&
        outTensors[0].shape.length == 3 &&
        outTensors[0].shape[1] == 84) {
      // YOLOv8: output [1, 84, anchors]
      _modelType = _ModelType.yolov8;
      _yoloAnchors = outTensors[0].shape[2];
      _isUint8Input = false;
      _outputs.add(
        List.generate(1, (_) =>
          List.generate(84, (_) =>
            List<double>.filled(_yoloAnchors, 0.0))));
      statusMessage = 'YOLOv8 ready (${_inputW}x$_inputH)';
      debugPrint('FindInFront: YOLOv8 anchors=$_yoloAnchors');

    } else if (outTensors.length >= 3) {
      // EfficientDet: 4 output tensors
      _modelType = _ModelType.efficientDet;
      _resolveOutputIndices(outTensors);
      for (final t in outTensors) {
        _outputs.add(_preallocate(t.shape));
      }
      statusMessage = 'EfficientDet ready (${_inputW}x$_inputH, uint8=$_isUint8Input)';
      debugPrint('FindInFront: EfficientDet topK=$_edTopK '
          'boxes=$_idxBoxes classes=$_idxClasses '
          'scores=$_idxScores count=$_idxCount');
    } else {
      statusMessage = 'Unknown model shape';
      debugPrint('FindInFront: unrecognized output shape');
      return;
    }

    _isolate = await IsolateInterpreter.create(address: _interpreter!.address);
    debugPrint('FindInFront: IsolateInterpreter ready');
  }

  void _resolveOutputIndices(List<Tensor> tensors) {
    final rankTwo = <int>[];
    for (int i = 0; i < tensors.length; i++) {
      final s = tensors[i].shape;
      if (s.length == 3 && s.last == 4) {
        _idxBoxes = i;
        _edTopK = s[1];
      } else if (s.length == 1) {
        _idxCount = i;
      } else if (s.length == 2) {
        rankTwo.add(i);
        if (s[1] > _edTopK) _edTopK = s[1];
      }
    }
    if (rankTwo.length >= 2) {
      _idxClasses = rankTwo[0];
      _idxScores  = rankTwo[1];
    }
  }

  Object _preallocate(List<int> shape) {
    switch (shape.length) {
      case 1:
        return List<double>.filled(shape[0], 0.0);
      case 2:
        return List.generate(shape[0], (_) => List<double>.filled(shape[1], 0.0));
      case 3:
        return List.generate(shape[0], (_) =>
          List.generate(shape[1], (_) =>
            List<double>.filled(shape[2], 0.0)));
      default:
        return List<double>.filled(shape.fold(1, (a, b) => a * b), 0.0);
    }
  }

  Future<String> _copyAssetToDevice(String assetPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path, p.basename(assetPath));
    final file = File(dest);
    final data = await rootBundle.load(assetPath);
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      await file.writeAsBytes(data.buffer.asUint8List());
      debugPrint('FindInFront: copied ${data.lengthInBytes >> 10} KB → $dest');
    }
    return dest;
  }

  Future<DetectionResult?> detect(CameraImage image, CameraDescription camera) async {
    if (_running || !isReady) return null;
    final now = DateTime.now();
    if (now.difference(_lastRun) < _minInterval) return null;
    _lastRun = now;
    _running = true;

    try {
      // Build input in the format the model expects, rotated upright
      final input = _preprocess(image, _inputW, _inputH, camera.sensorOrientation);

      final outMap = <int, Object>{
        for (int i = 0; i < _outputs.length; i++) i: _outputs[i],
      };

      await _isolate!.runForMultipleInputs([input], outMap);

      final result = switch (_modelType) {
        _ModelType.efficientDet => _readEfficientDet(),
        _ModelType.yolov8      => _readYolo(),
        _                      => null,
      };
      return result;
    } catch (e, st) {
      debugPrint('FindInFront detect error: $e\n$st');
      return null;
    } finally {
      _running = false;
    }
  }

  // ─── EfficientDet ─────────────────────────────────────────────────────────
  DetectionResult? _readEfficientDet() {
    final countRaw = ((_outputs[_idxCount] as List)[0] as num).toDouble();
    final count = countRaw.toInt().clamp(0, _edTopK);
    if (count == 0) return null;

    final boxes   = (_outputs[_idxBoxes]   as List)[0] as List;
    final classes = (_outputs[_idxClasses] as List)[0] as List;
    final scores  = (_outputs[_idxScores]  as List)[0] as List;

    DetectionResult? best;

    for (int i = 0; i < count; i++) {
      final score = (scores[i] as num).toDouble();
      if (score < _confThreshold) continue;

      // EfficientDet-Lite0 outputs 0-based indices into the 90-slot COCO map.
      final labelIdx = (classes[i] as num).toInt();
      if (labelIdx < 0 || labelIdx >= _labels.length) continue;
      final label = _labels[labelIdx];
      if (label == '???' || label.isEmpty) continue; // skip COCO gap slots

      final b      = boxes[i] as List;
      final top    = (b[0] as num).toDouble();
      final left   = (b[1] as num).toDouble();
      final bottom = (b[2] as num).toDouble();
      final right  = (b[3] as num).toDouble();
      final hFrac  = (bottom - top).clamp(0.0, 1.0);
      final dist   = _distanceEst.estimateMeters(label, hFrac);

      // Pick the most confident detection — most trustworthy to announce.
      if (best == null || score > best.score) {
        best = DetectionResult(
          label: _cap(label), score: score,
          top: top, left: left, bottom: bottom, right: right,
          distanceMeters: dist,
        );
      }
    }
    if (best != null) {
      debugPrint('FindInFront: ${best.label} '
          '${(best.score * 100).toStringAsFixed(0)}% '
          '${best.distanceMeters.toStringAsFixed(1)}m');
    }
    return best;
  }

  // ─── YOLOv8 ───────────────────────────────────────────────────────────────
  DetectionResult? _readYolo() {
    final out = (_outputs[0] as List)[0] as List; // [84][anchors]
    DetectionResult? best;

    for (int i = 0; i < _yoloAnchors; i++) {
      double maxScore = 0;
      int maxClass = -1;
      for (int c = 4; c < 84 && c < _labels.length + 4; c++) {
        final s = ((out[c] as List)[i] as num).toDouble();
        if (s > maxScore) { maxScore = s; maxClass = c - 4; }
      }
      if (maxScore < _confThreshold || maxClass < 0 || maxClass >= _labels.length) continue;

      final cx = ((out[0] as List)[i] as num).toDouble();
      final cy = ((out[1] as List)[i] as num).toDouble();
      final w  = ((out[2] as List)[i] as num).toDouble();
      final h  = ((out[3] as List)[i] as num).toDouble();
      final label = _labels[maxClass];
      final dist  = _distanceEst.estimateMeters(label, h.clamp(0.0, 1.0));

      if (best == null || dist < best.distanceMeters) {
        best = DetectionResult(
          label: _cap(label), score: maxScore,
          top: cy - h / 2, left: cx - w / 2,
          bottom: cy + h / 2, right: cx + w / 2,
          distanceMeters: dist,
        );
      }
    }
    return best;
  }

  // ─── Preprocessing ────────────────────────────────────────────────────────

  /// Center-crops the camera frame, scales to the model input, and converts
  /// YUV→RGB. Returns a Uint8List (0-255) for quantized models or a
  /// Float32List (0.0-1.0) for float models.
  ///
  /// Handles BOTH camera layouts:
  ///  • Packed NV21 (Flutter `ImageFormatGroup.nv21`): a single plane holding
  ///    Y bytes followed by interleaved V,U. `planes.length == 1`.
  ///  • Semi-planar / planar YUV420: separate Y and UV planes.
  ///
  /// [rotation] is the camera sensor orientation (0/90/180/270); the frame is
  /// rotated upright so objects aren't sideways to the model.
  Object _preprocess(CameraImage image, int tw, int th, int rotation) {
    final w = image.width, h = image.height;

    // Upright dimensions after applying sensor rotation
    final bool swap = rotation == 90 || rotation == 270;
    final int uw = swap ? h : w;
    final int uh = swap ? w : h;
    final crop = min(uw, uh);
    final offX = (uw - crop) ~/ 2;
    final offY = (uh - crop) ~/ 2;

    final packed = image.planes.length == 1;

    // Y plane params
    final yB  = image.planes[0].bytes;
    final yRS = image.planes[0].bytesPerRow == 0 ? w : image.planes[0].bytesPerRow;

    // UV params — differ between packed NV21 and multi-plane
    final Uint8List uvB;
    final int uvBase, uvRS, uvPS, vOff, uOff;
    if (packed) {
      // NV21 packed: VU interleaved, right after the Y data
      uvB    = yB;
      uvBase = yRS * h;        // start of chroma in the same buffer
      uvRS   = yRS;            // chroma row stride == luma row stride for NV21
      uvPS   = 2;             // V,U pair per 2x2 block
      vOff   = 0;             // NV21: V first
      uOff   = 1;
    } else {
      // Separate plane(s). planes[1] is U/V (interleaved on Android = VU/NV21).
      uvB    = image.planes[1].bytes;
      uvBase = 0;
      uvRS   = image.planes[1].bytesPerRow == 0 ? w : image.planes[1].bytesPerRow;
      uvPS   = image.planes[1].bytesPerPixel ?? 2;
      vOff   = 0;
      uOff   = 1;
    }

    final uvMax = uvB.length;
    final total = th * tw * 3;
    final outI = _isUint8Input ? Uint8List(total) : null;
    final outF = _isUint8Input ? null : Float32List(total);

    for (int py = 0; py < th; py++) {
      for (int px = 0; px < tw; px++) {
        // Upright (cropped) coordinate
        final ux = offX + (px * crop ~/ tw);
        final uy = offY + (py * crop ~/ th);

        // Map upright → source pixel via inverse sensor rotation
        final int sx, sy;
        switch (rotation) {
          case 90:
            sx = uy;          sy = h - 1 - ux; break;
          case 180:
            sx = w - 1 - ux;  sy = h - 1 - uy; break;
          case 270:
            sx = w - 1 - uy;  sy = ux;         break;
          default: // 0
            sx = ux;          sy = uy;
        }

        final yVal = yB[sy * yRS + sx] & 0xFF;
        final uvIdx = uvBase + (sy >> 1) * uvRS + (sx >> 1) * uvPS;

        int vVal = 0, uVal = 0;
        if (uvIdx + 1 < uvMax) {
          vVal = (uvB[uvIdx + vOff] & 0xFF) - 128;
          uVal = (uvB[uvIdx + uOff] & 0xFF) - 128;
        }

        final r = (yVal + (1.402 * vVal)).clamp(0.0, 255.0);
        final g = (yVal - 0.344 * uVal - 0.714 * vVal).clamp(0.0, 255.0);
        final b = (yVal + 1.772 * uVal).clamp(0.0, 255.0);

        final idx = (py * tw + px) * 3;
        if (outI != null) {
          outI[idx]     = r.toInt();
          outI[idx + 1] = g.toInt();
          outI[idx + 2] = b.toInt();
        } else {
          outF![idx]     = r / 255.0;
          outF[idx + 1] = g / 255.0;
          outF[idx + 2] = b / 255.0;
        }
      }
    }
    return outI ?? outF!;
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Future<void> dispose() async {
    await _isolate?.close();
    _interpreter?.close();
  }
}
