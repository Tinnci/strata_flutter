import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:material_ui/material_ui.dart'
    show FontWeight, TextPainter, TextSpan, TextStyle, TextDirection;

import '../model/file_tree.dart';
import '../motion/motion_state.dart';
import '../scene/map_scene.dart';
import '../theme/theme.dart';
import '../theme/typography.dart';

class MapFrame {
  const MapFrame({
    required this.theme,
    required this.lift,
    required this.appear,
    this.smallest = 0.74,
    this.solidity = 1.5,
  });

  final StrataTheme theme;
  final double Function(int id) lift;
  final double Function(int order) appear;
  final double smallest;
  final double solidity;

  factory MapFrame.leaving(StrataTheme theme, double elapsed) {
    return MapFrame(
      theme: theme,
      lift: (_) => 0.0,
      appear: (order) => SwapTiming.leaving(order, elapsed),
      smallest: 0.3,
      solidity: 1.15,
    );
  }
}

double _unit(double v) => v.clamp(0.0, 1.0);

Float64List _scaleAbout(Offset point, double factor) {
  final tx = point.dx * (1.0 - factor);
  final ty = point.dy * (1.0 - factor);
  return Float64List.fromList([
    factor,
    0,
    0,
    0,
    0,
    factor,
    0,
    0,
    0,
    0,
    1,
    0,
    tx,
    ty,
    0,
    1,
  ]);
}

Float64List _scaleXYAbout(Offset point, double sx, double sy) {
  final tx = point.dx * (1.0 - sx);
  final ty = point.dy * (1.0 - sy);
  return Float64List.fromList([
    sx,
    0,
    0,
    0,
    0,
    sy,
    0,
    0,
    0,
    0,
    1,
    0,
    tx,
    ty,
    0,
    1,
  ]);
}

Offset _transformPoint(Offset p, Float64List m) {
  return Offset(
    m[0] * p.dx + m[4] * p.dy + m[12],
    m[1] * p.dx + m[5] * p.dy + m[13],
  );
}

Float64List _concat(Float64List a, Float64List b) {
  final out = Float64List(16);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += a[row + k * 4] * b[k + col * 4];
      }
      out[row + col * 4] = sum;
    }
  }
  return out;
}

