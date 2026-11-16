import 'dart:math' as math;
import 'dart:ui';

typedef Polygon = List<Offset>;

abstract final class Geometry {
  /// Signed area: positive when corners run counter-clockwise in a y-up system.
  static double signedArea(Polygon polygon) {
    if (polygon.length < 3) return 0.0;
    var sum = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      sum += a.dx * b.dy - b.dx * a.dy;
    }
    return sum / 2.0;
  }

  static double area(Polygon polygon) => signedArea(polygon).abs();

  static Offset centroid(Polygon polygon) {
    if (polygon.isEmpty) return Offset.zero;
    var x = 0.0;
    var y = 0.0;
    var k = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      final cross = a.dx * b.dy - b.dx * a.dy;
      x += (a.dx + b.dx) * cross;
      y += (a.dy + b.dy) * cross;
      k += cross * 3.0;
    }
    if (k.abs() <= 1e-12) {
      final count = polygon.length.toDouble();
      var sx = 0.0;
      var sy = 0.0;
      for (final p in polygon) {
        sx += p.dx;
        sy += p.dy;
      }
      return Offset(sx / count, sy / count);
    }
    return Offset(x / k, y / k);
  }

  static Rect bounds(Polygon polygon) {
    if (polygon.isEmpty) return Rect.zero;
    var minX = polygon.first.dx;
    var maxX = polygon.first.dx;
    var minY = polygon.first.dy;
    var maxY = polygon.first.dy;
    for (var i = 1; i < polygon.length; i++) {
      final p = polygon[i];
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Whether a point lies inside a convex polygon (either winding).
  static bool contains(Polygon polygon, Offset point) {
    if (polygon.length < 3) return false;
    var sign = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      final cross =
          (b.dx - a.dx) * (point.dy - a.dy) - (b.dy - a.dy) * (point.dx - a.dx);
      if (cross.abs() < 1e-9) continue;
      if (sign != 0.0 && (cross > 0) != (sign > 0)) return false;
      sign = cross;
    }
    return true;
  }

  /// The part of a polygon where `nx*x + ny*y <= c`.
  static Polygon clip(Polygon polygon, double nx, double ny, double c) {
    if (polygon.length < 3) return const [];
    final result = <Offset>[];
    var previous = polygon.last;
    var previousSide = nx * previous.dx + ny * previous.dy - c;

    for (final current in polygon) {
      final side = nx * current.dx + ny * current.dy - c;
      if ((side <= 0) != (previousSide <= 0)) {
        final t = previousSide / (previousSide - side);
        result.add(Offset(
          previous.dx + (current.dx - previous.dx) * t,
          previous.dy + (current.dy - previous.dy) * t,
        ));
      }
      if (side <= 0) {
        result.add(current);
      }
      previous = current;
      previousSide = side;
    }
    return result.length >= 3 ? result : const [];
  }

  /// The part of `subject` inside the convex polygon `clipPoly`, keeping `inset`
  /// away from its edges.
  static Polygon clipToConvex(
    Polygon subject,
    Polygon clipPoly, {
    double inset = 0.0,
  }) {
    if (clipPoly.length < 3) return const [];
    final orientation = signedArea(clipPoly) >= 0 ? 1.0 : -1.0;
    var result = subject;
    for (var i = 0; i < clipPoly.length && result.length >= 3; i++) {
      final a = clipPoly[i];
      final b = clipPoly[(i + 1) % clipPoly.length];
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      final length = math.sqrt(dx * dx + dy * dy);
      if (length < 1e-9) continue;
      final nx = dy / length * orientation;
      final ny = -dx / length * orientation;
      result = clip(result, nx, ny, nx * a.dx + ny * a.dy - inset);
    }
    return result.length >= 3 ? result : const [];
  }

  /// A convex polygon shrunk by `distance` on every side; empty when nothing is left.
  static Polygon inset(Polygon polygon, double distance) {
    return clipToConvex(polygon, polygon, inset: distance);
  }

  /// A rounded rectangle as a polygon.
  static Polygon roundedRect(Rect rect, {required double radius, int steps = 8}) {
    final r = math.min(radius, math.min(rect.width, rect.height) / 2.0);
    final corners = <(double, double, double)>[
      (rect.right - r, rect.top + r, -math.pi / 2.0),
      (rect.right - r, rect.bottom - r, 0.0),
      (rect.left + r, rect.bottom - r, math.pi / 2.0),
      (rect.left + r, rect.top + r, math.pi),
    ];
    final points = <Offset>[];
    for (final (cx, cy, start) in corners) {
      for (var step = 0; step <= steps; step++) {
        final angle = start + (math.pi / 2.0) * step / steps;
        points.add(Offset(cx + r * math.cos(angle), cy + r * math.sin(angle)));
      }
    }
    return points;
  }

  /// Rounds the corners of a polygon using Chaikin's scheme.
  static Polygon soften(Polygon polygon, {required double cap, int passes = 3}) {
    var current = polygon;
    var limit = cap;
    for (var pass = 0; pass < passes && current.length >= 3; pass++) {
      final next = <Offset>[];
      for (var i = 0; i < current.length; i++) {
        final a = current[i];
        final b = current[(i + 1) % current.length];
        final dx = b.dx - a.dx;
        final dy = b.dy - a.dy;
        final length = math.sqrt(dx * dx + dy * dy);
        if (length < 0.5) {
          next.add(Offset((a.dx + b.dx) / 2.0, (a.dy + b.dy) / 2.0));
          continue;
        }
        final cut = math.min(length * 0.25, limit) / length;
        next.add(Offset(a.dx + dx * cut, a.dy + dy * cut));
        next.add(Offset(b.dx - dx * cut, b.dy - dy * cut));
      }
      current = next;
      limit /= 2.0;
    }
    return current;
  }

  static (double, double)? horizontalSpan(Polygon polygon, double y) {
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      if ((a.dy <= y) == (b.dy <= y)) continue;
      final x = a.dx + (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy);
      if (x < low) low = x;
      if (x > high) high = x;
    }
    return low <= high ? (low, high) : null;
  }

  static (double, double)? verticalSpan(Polygon polygon, double x) {
    final swapped = polygon.map((p) => Offset(p.dy, p.dx)).toList(growable: false);
    return horizontalSpan(swapped, x);
  }
}
