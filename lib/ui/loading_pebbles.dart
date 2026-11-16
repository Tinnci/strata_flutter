import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../layout/bubble_layout.dart';
import '../layout/geometry.dart';
import '../model/file_tree.dart';
import '../motion/motion.dart';
import '../theme/theme.dart';

class PebbleLoader extends StatefulWidget {
  const PebbleLoader({super.key, required this.theme});

  final StrataTheme theme;

  @override
  State<PebbleLoader> createState() => _PebbleLoaderState();
}

class _PebbleLoaderState extends State<PebbleLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_MiniPebble> _pebbles;

  @override
  void initState() {
    super.initState();
    _pebbles = _buildPebbles();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<_MiniPebble> _buildPebbles() {
    const sizes = [38.0, 26.0, 20.0, 15.0, 11.0, 14.0];
    final region = Geometry.roundedRect(
      const Rect.fromLTWH(0, 0, 210, 148),
      radius: 26,
    );
    final polys = BubbleLayout.ordered(sizes: sizes, region: region);
    final result = <_MiniPebble>[];

    for (var i = 0; i < polys.length; i++) {
      final insetPoly = Geometry.inset(polys[i], 3.4);
      if (insetPoly.length < 3) continue;
      final center = Geometry.centroid(insetPoly);
      final path = _toSmoothPath(insetPoly, radius: 14.0);
      final isFree = i == polys.length - 1;
      result.add(
        _MiniPebble(
          path: path,
          dots: isFree ? _dotField(Geometry.inset(insetPoly, 4.5)) : null,
          center: center,
          toneIndex: i,
          isFree: isFree,
        ),
      );
    }
    return result;
  }

  static Path _toSmoothPath(Polygon poly, {required double radius}) {
    final path = Path();
    if (poly.length < 3) return path;
    var started = false;
    for (var i = 0; i < poly.length; i++) {
      final prev = poly[(i - 1 + poly.length) % poly.length];
      final curr = poly[i];
      final next = poly[(i + 1) % poly.length];
      final dxIn = curr.dx - prev.dx;
      final dyIn = curr.dy - prev.dy;
      final lenIn = math.sqrt(dxIn * dxIn + dyIn * dyIn);
      final dxOut = next.dx - curr.dx;
      final dyOut = next.dy - curr.dy;
      final lenOut = math.sqrt(dxOut * dxOut + dyOut * dyOut);
      if (lenIn < 0.5 || lenOut < 0.5) {
        if (!started) {
          path.moveTo(curr.dx, curr.dy);
          started = true;
        } else {
          path.lineTo(curr.dx, curr.dy);
        }
        continue;
      }
      final cutIn = math.min(lenIn * 0.42, radius) / lenIn;
      final cutOut = math.min(lenOut * 0.42, radius) / lenOut;
      final enter = Offset(curr.dx - dxIn * cutIn, curr.dy - dyIn * cutIn);
      final exit = Offset(curr.dx + dxOut * cutOut, curr.dy + dyOut * cutOut);
      if (!started) {
        path.moveTo(enter.dx, enter.dy);
        started = true;
      } else {
        path.lineTo(enter.dx, enter.dy);
      }
      path.quadraticBezierTo(curr.dx, curr.dy, exit.dx, exit.dy);
    }
    path.close();
    return path;
  }

  static Path? _dotField(Polygon poly) {
    if (poly.length < 3) return null;
    final box = Geometry.bounds(poly);
    const step = 8.0;
    final path = Path();
    var row = 0;
    for (var y = box.top + step * 0.5; y < box.bottom; y += step) {
      final shift = row.isOdd ? step * 0.5 : 0.0;
      for (var x = box.left + step * 0.5 + shift; x < box.right; x += step) {
        final p = Offset(x, y);
        if (Geometry.contains(poly, p)) {
          path.addOval(Rect.fromCircle(center: p, radius: 0.95));
        }
      }
      row++;
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      height: 148,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _PebbleLoaderPainter(
              pebbles: _pebbles,
              theme: widget.theme,
              elapsedSeconds: _controller.lastElapsedDuration?.inMicroseconds != null
                  ? _controller.lastElapsedDuration!.inMicroseconds / 1e6
                  : _controller.value * 6.0,
              phaseAngle: _controller.value * math.pi * 2.0,
            ),
          );
        },
      ),
    );
  }
}