void _drawLabel(
  Canvas canvas,
  MarkLabel? label,
  Offset point,
  Color ink,
  double opacity,
) {
  if (label == null || opacity <= 0.02) return;
  final effectiveColor = ink.withValues(alpha: ink.a * opacity);
  final fontFamily = StrataTypography.primaryFontFamily;
  final fontFallback = StrataTypography.fallbackFor(null);

  final namePainter = TextPainter(
    text: TextSpan(
      text: label.name,
      style: TextStyle(
        color: effectiveColor,
        fontSize: label.fontSize,
        fontWeight: FontWeight.w600,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFallback,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  if (label.size != null) {
    namePainter.paint(
      canvas,
      Offset(
        point.dx - namePainter.width / 2.0,
        point.dy - label.fontSize * 0.58 - namePainter.height / 2.0,
      ),
    );

    final sizePainter = TextPainter(
      text: TextSpan(
        text: label.size,
        style: TextStyle(
          color: effectiveColor.withValues(alpha: effectiveColor.a * 0.78),
          fontSize: label.fontSize - 1.0,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    sizePainter.paint(
      canvas,
      Offset(
        point.dx - sizePainter.width / 2.0,
        point.dy + label.fontSize * 0.74 - sizePainter.height / 2.0,
      ),
    );
  } else {
    namePainter.paint(
      canvas,
      Offset(
        point.dx - namePainter.width / 2.0,
        point.dy - namePainter.height / 2.0,
      ),
    );
  }
}

void _drawFree(
  Canvas canvas,
  Path shape,
  Path? dots,
  Float64List transform,
  StrataTheme theme,
  double opacity,
) {
  final lineColor = theme.line.color;
  final strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = lineColor.withValues(alpha: 0.42 * opacity);
  canvas.drawPath(shape.transform(transform), strokePaint);

  if (dots != null) {
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = lineColor.withValues(alpha: 0.26 * opacity);
    canvas.drawPath(dots.transform(transform), dotPaint);
  }
}

void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    const dash = 3.0;
    const gap = 4.0;
    while (distance < metric.length) {
      final end = math.min(distance + dash, metric.length);
      canvas.drawPath(metric.extractPath(distance, end), paint);
      distance += dash + gap;
    }
  }
}

abstract final class MapRenderer {
  static void drawTextLabel(
    Canvas canvas,
    MarkLabel? label,
    Offset point,
    Color ink,
    double opacity,
  ) => _drawLabel(canvas, label, point, ink, opacity);

  static void drawFreePath(
    Canvas canvas,
    Path shape,
    Path? dots,
    Float64List transform,
    StrataTheme theme,
    double opacity,
  ) => _drawFree(canvas, shape, dots, transform, theme, opacity);

  static void drawDashed(Canvas canvas, Path path, Paint paint) =>
      _drawDashedPath(canvas, path, paint);

  static void drawScene(
    MapScene scene, {
    required MapFrame frame,
    required int? flowFocus,
    required Canvas canvas,
  }) {
    switch (scene.mode) {
      case MapMode.bubbles:
        if (scene.bubbles != null) {
          _drawBubbles(scene.bubbles!, frame, canvas);
        }
      case MapMode.flow:
        if (scene.flow != null) {
          _drawFlow(scene.flow!, frame, flowFocus, canvas);
        }
    }
  }

  static void _drawBubbles(BubbleScene scene, MapFrame frame, Canvas canvas) {
    final theme = frame.theme;
    final transforms = <int, Float64List>{};
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // Draw resting bubbles first and hovered/lifting bubbles last so swollen
    // pebbles and their accent strokes always appear above neighbours.
    final topEntries = <(int order, int index)>[
      for (var order = 0; order < scene.top.length; order++)
        (order, scene.top[order]),
    ]..sort((a, b) => frame.lift(a.$2).compareTo(frame.lift(b.$2)));

    for (final (order, index) in topEntries) {
      final cell = scene.cells[index];
      final appear = frame.appear(order);
      if (appear <= 0.001) continue;

      final lift = frame.lift(index);
      final scaleFactor =
          (frame.smallest + (1.0 - frame.smallest) * appear) *
          (1.0 + 0.02 * lift);
      final outer = _scaleAbout(cell.center, scaleFactor);
      transforms[index] = outer;
      final layerAlpha = _unit(appear * frame.solidity);

      if (cell.item.kind == MapItemKind.free) {
        _drawFree(canvas, cell.outline, cell.dots, outer, theme, layerAlpha);
        continue;
      }

      final fill = theme.fill(cell.tone);
      if (lift > 0.05 && cell.item.kind != MapItemKind.hidden && cell.item.kind != MapItemKind.unscanned) {
        final shadowPaint = Paint()
          ..color = const Color(0xFF000000).withValues(
            alpha: (theme.isDark ? 0.28 : 0.12) * _unit(lift) * layerAlpha,
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
        canvas.drawPath(
          cell.outline.transform(outer).shift(const Offset(0, 3)),
          shadowPaint,
        );
      }
      if (cell.children.isEmpty) {
        final path = cell.outline.transform(outer);
        fillPaint.color = fill
            .lighter(0.03 * _unit(lift))
            .color
            .withValues(alpha: layerAlpha);
        canvas.drawPath(path, fillPaint);

        if (cell.item.kind == MapItemKind.hidden ||
            cell.item.kind == MapItemKind.unscanned) {
          strokePaint
            ..strokeWidth = 1.0
            ..color = theme.line.color.withValues(alpha: 0.28 * layerAlpha);
          _drawDashedPath(canvas, path, strokePaint);
        } else if (lift > 0.02) {
          strokePaint
            ..strokeWidth = 1.5
            ..color = theme.accent.color.withValues(
              alpha: _unit(lift) * layerAlpha,
            );
          canvas.drawPath(path, strokePaint);
        }
        continue;
      }

      fillPaint.color = theme
          .wall(cell.tone)
          .color
          .withValues(alpha: layerAlpha);
      canvas.drawPath(cell.outline.transform(outer), fillPaint);

      final orderedChildren = List<int>.from(cell.children)
        ..sort((a, b) => frame.lift(a).compareTo(frame.lift(b)));

      for (final childIndex in orderedChildren) {
        final child = scene.cells[childIndex];
        final childLift = frame.lift(childIndex);
        final middleLocal = _scaleAbout(
          child.center,
          1.0 - 0.035 * _unit(lift) + 0.055 * childLift,
        );
        final middle = _concat(outer, middleLocal);
        transforms[childIndex] = middle;

        final childPath = child.outline.transform(middle);
        fillPaint.color = theme
            .fill(child.tone)
            .lighter(0.035 * _unit(childLift))
            .color
            .withValues(alpha: layerAlpha);
        canvas.drawPath(childPath, fillPaint);

        for (final grandIndex in child.children) {
          final grand = scene.cells[grandIndex];
          final innerLocal = _scaleAbout(
            grand.center,
            1.0 - 0.07 * _unit(childLift),
          );
          final inner = _concat(middle, innerLocal);
          transforms[grandIndex] = inner;
          fillPaint.color = theme
              .fill(grand.tone)
              .color
              .withValues(alpha: layerAlpha);
          canvas.drawPath(grand.outline.transform(inner), fillPaint);
        }

        if (childLift > 0.02) {
          strokePaint
            ..strokeWidth = 1.5
            ..color = theme.accent.color.withValues(
              alpha: _unit(childLift) * layerAlpha,
            );
          canvas.drawPath(childPath, strokePaint);
        }
      }
    }

    // Labels drawn on top of every fill.
    for (final (order, index) in topEntries) {
      final outer = transforms[index];
      if (outer == null) continue;
      final cell = scene.cells[index];
      final layerAlpha = _unit(frame.appear(order) * frame.solidity);
      final lift = _unit(frame.lift(index));
      final at = _transformPoint(cell.center, outer);

      if (cell.item.kind == MapItemKind.free) {
        _drawLabel(canvas, cell.label, at, theme.text.color, layerAlpha);
        continue;
      }
      if (cell.item.kind == MapItemKind.hidden ||
          cell.item.kind == MapItemKind.unscanned) {
        _drawLabel(
          canvas,
          cell.label,
          at,
          theme.secondaryText.color,
          layerAlpha,
        );
        continue;
      }

      final opensUp = cell.children.any((c) => scene.cells[c].label != null);
      final ink = theme.ink(
        cell.children.isEmpty
            ? theme.fill(cell.tone)
            : theme.fill(scene.cells[cell.children[0]].tone),
      );
      _drawLabel(
        canvas,
        cell.label,
        at,
        ink.color,
        (opensUp ? 1.0 - lift : 1.0) * layerAlpha,
      );
      if (lift <= 0.02) continue;

      final orderedChildren = List<int>.from(cell.children)
        ..sort((a, b) => frame.lift(a).compareTo(frame.lift(b)));

      for (final childIndex in orderedChildren) {
        final middle = transforms[childIndex];
        if (middle == null) continue;
        final child = scene.cells[childIndex];
        final childLift = _unit(frame.lift(childIndex));
        final showsInside = child.children.any(
          (g) => scene.cells[g].label != null,
        );
        _drawLabel(
          canvas,
          child.label,
          _transformPoint(child.center, middle),
          theme.ink(theme.fill(child.tone)).color,
          lift * (showsInside ? 1.0 - childLift : 1.0) * layerAlpha,
        );
        if (childLift <= 0.02) continue;
        for (final grandIndex in child.children) {
          final inner = transforms[grandIndex];
          if (inner == null) continue;
          final grand = scene.cells[grandIndex];
          _drawLabel(
            canvas,
            grand.label,
            _transformPoint(grand.center, inner),
            theme.ink(theme.fill(grand.tone)).color,
            childLift * layerAlpha,
          );
        }
      }
    }
  }

  static void _drawFlow(
    FlowScene scene,
    MapFrame frame,
    int? focus,
    Canvas canvas,
  ) {
    final theme = frame.theme;
    final strength = focus != null ? _unit(frame.lift(focus)) : 0.0;
    final family = focus != null ? scene.familyOf(focus) : const <int>{};
    double presence(int bar) =>
        family.isEmpty || family.contains(bar) ? 1.0 : 1.0 - 0.55 * strength;

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    for (final ribbon in scene.ribbons) {
      final appear = _unit(
        frame.appear(scene.bars[ribbon.child].level * 4) *
            frame.solidity *
            0.93,
      );
      if (appear <= 0.01) continue;
      final tone = scene.bars[ribbon.child].tone;
      final color = (tone.role == ToneRole.free || tone.role == ToneRole.hidden)
          ? theme.neutral
          : theme.fill(tone);
      final related =
          family.contains(ribbon.parent) && family.contains(ribbon.child);
      final opacity =
          (0.4 + (related ? 0.3 * strength : 0.0)) *
          math.min(presence(ribbon.parent), presence(ribbon.child));
      fillPaint.color = color.color.withValues(alpha: opacity * appear);
      canvas.drawPath(ribbon.path, fillPaint);
    }

    final barOrder = List<int>.generate(scene.bars.length, (i) => i)
      ..sort((a, b) => frame.lift(a).compareTo(frame.lift(b)));

    for (final index in barOrder) {
      final bar = scene.bars[index];
      final appear = frame.appear(bar.level * 4);
      if (appear <= 0.001) continue;
      final lift = frame.lift(index);
      final center = bar.rect.center;
      final tall = math.max(0.1, 1.0 - (1.0 - frame.smallest) * 1.7);
      final wide = frame.smallest < 0.5 ? 0.7 + 0.3 * appear : 1.0;
      final stretch = _scaleXYAbout(
        center,
        wide * (1.0 + 0.012 * lift),
        (tall + (1.0 - tall) * appear) * (1.0 + 0.07 * lift),
      );
      final radius = math.min(
        9.0,
        math.min(bar.rect.width / 2.4, bar.rect.height / 2.4),
      );
      final basePath = Path()
        ..addRRect(RRect.fromRectAndRadius(bar.rect, Radius.circular(radius)));
      final shape = basePath.transform(stretch);
      final layerAlpha = _unit(appear * frame.solidity) * presence(index);

      if (bar.item.kind == MapItemKind.free) {
        _drawFree(canvas, basePath, bar.dots, stretch, theme, layerAlpha);
        _drawLabel(canvas, bar.label, center, theme.text.color, layerAlpha);
      } else {
        if (lift > 0.05 && bar.item.kind != MapItemKind.hidden && bar.item.kind != MapItemKind.unscanned) {
          final shadowPaint = Paint()
            ..color = const Color(0xFF000000).withValues(
              alpha: (theme.isDark ? 0.26 : 0.12) * _unit(lift) * layerAlpha,
            )
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
          canvas.drawPath(shape.shift(const Offset(0, 3)), shadowPaint);
        }
        final fill = theme.fill(bar.tone);
        fillPaint.color = fill
            .lighter(0.03 * _unit(lift))
            .color
            .withValues(alpha: layerAlpha);
        canvas.drawPath(shape, fillPaint);

        if (lift > 0.02) {
          strokePaint
            ..strokeWidth = 1.5
            ..color = theme.accent.color.withValues(
              alpha: _unit(lift) * layerAlpha,
            );
          canvas.drawPath(shape, strokePaint);
        }
        if (bar.item.kind == MapItemKind.hidden ||
            bar.item.kind == MapItemKind.unscanned) {
          strokePaint
            ..strokeWidth = 1.0
            ..color = theme.line.color.withValues(alpha: 0.28 * layerAlpha);
          _drawDashedPath(canvas, shape, strokePaint);
        }
        final ink =
            (bar.item.kind == MapItemKind.hidden ||
                bar.item.kind == MapItemKind.unscanned)
            ? theme.secondaryText
            : theme.ink(fill);
        _drawLabel(canvas, bar.label, center, ink.color, layerAlpha);
      }
    }
  }
}
