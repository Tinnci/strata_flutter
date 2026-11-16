import 'dart:math' as math;
import 'dart:ui';

import 'geometry.dart';
import 'squarify.dart';

/// Organic cells that press against each other and fill a region, each with an
/// area in proportion to its size (a Voronoi treemap built on power diagrams).
abstract final class BubbleLayout {
  static List<Polygon> powerCells({
    required List<Offset> sites,
    required List<double> weights,
    required Polygon region,
  }) {
    final cells = <Polygon>[];
    for (var i = 0; i < sites.length; i++) {
      var cell = region;
      final sx = sites[i].dx;
      final sy = sites[i].dy;
      final own = sx * sx + sy * sy - weights[i];
      for (var j = 0; j < sites.length && cell.length >= 3; j++) {
        if (j == i) continue;
        final tx = sites[j].dx;
        final ty = sites[j].dy;
        cell = Geometry.clip(
          cell,
          tx - sx,
          ty - sy,
          (tx * tx + ty * ty - weights[j] - own) / 2.0,
        );
      }
      cells.add(cell);
    }
    return cells;
  }

  static List<Polygon> ordered({
    required List<double> sizes,
    required Polygon region,
    double tolerance = 0.01,
    int maximumIterations = 240,
  }) {
    final count = sizes.length;
    final regionArea = Geometry.area(region);
    if (count == 0 || regionArea <= 0) {
      return List<Polygon>.filled(count, const []);
    }
    if (count == 1) return [region];

    final total = math.max(
      sizes.fold<double>(0.0, (a, b) => a + b),
      double.minPositive,
    );
    var shares = sizes.map((s) => math.max(s / total, 0.0015)).toList();
    final shareSum = shares.fold<double>(0.0, (a, b) => a + b);
    shares = shares.map((s) => s / shareSum).toList(growable: false);
    final targets = shares.map((s) => s * regionArea).toList(growable: false);

    final box = Geometry.bounds(region);
    final middle = Geometry.centroid(region);
    final sites = Squarify.rects(shares, box).map((rect) {
      var point = rect.center;
      var steps = 0;
      while (!Geometry.contains(region, point) && steps < 24) {
        point = Offset(
          point.dx + (middle.dx - point.dx) * 0.15,
          point.dy + (middle.dy - point.dy) * 0.15,
        );
        steps++;
      }
      return point;
    }).toList();

    final weights = targets.map((t) => t / math.pi).toList();

    var best = <Polygon>[];
    var bestError = double.infinity;

    for (var iter = 0; iter < maximumIterations; iter++) {
      final cells = powerCells(sites: sites, weights: weights, region: region);
      var worst = 0.0;
      final areas = List<double>.filled(count, 0.0);
      for (var i = 0; i < count; i++) {
        areas[i] = Geometry.area(cells[i]);
        final err = (areas[i] - targets[i]).abs() / targets[i];
        if (err > worst) worst = err;
      }
      if (worst < bestError) {
        bestError = worst;
        best = cells;
      }
      if (worst < tolerance) break;

      for (var i = 0; i < count; i++) {
        if (areas[i] > 0) {
          sites[i] = Geometry.centroid(cells[i]);
        }
        weights[i] += (targets[i] - areas[i]) / math.pi * 0.9;
      }
    }

    return best;
  }
}
