import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Result of analysing a monocular depth map for obstacles in the walking path.
///
/// MiDaS produces *relative* inverse depth (no metres), so we reason about
/// "how much closer than the rest of the scene" rather than absolute distance.
class ObstacleResult {
  /// 0..1 — how close the nearest thing directly ahead is (1 = right in front).
  final double closeness;

  /// True when something substantial is blocking the path straight ahead.
  final bool blocked;

  /// 'left' or 'right' — a clearer direction to move, when blocked. Null if
  /// every direction is blocked (e.g. facing a wall) or path is clear.
  final String? clearDirection;

  /// Azimuth of the nearest obstacle: -1 = far left, 0 = centre, +1 = far right.
  /// Drives stereo panning of the beep.
  final double pan;

  /// True when the view is dominated by a large, flat, near surface — a WALL,
  /// as opposed to a discrete obstacle (person, chair).
  final bool isWall;

  /// Downsampled normalised depth (0..1, 1 = nearest) for the on-screen heatmap.
  final List<List<double>> heatmap;

  const ObstacleResult({
    required this.closeness,
    required this.blocked,
    required this.clearDirection,
    required this.pan,
    required this.isWall,
    required this.heatmap,
  });

  /// Spoken/vibration severity bucket.
  bool get isUrgent => closeness >= 0.80;
}

class DepthService {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;

  int _inH = 256, _inW = 256;
  int _outH = 256, _outW = 256;
  int _outRank = 3;
  late Object _output; // nested list matching the model's exact output shape

  // ImageNet normalisation (MiDaS expects this)
  static const _mean = [0.485, 0.456, 0.406];
  static const _std  = [0.229, 0.224, 0.225];

  // Run depth at most ~3x/sec; it's heavier than detection.
  static const _minInterval = Duration(milliseconds: 300);
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  bool _running = false;

  // Obstacle thresholds — sensitivity is adjustable live from the UI.
  double sensitivity = 0.55; // center closeness → blocked (lower = more sensitive)
  static const double _clearThreshold = 0.45; // a side is "clear" below this
  static const int _grid = 24; // heatmap resolution

  String statusMessage = 'Depth: init...';
  bool get isReady => _isolate != null;

  Future<void> init() async {
    try {
      final path = await _copyAsset('assets/models/midas_small.tflite');
      final options = InterpreterOptions()..threads = 4;
      _interpreter = Interpreter.fromFile(File(path), options: options);
      _interpreter!.allocateTensors();

      final inShape = _interpreter!.getInputTensor(0).shape;   // [1,256,256,3]
      final outShape = _interpreter!.getOutputTensors()[0].shape; // [1,256,256]
      _inH = inShape[1];
      _inW = inShape[2];
      _outH = outShape.length >= 3 ? outShape[1] : 256;
      _outW = outShape.length >= 3 ? outShape[2] : 256;
      _outRank = outShape.length;

      // Build a nested zero buffer matching the EXACT output shape
      // (e.g. [1,256,256,1] is 4-D, not 3-D).
      _output = _buildNested(outShape);

      _isolate = await IsolateInterpreter.create(address: _interpreter!.address);
      statusMessage = 'Depth ready (${_inW}x$_inH)';
      debugPrint('FindInFront Depth: in=$inShape out=$outShape');
    } catch (e, st) {
      statusMessage = 'Depth init error: $e';
      debugPrint('FindInFront Depth init error: $e\n$st');
    }
  }

  Future<ObstacleResult?> detectObstacle(CameraImage image, CameraDescription cam) async {
    if (_running || !isReady) return null;
    final now = DateTime.now();
    if (now.difference(_lastRun) < _minInterval) return null;
    _lastRun = now;
    _running = true;

    try {
      final sw = Stopwatch()..start();
      final input = _preprocess(image, _inW, _inH, cam.sensorOrientation);
      await _isolate!.runForMultipleInputs([input], {0: _output});
      final result = _analyse();
      debugPrint('FindInFront Depth: infer ${sw.elapsedMilliseconds}ms');
      return result;
    } catch (e, st) {
      debugPrint('FindInFront Depth error: $e\n$st');
      return null;
    } finally {
      _running = false;
    }
  }

