import 'dart:math' as math;
import 'dart:ui';

/// The classic squarified treemap: fills a rectangle with one rectangle per value,
/// areas in proportion, keeping them close to square.
abstract final class Squarify {
  static List<Rect> rects(List<double> values, Rect rect) {
    final total = values.fold<double>(0.0, (a, b) => a + b);
    if (total <= 0 || rect.width <= 0 || rect.height <= 0) {
      return List<Rect>.filled(
        values.length,
        Rect.fromLTWH(rect.left, rect.top, 0, 0),
      );
    }

    final scale = (rect.width * rect.height) / total;
    final areas = values
        .map((v) => math.max(v * scale, 1e-9))
        .toList(growable: false);

    final result = List<Rect>.filled(values.length, Rect.zero);
    var remaining = rect;
    final row = <int>[];
    var rowArea = 0.0;

    double worst(List<int> indices, double sum, double side) {
      if (indices.isEmpty || sum <= 0 || side <= 0) return double.infinity;
      final thickness = sum / side;
      var ratio = 0.0;
      for (final index in indices) {
        final length = areas[index] / thickness;
        ratio = math.max(
          ratio,
          math.max(length / thickness, thickness / length),
        );
      }
      return ratio;
    }

    void flush() {
      if (row.isEmpty) return;
      final horizontal = remaining.width >= remaining.height;
      final side = horizontal ? remaining.height : remaining.width;
      final thickness = rowArea / side;
      var offset = 0.0;
      for (final index in row) {
        final length = areas[index] / thickness;
        result[index] = horizontal
            ? Rect.fromLTWH(
                remaining.left,
                remaining.top + offset,
                thickness,
                length,
              )
            : Rect.fromLTWH(
                remaining.left + offset,
                remaining.top,
                length,
                thickness,
              );
        offset += length;
      }
      if (horizontal) {
        remaining = Rect.fromLTWH(
          remaining.left + thickness,
          remaining.top,
          math.max(0.0, remaining.width - thickness),
          remaining.height,
        );
      } else {
        remaining = Rect.fromLTWH(
          remaining.left,
          remaining.top + thickness,
          remaining.width,
          math.max(0.0, remaining.height - thickness),
        );
      }
      row.clear();
      rowArea = 0.0;
    }

    for (var i = 0; i < areas.length; i++) {
      final side = math.min(remaining.width, remaining.height);
      if (row.isNotEmpty &&
          worst([...row, i], rowArea + areas[i], side) >
              worst(row, rowArea, side)) {
        flush();
      }
      row.add(i);
      rowArea += areas[i];
    }
    flush();
    return result;
  }
}
