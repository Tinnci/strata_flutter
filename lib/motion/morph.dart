import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../model/file_tree.dart';
import '../render/map_renderer.dart';
import '../scene/map_scene.dart';
import '../theme/theme.dart';

class _MarkInfo {
  const _MarkInfo({
    required this.key,
    required this.parent,
    required this.rect,
  });

  final String key;
  final int? parent;
  final Rect rect;
}

class MorphPose {
  const MorphPose({
    required this.outerPlace,
    required this.innerPlace,
    required this.outerAlpha,
    required this.innerAlpha,
    required this.outerOwn,
    required this.innerOwn,
  });

  final List<Float64List> outerPlace;
  final List<Float64List> innerPlace;
  final List<double> outerAlpha;
  final List<double> innerAlpha;
  final List<bool> outerOwn;
  final List<bool> innerOwn;
}

double _smooth(double from, double to, double x) {
  final t = ((x - from) / (to - from)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

Rect _lerpRect(Rect a, Rect b, double t) {
  return Rect.fromLTRB(
    a.left + (b.left - a.left) * t,
    a.top + (b.top - a.top) * t,
    a.right + (b.right - a.right) * t,
    a.bottom + (b.bottom - a.bottom) * t,
  );
}

Float64List _identity() {
  return Float64List.fromList([
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  ]);
}

Float64List _translation(double tx, double ty) {
  return Float64List.fromList([
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    tx, ty, 0, 1,
  ]);
}

Float64List _scale(double sx, double sy) {
  return Float64List.fromList([
    sx, 0, 0, 0,
    0, sy, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  ]);
}

Float64List _scaleAbout(Offset point, double factor) {
  return Float64List.fromList([
    factor, 0, 0, 0,
    0, factor, 0, 0,
    0, 0, 1, 0,
    point.dx * (1.0 - factor), point.dy * (1.0 - factor), 0, 1,
  ]);
}

/// Applies `first` then `second` (equivalent to Swift `first.concatenating(second)`).
Float64List _then(Float64List first, Float64List second) {
  final out = Float64List(16);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += second[row + k * 4] * first[k + col * 4];
      }
      out[row + col * 4] = sum;
    }
  }
  return out;
}

/// Inverts an affine 2D matrix stored in 4x4 column-major layout.
Float64List _invert2D(Float64List m) {
  final a = m[0], b = m[1], c = m[4], d = m[5], tx = m[12], ty = m[13];
  final det = a * d - b * c;
  if (det.abs() < 1e-12) return _identity();
  final inv = 1.0 / det;
  final na = d * inv;
  final nb = -b * inv;
  final nc = -c * inv;
  final nd = a * inv;
  final ntx = -(na * tx + nc * ty);
  final nty = -(nb * tx + nd * ty);
  return Float64List.fromList([
    na, nb, 0, 0,
    nc, nd, 0, 0,
    0, 0, 1, 0,
    ntx, nty, 0, 1,
  ]);
}

Offset _applyPoint(Offset p, Float64List m) {
  return Offset(m[0] * p.dx + m[4] * p.dy + m[12],
      m[1] * p.dx + m[5] * p.dy + m[13]);
}