class _MiniPebble {
  const _MiniPebble({
    required this.path,
    required this.dots,
    required this.center,
    required this.toneIndex,
    required this.isFree,
  });

  final Path path;
  final Path? dots;
  final Offset center;
  final int toneIndex;
  final bool isFree;
}

class _PebbleLoaderPainter extends CustomPainter {
  const _PebbleLoaderPainter({
    required this.pebbles,
    required this.theme,
    required this.elapsedSeconds,
    required this.phaseAngle,
  });

  final List<_MiniPebble> pebbles;
  final StrataTheme theme;
  final double elapsedSeconds;
  final double phaseAngle;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < pebbles.length; i++) {
      final p = pebbles[i];
      final appear = Spring.response(elapsedSeconds - i * 0.055);
      if (appear <= 0.01) continue;

      final breathe = 1.0 + 0.032 * math.sin(phaseAngle + i * 1.05);
      final scale = (0.72 + 0.28 * appear) * breathe;
      final tx = p.center.dx * (1.0 - scale);
      final ty = p.center.dy * (1.0 - scale);
      final matrix = Float64List.fromList([
        scale, 0, 0, 0,
        0, scale, 0, 0,
        0, 0, 1, 0,
        tx, ty, 0, 1,
      ]);

      final alpha = (appear * 1.4).clamp(0.0, 1.0);
      final transformed = p.path.transform(matrix);

      if (p.isFree) {
        strokePaint.color = theme.line.color.withValues(alpha: 0.42 * alpha);
        canvas.drawPath(transformed, strokePaint);
        if (p.dots != null) {
          fillPaint.color = theme.line.color.withValues(alpha: 0.28 * alpha);
          canvas.drawPath(p.dots!.transform(matrix), fillPaint);
        }
      } else {
        final shift = 0.035 * math.sin(phaseAngle + i * 1.05);
        final color = theme.tones[p.toneIndex % theme.tones.length].lighter(shift);
        fillPaint.color = color.color.withValues(alpha: alpha);
        canvas.drawPath(transformed, fillPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PebbleLoaderPainter oldDelegate) => true;
}

class StrataLoadingView extends StatelessWidget {
  const StrataLoadingView({
    super.key,
    required this.theme,
    required this.volume,
    required this.entryCount,
    required this.scannedBytes,
    required this.themeDots,
    this.rightBarPadding = 22.0,
  });

  final StrataTheme theme;
  final DiskVolume? volume;
  final int entryCount;
  final int scannedBytes;
  final Widget themeDots;
  final double rightBarPadding;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 36, 16, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  volume?.name ?? '正在读取磁盘…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: theme.line.color.withValues(alpha: 0.28),
                      width: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  '最大的',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: theme.secondaryText.color,
                  ),
                ),
                const SizedBox(height: 14),
                for (var i = 0; i < 6; i++) ...[
                  Row(
                    children: [
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: theme.line.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3.5),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 150.0 - i * 16.0,
                        height: 12,
                        decoration: BoxDecoration(
                          color: theme.line.color.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
                const Spacer(),
                Text(
                  entryCount > 0
                      ? '正在扫描 · 已看过 ${Format.count(entryCount)} 项'
                      : '正在准备扫描…',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.secondaryText.color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              SizedBox(
                height: 54,
                child: Padding(
                  padding: EdgeInsets.only(right: rightBarPadding),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [themeDots],
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PebbleLoader(theme: theme),
                      const SizedBox(height: 24),
                      Text(
                        volume != null
                            ? '正在扫描 ${volume!.name}'
                            : '正在读取磁盘列表',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: theme.text.color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entryCount > 0
                            ? '已看过 ${Format.count(entryCount)} 项 · ${Format.size(scannedBytes)}'
                            : '马上就能看到磁盘空间分布',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: theme.secondaryText.color,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
