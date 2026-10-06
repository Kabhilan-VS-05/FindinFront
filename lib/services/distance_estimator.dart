import 'dart:math';

/// Estimates the distance to a detected object.
///
/// On the low-end phones FindInFront targets there is no usable depth sensor
/// (proximity sensors only work at a few centimetres; ToF/LiDAR are absent),
/// so distance is *estimated* from how large the object appears in the frame.
///
/// The design is pluggable: [estimateMeters] is the only thing the rest of the
/// app depends on. If we ever run on a device with a real depth sensor, a
/// `SensorDistanceEstimator` can implement the same contract and be swapped in.
abstract class DistanceEstimator {
  /// Returns the estimated distance in metres for an object whose bounding box
  /// occupies [boxHeightFraction] of the frame height (0..1).
  /// [label] selects the assumed real-world size of the object.
  double estimateMeters(String label, double boxHeightFraction);
}

/// Monocular (single-camera) distance estimate.
///
/// Geometry: an object of real height `H` at distance `D`, seen through a
/// camera with vertical field-of-view `θ`, fills a fraction `f` of the frame
/// height where  f ≈ H / (2·D·tan(θ/2)).  Solving for D:
///
///     D ≈ H / (2·f·tan(θ/2))  =  k · H / f
///
/// with k = 1 / (2·tan(θ/2)).  For a typical phone vertical FOV of ~60°,
/// tan(30°) ≈ 0.577, so k ≈ 0.87.
class CameraDistanceEstimator implements DistanceEstimator {
  CameraDistanceEstimator({double verticalFovDegrees = 60.0})
      : _k = 1.0 / (2.0 * tan((verticalFovDegrees * pi / 180.0) / 2.0));

  final double _k;

  /// Assumed real-world height in metres for common COCO classes.
  /// These are rough averages — enough for "near vs far", not survey-grade.
  static const Map<String, double> _realHeights = {
    'person': 1.70,
    'bicycle': 1.10,
    'car': 1.50,
    'motorcycle': 1.30,
    'bus': 3.20,
    'truck': 3.50,
    'cat': 0.30,
    'dog': 0.50,
    'chair': 0.90,
    'couch': 0.80,
    'bed': 0.60,
    'dining table': 0.75,
    'tv': 0.60,
    'laptop': 0.25,
    'bottle': 0.25,
    'cup': 0.12,
    'door': 2.00,
    'potted plant': 0.50,
    'backpack': 0.45,
    'umbrella': 0.90,
    'suitcase': 0.55,
    'refrigerator': 1.70,
    'oven': 0.60,
    'microwave': 0.30,
    'toilet': 0.70,
    'sink': 0.20,
  };

  /// Fallback real height when the class is not in the table.
  static const double _defaultHeight = 0.50;

  @override
  double estimateMeters(String label, double boxHeightFraction) {
    if (boxHeightFraction <= 0) return double.infinity;
    final h = _realHeights[label.toLowerCase()] ?? _defaultHeight;
    final d = _k * h / boxHeightFraction;
    // Clamp to a sane range so a sliver of an object doesn't read as 50 m.
    return d.clamp(0.2, 15.0);
  }
}