Rect _applyRect(Rect r, Float64List m) {
  final p1 = _applyPoint(r.topLeft, m);
  final p2 = _applyPoint(r.topRight, m);
  final p3 = _applyPoint(r.bottomLeft, m);
  final p4 = _applyPoint(r.bottomRight, m);
  final minX = math.min(math.min(p1.dx, p2.dx), math.min(p3.dx, p4.dx));
  final maxX = math.max(math.max(p1.dx, p2.dx), math.max(p3.dx, p4.dx));
  final minY = math.min(math.min(p1.dy, p2.dy), math.min(p3.dy, p4.dy));
  final maxY = math.max(math.max(p1.dy, p2.dy), math.max(p3.dy, p4.dy));
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

List<_MarkInfo> _extractMarks(MapScene scene) {
  switch (scene.mode) {
    case MapMode.bubbles:
      return scene.bubbles!.cells
          .map((c) => _MarkInfo(
                key: c.key,
                parent: c.parent,
                rect: c.outline.getBounds(),
              ))
          .toList(growable: false);
    case MapMode.flow:
      return scene.flow!.bars
          .map((b) => _MarkInfo(
                key: b.key,
                parent: b.parent,
                rect: b.rect,
              ))
          .toList(growable: false);
  }
}

/// One picture turning into another: camera zoom into an anchor folder while
/// matched marks travel from their old boxes to their new boxes.
class Morph {
  Morph({
    required this.outer,
    required this.inner,
    required this.leavesOuter,
    required this.anchor,
    required this.bounds,
  })  : _outerMarks = _extractMarks(outer),
        _innerMarks = _extractMarks(inner) {
    bool isInside(int index) {
      if (anchor == null) return true;
      var current = _outerMarks[index].parent;
      while (current != null) {
        if (current == anchor) return true;
        current = _outerMarks[current].parent;
      }
      return false;
    }

    final byKey = <String, int>{};
    for (var i = 0; i < _outerMarks.length; i++) {
      final k = _outerMarks[i].key;
      if (!byKey.containsKey(k) && isInside(i)) {
        byKey[k] = i;
      }
    }

    for (var i = 0; i < _innerMarks.length; i++) {
      final match = byKey[_innerMarks[i].key];
      if (match != null && !_outerMatch.containsKey(match)) {
        _outerMatch[match] = i;
        _innerMatch[i] = match;
      }
    }

    var step = anchor;
    while (step != null) {
      _around.add(step);
      step = _outerMarks[step].parent;
    }

    if (outer.mode == MapMode.flow && anchor != null) {
      final topRows = _innerMarks
          .where((m) => m.parent == null)
          .map((m) => m.rect.top);
      final top = topRows.isEmpty ? 0.0 : topRows.reduce(math.min);
      final belowRows = _outerMarks
          .where((m) => m.parent == anchor)
          .map((m) => m.rect.top);
      final below = belowRows.isEmpty
          ? _outerMarks[anchor!].rect.bottom + FlowScene.between
          : belowRows.reduce(math.min);
      _rowShift = top - below;
    } else {
      _rowShift = 0.0;
    }
  }

  final MapScene outer;
  final MapScene inner;
  final bool leavesOuter;
  final int? anchor;
  final Size bounds;

  final List<_MarkInfo> _outerMarks;
  final List<_MarkInfo> _innerMarks;
  final Map<int, int> _outerMatch = {};
  final Map<int, int> _innerMatch = {};
  final Set<int> _around = {};
  late final double _rowShift;

  int get matchCount => _innerMatch.length;

  double get duration => anchor == null ? 0.50 : 0.62;

  Float64List _camera(double progress) {
    if (anchor == null) return _identity();
    final q = progress * (2.0 - progress);
    final frame = _outerMarks[anchor!].rect;
    final full = Offset.zero & bounds;
    switch (outer.mode) {
      case MapMode.bubbles:
        final scaleFactor = math.pow(
          math.min(
            full.width / math.max(frame.width, 1.0),
            full.height / math.max(frame.height, 1.0),
          ),
          q,
        ).toDouble();
        final center = frame.center;
        final fullCenter = full.center;
        return _then(
          _then(
            _translation(-center.dx, -center.dy),
            _scale(scaleFactor, scaleFactor),
          ),
          _translation(
            center.dx + (fullCenter.dx - center.dx) * q,
            center.dy + (fullCenter.dy - center.dy) * q,
          ),
        );
      case MapMode.flow:
        final scaleFactor =
            math.pow(full.width / math.max(frame.width, 1.0), q).toDouble();
        final center = frame.center;
        final fullCenter = full.center;
        return _then(
          _then(
            _translation(-center.dx, 0.0),
            _scale(scaleFactor, 1.0),
          ),
          _translation(
            center.dx + (fullCenter.dx - center.dx) * q,
            _rowShift * q,
          ),
        );
    }
  }

  Float64List _fit(Rect source, Rect target) {
    switch (outer.mode) {
      case MapMode.bubbles:
        final scaleFactor = math.sqrt(
          (target.width * target.height) /
              math.max(source.width * source.height, 1.0),
        );
        final sc = source.center;
        final tc = target.center;
        return _then(
          _then(
            _translation(-sc.dx, -sc.dy),
            _scale(scaleFactor, scaleFactor),
          ),
          _translation(tc.dx, tc.dy),
        );
      case MapMode.flow:
        final sx = target.width / math.max(source.width, 0.5);
        final sy = target.height / math.max(source.height, 0.5);
        return Float64List.fromList([
          sx, 0, 0, 0,
          0, sy, 0, 0,
          0, 0, 1, 0,
          target.left - source.left * sx,
          target.top - source.top * sy,
          0,
          1,
        ]);
    }
  }

  Float64List _push(int index, Float64List view, double q) {
    if (anchor == null || _around.contains(index)) return _identity();
    final from = _outerMarks[anchor!].rect;
    final mark = _outerMarks[index].rect;
    final reach =
        math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height) *
            0.5 *
            q *
            q;
    switch (outer.mode) {
      case MapMode.bubbles:
        final a = _applyPoint(from.center, view);
        final b = _applyPoint(mark.center, view);
        final dx = b.dx - a.dx;
        final dy = b.dy - a.dy;
        final length = math.max(math.sqrt(dx * dx + dy * dy), 1.0);
        return _translation(dx / length * reach, dy / length * reach);
      case MapMode.flow:
        return _translation(mark.center.dx < from.center.dx ? -reach : reach, 0);
    }
  }

  MorphPose pose(double q) {
    final view = _camera(q);
    final back = _invert2D(_camera(1.0));
    final innerView = _then(back, view);
    final handOver = _smooth(0.05, 0.55, q);

    final outerPlace = <Float64List>[];
    final innerPlace = <Float64List>[];
    final outerAlpha = <double>[];
    final innerAlpha = <double>[];
    final outerOwn = <bool>[];
    final innerOwn = <bool>[];
    final boxes = <int, Rect>{};

    for (var i = 0; i < _outerMarks.length; i++) {
      final mark = _outerMarks[i];
      final match = _outerMatch[i];
      if (match != null) {
        final box = _applyRect(
          _lerpRect(mark.rect, _applyRect(_innerMarks[match].rect, back), q),
          view,
        );
        boxes[match] = box;
        outerPlace.add(_fit(mark.rect, box));
        outerAlpha.add(math.min(1.0, 2.0 * (1.0 - handOver)));
        outerOwn.add(true);
      } else if (mark.parent != null) {
        final p = mark.parent!;
        outerPlace.add(outerPlace[p]);
        outerAlpha.add(outerAlpha[p]);
        outerOwn.add(false);
      } else {
        outerPlace.add(_then(view, _push(i, view, q)));
        outerAlpha.add(1.0 - _smooth(0.05, 0.55, q));
        outerOwn.add(true);
      }
    }

    for (var i = 0; i < _innerMarks.length; i++) {
      final mark = _innerMarks[i];
      final box = boxes[i];
      if (box != null) {
        innerPlace.add(_fit(mark.rect, box));
        innerAlpha.add(handOver);
        innerOwn.add(true);
      } else if (mark.parent != null) {
        final p = mark.parent!;
        innerPlace.add(innerPlace[p]);
        innerAlpha.add(innerAlpha[p]);
        innerOwn.add(false);
      } else {
        innerPlace.add(_then(_scaleAbout(mark.rect.center, 0.7 + 0.3 * q), innerView));
        innerAlpha.add(_smooth(0.35, 0.9, q));
        innerOwn.add(true);
      }
    }

    return MorphPose(
      outerPlace: outerPlace,
      innerPlace: innerPlace,
      outerAlpha: outerAlpha,
      innerAlpha: innerAlpha,
      outerOwn: outerOwn,
      innerOwn: innerOwn,
    );
  }

  void draw({
    required double progress,
    required StrataTheme theme,
    required Map<int, double> lifts,
    required int? flowFocus,
    required Canvas canvas,
  }) {
    final q = leavesOuter ? progress : 1.0 - progress;
    final currentPose = pose(q);
    final settle = 1.0 - _smooth(0.0, 0.35, progress);
    double leftLift(int id) => (lifts[id] ?? 0.0) * settle;
    double still(int _) => 0.0;
    final outerLabels = 1.0 - _smooth(0.1, 0.45, q);
    final innerLabels = _smooth(0.5, 0.92, q);

    if (outer.mode == MapMode.bubbles && inner.mode == MapMode.bubbles) {
      _MorphRenderer.bubbles(
        outer.bubbles!,
        place: currentPose.outerPlace,
        alpha: currentPose.outerAlpha,
        own: currentPose.outerOwn,
        lift: leavesOuter ? leftLift : still,
        labels: outerLabels,
        theme: theme,
        canvas: canvas,
      );
      _MorphRenderer.bubbles(
        inner.bubbles!,
        place: currentPose.innerPlace,
        alpha: currentPose.innerAlpha,
        own: currentPose.innerOwn,
        lift: leavesOuter ? still : leftLift,
        labels: innerLabels,
        theme: theme,
        canvas: canvas,
      );
    } else if (outer.mode == MapMode.flow && inner.mode == MapMode.flow) {
      _MorphRenderer.flow(
        outer.flow!,
        place: currentPose.outerPlace,
        alpha: currentPose.outerAlpha,
        lift: leavesOuter ? leftLift : still,
        focus: leavesOuter ? flowFocus : null,
        labels: outerLabels,
        theme: theme,
        canvas: canvas,
      );
      _MorphRenderer.flow(
        inner.flow!,
        place: currentPose.innerPlace,
        alpha: currentPose.innerAlpha,
        lift: leavesOuter ? still : leftLift,
        focus: leavesOuter ? null : flowFocus,
        labels: innerLabels,
        theme: theme,
        canvas: canvas,
      );
    }
  }
}

