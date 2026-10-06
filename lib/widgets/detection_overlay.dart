import 'package:flutter/material.dart';
import '../services/detector_service.dart';
import '../services/depth_service.dart';

class DetectionOverlay extends StatelessWidget {
  final DetectionResult? detection;
  final ObstacleResult? obstacle;
  final double closeness; // 0..1 live proximity
  final double pan;       // -1 left .. 1 right
  final bool isVoiceMode; // true = voice, false = vibrate
  final bool showHeatmap; // depth heatmap overlay on/off
  final String? debugStatus; // shown below the detection card when not null

  const DetectionOverlay({
    super.key,
    required this.detection,
    required this.obstacle,
    required this.closeness,
    required this.pan,
    required this.isVoiceMode,
    this.showHeatmap = false,
    this.debugStatus,
  });

  String _distanceText(double d) {
    if (d < 1.0) return 'Very close';
    if (d < 3.0) return '${d.toStringAsFixed(1)} m away';
    return '${d.toStringAsFixed(0)} m away';
  }

  // Live proximity bar: fills with closeness, colour shifts green→amber→red,
  // and a marker shows which side (left/right) the obstacle is on.
  Widget _proximityBar() {
    final c = closeness.clamp(0.0, 1.0);
    final color = c < 0.45
        ? Colors.greenAccent.shade400
        : (c < 0.75 ? Colors.amber : Colors.redAccent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                Container(height: 14, color: Colors.white12),
                FractionallySizedBox(
                  widthFactor: c,
                  child: Container(height: 14, color: color),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Left / centre / right azimuth indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('◀ L',
                  style: TextStyle(
                      color: pan < -0.25 && c > 0.3 ? color : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold)),
              Text('•',
                  style: TextStyle(
                      color: pan.abs() <= 0.25 && c > 0.3 ? color : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold)),
              Text('R ▶',
                  style: TextStyle(
                      color: pan > 0.25 && c > 0.3 ? color : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _obstacleBanner() {
    final o = obstacle!;
    final wall = o.isWall;
    final headline = wall ? 'WALL AHEAD' : 'OBSTACLE';
    final action = wall
        ? 'STOP'
        : (o.clearDirection != null
            ? 'MOVE ${o.clearDirection!.toUpperCase()}'
            : 'STOP');
    final arrow = o.clearDirection == 'left'
        ? Icons.arrow_back
        : o.clearDirection == 'right'
            ? Icons.arrow_forward
            : Icons.front_hand;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: o.isUrgent ? Colors.red.shade700 : Colors.orange.shade800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Row(
        children: [
          Icon(arrow, color: Colors.white, size: 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600)),
                Text(action,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Depth heatmap painted over the camera (red = close, blue = far)
        if (showHeatmap && obstacle != null)
          Positioned.fill(
            child: CustomPaint(painter: _HeatmapPainter(obstacle!.heatmap)),
          ),
        _buildHud(),
      ],
    );
  }

  Widget _buildHud() {
    return Column(
      children: [
        // Top status bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Scanning dot
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8, height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'SCANNING',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                // Alert mode badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isVoiceMode ? '🔊 VOICE' : '📳 VIBRATE',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Obstacle / wall warning banner — large, high-contrast, center screen
        if (obstacle != null && obstacle!.blocked) _obstacleBanner(),

        const Spacer(),

        // Live proximity bar (above the name card)
        _proximityBar(),

        // Bottom detection card
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: detection != null
                ? (detection!.isClose ? Colors.red.shade900 : Colors.black87)
                : Colors.black54,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: detection != null ? Colors.white30 : Colors.white10,
            ),
          ),
          child: detection != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detection!.isClose ? '⚠  CLOSE' : 'DETECTED',
                      style: TextStyle(
                        color: detection!.isClose
                            ? Colors.redAccent.shade100
                            : Colors.white54,
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      detection!.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _distanceText(detection!.distanceMeters),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 18,
                      ),
                    ),
                  ],
                )
              : const Center(
                  child: Text(
                    'Looking for objects...',
                    style: TextStyle(color: Colors.white38, fontSize: 18),
                  ),
                ),
        ),

        // Debug status line (shows model type, errors, etc.)
        if (debugStatus != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              debugStatus!,
              style: const TextStyle(color: Colors.white24, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

/// Paints the downsampled depth grid as a translucent heatmap.
/// blue (far) → green → yellow → red (near).
class _HeatmapPainter extends CustomPainter {
  final List<List<double>> grid;
  _HeatmapPainter(this.grid);

  Color _color(double c) {
    // c: 0 far → 1 near
    if (c < 0.5) {
      // blue → green
      final t = c / 0.5;
      return Color.lerp(Colors.blue, Colors.green, t)!;
    } else {
      // green → yellow → red
      final t = (c - 0.5) / 0.5;
      return Color.lerp(Colors.green, Colors.red, t)!;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (grid.isEmpty) return;
    final rows = grid.length, cols = grid[0].length;
    final cw = size.width / cols, ch = size.height / rows;
    final paint = Paint();
    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < cols; x++) {
        final c = grid[y][x].clamp(0.0, 1.0);
        paint.color = _color(c).withValues(alpha: 0.45);
        canvas.drawRect(
          Rect.fromLTWH(x * cw, y * ch, cw + 0.5, ch + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => old.grid != grid;
}