  /// Build a nested List of zeros whose shape matches [shape].
  Object _buildNested(List<int> shape) {
    if (shape.length == 1) return List<double>.filled(shape[0], 0.0);
    return List.generate(shape[0], (_) => _buildNested(shape.sublist(1)));
  }

  /// Flatten the depth output into a [_outH][_outW] grid of doubles,
  /// regardless of whether the model emits rank-3 [1,H,W] or rank-4 [1,H,W,1].
  List<List<double>> _depthGrid() {
    final o = _output as List;
    final plane = o[0] as List; // [H][W] or [H][W][1]
    return List.generate(_outH, (y) {
      final row = plane[y] as List;
      return List.generate(_outW, (x) {
        final cell = row[x];
        return (_outRank >= 4 ? (cell as List)[0] : cell) as double;
      });
    });
  }

  /// Find the closest thing ahead and which side is clearer.
  ObstacleResult _analyse() {
    final d = _depthGrid();

    // Per-frame normalisation: MiDaS scale varies frame to frame.
    double mn = double.infinity, mx = -double.infinity;
    for (int y = 0; y < _outH; y++) {
      final row = d[y];
      for (int x = 0; x < _outW; x++) {
        final v = row[x];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
    }
    final range = (mx - mn).abs() < 1e-6 ? 1.0 : (mx - mn);
    double norm(double v) => (v - mn) / range; // 0..1, 1 = nearest

    // Path region: middle-to-lower band (where body-height obstacles sit).
    final y0 = (_outH * 0.25).floor();
    final y1 = (_outH * 0.95).floor();
    final third = _outW ~/ 3;

    double sumL = 0, sumC = 0, sumR = 0;
    int nL = 0, nC = 0, nR = 0;

    // Wall signals over the central column: how much of it is NEAR (coverage),
    // and how UNIFORM it is (flatness) — a wall is a large, flat, near surface.
    int centerNear = 0, centerTotal = 0;
    double cSum = 0, cSumSq = 0;

    for (int y = y0; y < y1; y++) {
      final row = d[y];
      for (int x = 0; x < _outW; x++) {
        final c = norm(row[x]);
        if (x < third)          { sumL += c; nL++; }
        else if (x < third * 2) {
          sumC += c; nC++;
          centerTotal++;
          if (c > 0.55) centerNear++;
          cSum += c; cSumSq += c * c;
        } else                  { sumR += c; nR++; }
      }
    }

    final cL = nL > 0 ? sumL / nL : 0.0;
    final cC = nC > 0 ? sumC / nC : 0.0;
    final cR = nR > 0 ? sumR / nR : 0.0;

    // Coverage: fraction of the centre that is near (wall fills the view).
    final coverage = centerTotal > 0 ? centerNear / centerTotal : 0.0;
    // Flatness: low variance of closeness → a smooth surface (wall), not clutter.
    final meanC = centerTotal > 0 ? cSum / centerTotal : 0.0;
    final variance = centerTotal > 0 ? (cSumSq / centerTotal - meanC * meanC) : 1.0;
    final std = sqrt(variance.clamp(0.0, 1.0));
    final flatness = (1.0 - std / 0.22).clamp(0.0, 1.0);

    // Blocked if dead-ahead is near, OR a large near region fills the centre.
    final blocked = cC >= sensitivity || coverage >= 0.60;
    // A WALL = most of the view is near AND flat (uniform surface).
    final isWall = coverage >= 0.70 && flatness >= 0.55;

    String? clear;
    if (blocked && !isWall) {
      if (cL < _clearThreshold && cL <= cR) {
        clear = 'left';
      } else if (cR < _clearThreshold && cR < cL) {
        clear = 'right';
      }
    }

    final sideSum = cL + cR;
    final pan = sideSum > 1e-6 ? ((cR - cL) / sideSum).clamp(-1.0, 1.0) : 0.0;
    final nearest = [cL, cC, cR].reduce((a, b) => a > b ? a : b);

    // Downsampled heatmap for the on-screen overlay.
    final heatmap = _downsample(d, norm);

    debugPrint('FindInFront Depth: L=${cL.toStringAsFixed(2)} '
        'C=${cC.toStringAsFixed(2)} R=${cR.toStringAsFixed(2)} '
        'cover=${coverage.toStringAsFixed(2)} flat=${flatness.toStringAsFixed(2)} '
        'blocked=$blocked wall=$isWall clear=$clear');

    return ObstacleResult(
      closeness: nearest,
      blocked: blocked,
      clearDirection: clear,
      pan: pan,
      isWall: isWall,
      heatmap: heatmap,
    );
  }

  /// Average the full depth map down to a [_grid]×[_grid] normalised grid.
  List<List<double>> _downsample(List<List<double>> d, double Function(double) norm) {
    final cellH = _outH / _grid, cellW = _outW / _grid;
    return List.generate(_grid, (gy) {
      return List.generate(_grid, (gx) {
        double sum = 0; int n = 0;
        final y0 = (gy * cellH).floor(), y1 = ((gy + 1) * cellH).floor();
        final x0 = (gx * cellW).floor(), x1 = ((gx + 1) * cellW).floor();
        for (int y = y0; y < y1; y++) {
          for (int x = x0; x < x1; x++) { sum += norm(d[y][x]); n++; }
        }
        return n > 0 ? sum / n : 0.0;
      });
    });
  }

  /// YUV→RGB, center-crop, rotate upright, ImageNet-normalise → Float32List.
  Float32List _preprocess(CameraImage image, int tw, int th, int rotation) {
    final w = image.width, h = image.height;
    final bool swap = rotation == 90 || rotation == 270;
    final int uw = swap ? h : w;
    final int uh = swap ? w : h;
    final crop = min(uw, uh);
    final offX = (uw - crop) ~/ 2;
    final offY = (uh - crop) ~/ 2;

    final packed = image.planes.length == 1;
    final yB  = image.planes[0].bytes;
    final yRS = image.planes[0].bytesPerRow == 0 ? w : image.planes[0].bytesPerRow;

    final Uint8List uvB;
    final int uvBase, uvRS, uvPS;
    if (packed) {
      uvB = yB; uvBase = yRS * h; uvRS = yRS; uvPS = 2;
    } else {
      uvB = image.planes[1].bytes;
      uvBase = 0;
      uvRS = image.planes[1].bytesPerRow == 0 ? w : image.planes[1].bytesPerRow;
      uvPS = image.planes[1].bytesPerPixel ?? 2;
    }
    final uvMax = uvB.length;

    final out = Float32List(th * tw * 3);

    for (int py = 0; py < th; py++) {
      for (int px = 0; px < tw; px++) {
        final ux = offX + (px * crop ~/ tw);
        final uy = offY + (py * crop ~/ th);
        final int sx, sy;
        switch (rotation) {
          case 90:  sx = uy;         sy = h - 1 - ux; break;
          case 180: sx = w - 1 - ux; sy = h - 1 - uy; break;
          case 270: sx = w - 1 - uy; sy = ux;         break;
          default:  sx = ux;         sy = uy;
        }

        final yVal = yB[sy * yRS + sx] & 0xFF;
        final uvIdx = uvBase + (sy >> 1) * uvRS + (sx >> 1) * uvPS;
        int vVal = 0, uVal = 0;
        if (uvIdx + 1 < uvMax) {
          vVal = (uvB[uvIdx] & 0xFF) - 128;
          uVal = (uvB[uvIdx + 1] & 0xFF) - 128;
        }

        final r = (yVal + 1.402 * vVal).clamp(0.0, 255.0) / 255.0;
        final g = (yVal - 0.344 * uVal - 0.714 * vVal).clamp(0.0, 255.0) / 255.0;
        final b = (yVal + 1.772 * uVal).clamp(0.0, 255.0) / 255.0;

        final idx = (py * tw + px) * 3;
        out[idx]     = (r - _mean[0]) / _std[0];
        out[idx + 1] = (g - _mean[1]) / _std[1];
        out[idx + 2] = (b - _mean[2]) / _std[2];
      }
    }
    return out;
  }

  Future<String> _copyAsset(String assetPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path, p.basename(assetPath));
    final file = File(dest);
    final data = await rootBundle.load(assetPath);
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      await file.writeAsBytes(data.buffer.asUint8List());
      debugPrint('FindInFront Depth: copied ${data.lengthInBytes >> 20} MB');
    }
    return dest;
  }

  Future<void> dispose() async {
    await _isolate?.close();
    _interpreter?.close();
  }
}