abstract final class _MorphRenderer {
  static double _unit(double v) => v.clamp(0.0, 1.0);

  static void bubbles(
    BubbleScene scene, {
    required List<Float64List> place,
    required List<double> alpha,
    required List<bool> own,
    required double Function(int) lift,
    required double labels,
    required StrataTheme theme,
    required Canvas canvas,
  }) {
    final cells = scene.cells;
    if (cells.isEmpty) return;

    final rests = List<Float64List>.filled(cells.length, _identity());
    final transforms = List<Float64List>.filled(cells.length, _identity());
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (cell.parent != null) {
        final p = cell.parent!;
        final factor = cell.level == 2
            ? 1.0 - 0.035 * _unit(lift(p)) + 0.055 * lift(i)
            : 1.0 - 0.07 * _unit(lift(p));
        rests[i] = _then(_scaleAbout(cell.center, factor), rests[p]);
      } else {
        rests[i] = _scaleAbout(cell.center, 1.0 + 0.02 * lift(i));
      }
      transforms[i] = _then(rests[i], place[i]);
    }

    final group = List<int>.filled(cells.length, 0);
    final members = <int, List<int>>{};
    for (var i = 0; i < cells.length; i++) {
      group[i] = own[i] ? i : group[cells[i].parent ?? i];
      members.putIfAbsent(group[i], () => []).add(i);
    }

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final strokePaint = Paint()..style = PaintingStyle.stroke;

    void drawCell(int index, Canvas target, double groupAlpha) {
      final cell = cells[index];
      final transform = transforms[index];
      if (cell.item.kind == MapItemKind.free) {
        MapRenderer.drawFreePath(
          target,
          cell.outline,
          cell.dots,
          transform,
          theme,
          groupAlpha,
        );
        return;
      }
      final shape = cell.outline.transform(transform);
      final raised = _unit(lift(index));
      if (cell.children.isEmpty) {
        fillPaint.color = theme
            .fill(cell.tone)
            .lighter(0.03 * raised)
            .color
            .withValues(alpha: groupAlpha);
        target.drawPath(shape, fillPaint);
        if (cell.item.kind == MapItemKind.hidden ||
            cell.item.kind == MapItemKind.unscanned) {
          strokePaint
            ..strokeWidth = 1.0
            ..color = theme.line.color.withValues(alpha: 0.28 * groupAlpha);
          MapRenderer.drawDashed(target, shape, strokePaint);
          return;
        }
      } else {
        fillPaint.color =
            theme.wall(cell.tone).color.withValues(alpha: groupAlpha);
        target.drawPath(shape, fillPaint);
      }
      if (raised > 0.02 && (cell.children.isEmpty || cell.level > 1)) {
        strokePaint
          ..strokeWidth = 1.5
          ..color = theme.accent.color.withValues(alpha: raised * groupAlpha);
        target.drawPath(shape, strokePaint);
      }
    }

    for (var i = 0; i < cells.length; i++) {
      if (!own[i]) continue;
      final opacity = alpha[i];
      final marks = members[i];
      if (opacity <= 0.003 || marks == null) continue;
      if (marks.length == 1 || opacity > 0.997) {
        for (final mark in marks) {
          drawCell(mark, canvas, opacity);
        }
      } else {
        final bounds = _applyRect(cells[i].outline.getBounds(), transforms[i])
            .inflate(12);
        canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
        for (final mark in marks) {
          drawCell(mark, canvas, 1.0);
        }
        canvas.restore();
      }
    }

    if (labels <= 0.01) return;
    for (final index in scene.top) {
      final cell = cells[index];
      final opacity = alpha[group[index]] * labels;
      if (opacity <= 0.01) continue;
      final at = _applyPoint(cell.center, transforms[index]);
      if (cell.item.kind == MapItemKind.free) {
        MapRenderer.drawTextLabel(
            canvas, cell.label, at, theme.text.color, opacity);
        continue;
      }
      if (cell.item.kind == MapItemKind.hidden ||
          cell.item.kind == MapItemKind.unscanned) {
        MapRenderer.drawTextLabel(
            canvas, cell.label, at, theme.secondaryText.color, opacity);
        continue;
      }
      final raised = _unit(lift(index));
      final opensUp = cell.children.any((c) => cells[c].label != null);
      final ink = theme.ink(
        cell.children.isEmpty
            ? theme.fill(cell.tone)
            : theme.fill(cells[cell.children[0]].tone),
      );
      MapRenderer.drawTextLabel(
        canvas,
        cell.label,
        at,
        ink.color,
        opacity * (opensUp ? 1.0 - raised : 1.0),
      );
    }
  }

  static void flow(
    FlowScene scene, {
    required List<Float64List> place,
    required List<double> alpha,
    required double Function(int) lift,
    required int? focus,
    required double labels,
    required StrataTheme theme,
    required Canvas canvas,
  }) {
    final strength = focus != null ? _unit(lift(focus)) : 0.0;
    final family = focus != null ? scene.familyOf(focus) : const <int>{};
    double presence(int bar) =>
        family.isEmpty || family.contains(bar) ? 1.0 : 1.0 - 0.55 * strength;

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final strokePaint = Paint()..style = PaintingStyle.stroke;

    for (final ribbon in scene.ribbons) {
      final ribbonAlpha = math.min(alpha[ribbon.parent], alpha[ribbon.child]);
      if (ribbonAlpha <= 0.01) continue;
      final tone = scene.bars[ribbon.child].tone;
      final color = (tone.role == ToneRole.free || tone.role == ToneRole.hidden)
          ? theme.neutral
          : theme.fill(tone);
      final related =
          family.contains(ribbon.parent) && family.contains(ribbon.child);
      final opacity = (0.4 + (related ? 0.3 * strength : 0.0)) *
          math.min(presence(ribbon.parent), presence(ribbon.child)) *
          ribbonAlpha;
      fillPaint.color = color.color.withValues(alpha: opacity);
      canvas.drawPath(ribbon.path.transform(place[ribbon.child]), fillPaint);
    }

    for (var i = 0; i < scene.bars.length; i++) {
      final opacity = alpha[i];
      if (opacity <= 0.003) continue;
      final bar = scene.bars[i];
      final raised = _unit(lift(i));
      final center = bar.rect.center;
      final localLift = Float64List.fromList([
        1.0 + 0.012 * lift(i), 0, 0, 0,
        0, 1.0 + 0.07 * lift(i), 0, 0,
        0, 0, 1, 0,
        center.dx * (-0.012 * lift(i)),
        center.dy * (-0.07 * lift(i)),
        0,
        1,
      ]);
      final transform = _then(localLift, place[i]);
      final radius = math.min(
        9.0,
        math.min(bar.rect.width / 2.4, bar.rect.height / 2.4),
      );
      final basePath = Path()
        ..addRRect(RRect.fromRectAndRadius(bar.rect, Radius.circular(radius)));
      final shape = basePath.transform(transform);
      final layerAlpha = opacity * presence(i);

      if (bar.item.kind == MapItemKind.free) {
        MapRenderer.drawFreePath(
          canvas,
          basePath,
          bar.dots,
          transform,
          theme,
          layerAlpha,
        );
        if (labels > 0.01) {
          MapRenderer.drawTextLabel(
            canvas,
            bar.label,
            _applyPoint(center, transform),
            theme.text.color,
            layerAlpha * labels,
          );
        }
      } else {
        final fill = theme.fill(bar.tone);
        fillPaint.color =
            fill.lighter(0.03 * raised).color.withValues(alpha: layerAlpha);
        canvas.drawPath(shape, fillPaint);
        if (raised > 0.02) {
          strokePaint
            ..strokeWidth = 1.5
            ..color =
                theme.accent.color.withValues(alpha: raised * layerAlpha);
          canvas.drawPath(shape, strokePaint);
        }
        if (labels > 0.01) {
          final ink = (bar.item.kind == MapItemKind.hidden ||
                  bar.item.kind == MapItemKind.unscanned)
              ? theme.secondaryText
              : theme.ink(fill);
          MapRenderer.drawTextLabel(
            canvas,
            bar.label,
            _applyPoint(center, transform),
            ink.color,
            layerAlpha * labels,
          );
        }
      }
    }
  }
}
