import 'dart:math' as math;
import 'dart:ui';

import '../layout/bubble_layout.dart';
import '../layout/flow_layout.dart';
import '../layout/geometry.dart';
import '../model/file_tree.dart';
import '../theme/theme.dart';

enum MapMode { bubbles, flow }

class MarkLabel {
  const MarkLabel({required this.name, this.size, required this.fontSize});

  final String name;
  final String? size;
  final double fontSize;
}

class BubbleCell {
  BubbleCell({
    required this.item,
    required this.key,
    required this.level,
    required this.parent,
    required this.raw,
    required this.outline,
    required this.center,
    required this.tone,
    this.dots,
    this.label,
  });

  final MapItem item;
  final String key;
  final int level;
  final int? parent;
  final List<int> children = [];
  final Polygon raw;
  final Path outline;
  final Path? dots;
  final Offset center;
  final Tone tone;
  final MarkLabel? label;
}

class BubbleScene {
  BubbleScene({required this.cells, required this.top, required this.size});

  final List<BubbleCell> cells;
  final List<int> top;
  final Size size;

  List<int> hit(Offset point) {
    final first = top.cast<int?>().firstWhere(
      (idx) => Geometry.contains(cells[idx!].raw, point),
      orElse: () => null,
    );
    if (first == null) return const [];
    final chain = [first];
    while (true) {
      final current = cells[chain.last];
      final next = current.children.cast<int?>().firstWhere(
        (idx) => Geometry.contains(cells[idx!].raw, point),
        orElse: () => null,
      );
      if (next == null) break;
      chain.add(next);
    }
    return chain;
  }

  int? deepestCell(Set<int> ids) {
    for (final idx in top) {
      if (!ids.contains(cells[idx].item.id)) continue;
      var current = idx;
      while (true) {
        final next = cells[current].children.cast<int?>().firstWhere(
          (c) => ids.contains(cells[c!].item.id),
          orElse: () => null,
        );
        if (next == null) break;
        current = next;
      }
      return current;
    }
    return null;
  }

  static const _styles = [
    (gap: 11.0, wall: 4.5, corner: 30.0),
    (gap: 4.6, wall: 2.2, corner: 13.0),
    (gap: 1.8, wall: 0.0, corner: 5.0),
  ];

  static const _innerShifts = [
    [0.0, -0.045, 0.040, -0.022, 0.060, -0.062, 0.024, -0.036],
    [0.0, -0.016, 0.016, -0.008, 0.024, -0.024],
  ];

  static BubbleScene build({
    required MapCatalog catalog,
    required int focus,
    required Size size,
  }) {
    final cells = <BubbleCell>[];
    final top = <int>[];
    if (size.width <= 80 || size.height <= 80) {
      return BubbleScene(cells: cells, top: top, size: size);
    }

    var standIn = -100;

    Path toPath(Polygon poly) {
      final path = Path();
      if (poly.isEmpty) return path;
      path.moveTo(poly.first.dx, poly.first.dy);
      for (var i = 1; i < poly.length; i++) {
        path.lineTo(poly[i].dx, poly[i].dy);
      }
      path.close();
      return path;
    }

    Path? dotField(Polygon poly) {
      if (poly.length < 3) return null;
      final box = Geometry.bounds(poly);
      const step = 13.0;
      final path = Path();
      var row = 0;
      for (var y = box.top + step * 0.5; y < box.bottom; y += step) {
        final shift = row.isOdd ? step * 0.5 : 0.0;
        for (var x = box.left + step * 0.5 + shift; x < box.right; x += step) {
          final p = Offset(x, y);
          if (Geometry.contains(poly, p)) {
            path.addOval(Rect.fromCircle(center: p, radius: 1.15));
          }
        }
        row++;
      }
      return path;
    }

    MarkLabel? buildLabel(
      MapItem item,
      Polygon shape,
      Offset center,
      int level,
    ) {
      final area = Geometry.area(shape);
      if (area < (level == 1 ? 1800 : (level == 2 ? 1100 : 750))) return null;
      final span = Geometry.horizontalSpan(shape, center.dy);
      final vSpan = Geometry.verticalSpan(shape, center.dx);
      if (span == null || vSpan == null) return null;
      final w = span.$2 - span.$1;
      final h = vSpan.$2 - vSpan.$1;
      if (w < 46 || h < 24) return null;

      final fontSize = switch (level) {
        1 => (math.sqrt(area) / 14.0).clamp(11.0, 15.5),
        2 => (math.sqrt(area) / 13.5).clamp(10.0, 12.5),
        _ => 10.0,
      };
      final showSize = h > fontSize * 3.1 && w > 64;
      final maxChars = math.max(4, (w / (fontSize * 0.68)).floor());
      final title = item.title.length > maxChars
          ? '${item.title.substring(0, maxChars - 1)}…'
          : item.title;

      return MarkLabel(
        name: title,
        size: showSize ? Format.size(item.size) : null,
        fontSize: fontSize,
      );
    }

    List<MapItem> condensed(
      List<MapItem> source, {
      required double minimumShare,
      required int limit,
    }) {
      if (source.isEmpty) return const [];
      final total = source.fold<int>(0, (s, e) => s + e.size);
      if (total <= 0) return const [];

      final kept = <MapItem>[];
      var smallBytes = 0;
      var smallCount = 0;
      for (final item in source) {
        if (item.isOutsideScan ||
            (kept.length < limit && item.size / total >= minimumShare)) {
          kept.add(item);
        } else {
          smallBytes += item.size;
          smallCount += item.kind == MapItemKind.small ? item.count : 1;
        }
      }
      if (smallBytes > 0) {
        kept.add(
          MapItem(
            id: standIn--,
            name: '',
            size: smallBytes,
            kind: MapItemKind.small,
            count: smallCount,
          ),
        );
      }
      return kept;
    }

    int? addCell(
      MapItem item, {
      required String key,
      required int level,
      required int? parent,
      required Polygon raw,
      required Tone tone,
    }) {
      final style = _styles[level - 1];
      final shape = Geometry.soften(
        Geometry.inset(raw, style.gap / 2.0),
        cap: style.corner,
      );
      if (shape.length < 3 || Geometry.area(shape) <= 6.0) return null;
      final center = Geometry.centroid(shape);
      final cell = BubbleCell(
        item: item,
        key: key,
        level: level,
        parent: parent,
        raw: raw,
        outline: toPath(shape),
        dots: item.kind == MapItemKind.free
            ? dotField(Geometry.inset(shape, 9.0))
            : null,
        center: center,
        tone: tone,
        label: buildLabel(item, shape, center, level),
      );
      cells.add(cell);
      final idx = cells.length - 1;
      if (parent != null) {
        cells[parent].children.add(idx);
      }
      return idx;
    }

    void subdivide(int parentIdx, int level) {
      final parent = cells[parentIdx];
      final style = _styles[level - 2];
      final room = Geometry.soften(
        Geometry.inset(parent.raw, style.gap / 2.0 + style.wall),
        cap: style.corner * 0.8,
      );
      if (room.length < 3 ||
          Geometry.area(room) <= (level == 2 ? 7000.0 : 4200.0)) {
        return;
      }
      final kids = condensed(
        catalog.childrenOfItem(parent.item),
        minimumShare: level == 2 ? 0.02 : 0.045,
        limit: level == 2 ? 16 : 9,
      );
      if (kids.length <= 1) return;

      final shifts = _innerShifts[level - 2];
      final polygons = BubbleLayout.ordered(
        sizes: kids.map((k) => k.size.toDouble()).toList(growable: false),
        region: room,
      );
      for (var i = 0; i < kids.length; i++) {
        final raw = polygons[i];
        if (raw.length < 3) continue;
        final kid = kids[i];
        final tone = kid.kind == MapItemKind.small
            ? parent.tone.shifted(lightness: -0.05, chroma: 0.8)
            : parent.tone.shifted(
                lightness: shifts[i % shifts.length],
                hue: level == 2 ? ((i % 3) - 1) * 4.0 : 0.0,
              );
        final cellIdx = addCell(
          kid,
          key: catalog.keyOf(kid, parentKey: parent.key),
          level: level,
          parent: parentIdx,
          raw: raw,
          tone: tone,
        );
        if (cellIdx != null && level == 2 && kid.kind == MapItemKind.folder) {
          subdivide(cellIdx, 3);
        }
      }
    }

    final rootItems = condensed(
      catalog.itemsIn(focus),
      minimumShare: 0.008,
      limit: 20,
    );
    if (rootItems.isEmpty) {
      return BubbleScene(cells: cells, top: top, size: size);
    }

    final region = Geometry.roundedRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      radius: 26,
    );
    final rootPolys = BubbleLayout.ordered(
      sizes: rootItems.map((e) => e.size.toDouble()).toList(growable: false),
      region: region,
    );

    var familySlot = 0;
    for (var i = 0; i < rootItems.length; i++) {
      final raw = rootPolys[i];
      if (raw.length < 3) continue;
      final item = rootItems[i];
      final Tone tone;
      switch (item.kind) {
        case MapItemKind.free:
          tone = const Tone.free();
        case MapItemKind.hidden:
        case MapItemKind.unscanned:
          tone = const Tone.hidden();
        case MapItemKind.small:
          tone = const Tone.neutral();
        case MapItemKind.folder:
        case MapItemKind.file:
          tone = Tone.family(familySlot++);
      }
      final idx = addCell(
        item,
        key: catalog.keyOf(item),
        level: 1,
        parent: null,
        raw: raw,
        tone: tone,
      );
      if (idx != null) {
        top.add(idx);
        if (item.kind == MapItemKind.folder) {
          subdivide(idx, 2);
        }
      }
    }

    return BubbleScene(cells: cells, top: top, size: size);
  }
}

class FlowBarVisual {
  const FlowBarVisual({
    required this.item,
    required this.key,
    required this.level,
    required this.parent,
    required this.rect,
    required this.tone,
    this.dots,
    this.label,
  });

  final MapItem item;
  final String key;
  final int level;
  final int? parent;
  final Rect rect;
  final Tone tone;
  final Path? dots;
  final MarkLabel? label;
}

class FlowRibbonVisual {
  const FlowRibbonVisual({
    required this.parent,
    required this.child,
    required this.path,
  });

  final int parent;
  final int child;
  final Path path;
}

class FlowScene {
  FlowScene({required this.bars, required this.ribbons, required this.size});

  static const int levels = 4;
  static const double between = 54.0;
  static const double spacing = 4.0;
  static const List<double> _shifts = [
    0.0,
    -0.045,
    0.040,
    -0.022,
    0.060,
    -0.062,
    0.024,
    -0.036,
  ];

  final List<FlowBarVisual> bars;
  final List<FlowRibbonVisual> ribbons;
  final Size size;

  int? hit(Offset point) {
    for (var i = bars.length - 1; i >= 0; i--) {
      if (bars[i].rect.contains(point)) return i;
    }
    return null;
  }

  int? deepestBar(Set<int> ids) {
    for (var i = bars.length - 1; i >= 0; i--) {
      if (ids.contains(bars[i].item.id)) return i;
    }
    return null;
  }

  Set<int> familyOf(int barIndex) {
    final result = <int>{barIndex};
    var current = bars[barIndex].parent;
    while (current != null) {
      result.add(current);
      current = bars[current].parent;
    }
    final queue = <int>[barIndex];
    while (queue.isNotEmpty) {
      final p = queue.removeLast();
      for (var i = 0; i < bars.length; i++) {
        if (bars[i].parent == p && result.add(i)) {
          queue.add(i);
        }
      }
    }
    return result;
  }

  static FlowScene build({
    required MapCatalog catalog,
    required int focus,
    required Size size,
  }) {
    if (size.width <= 120 || size.height <= 120) {
      return FlowScene(bars: const [], ribbons: const [], size: size);
    }

    final rowHeight = math.min(
      108.0,
      math.max(40.0, (size.height - between * (levels - 1)) / levels),
    );
    final itemsByTempId = <int, MapItem>{};
    final keysByTempId = <int, String>{};
    final tonesByTempId = <int, Tone>{};
    var nextId = 1;
    var standIn = -100;

    List<MapItem> condensed(
      List<MapItem> source, {
      required double minimumShare,
      required int limit,
    }) {
      if (source.isEmpty) return const [];
      final total = source.fold<int>(0, (s, e) => s + e.size);
      if (total <= 0) return const [];

      final kept = <MapItem>[];
      var smallBytes = 0;
      var smallCount = 0;
      for (final item in source) {
        if (item.isOutsideScan ||
            (kept.length < limit && item.size / total >= minimumShare)) {
          kept.add(item);
        } else {
          smallBytes += item.size;
          smallCount += item.kind == MapItemKind.small ? item.count : 1;
        }
      }
      if (smallBytes > 0) {
        kept.add(
          MapItem(
            id: standIn--,
            name: '',
            size: smallBytes,
            kind: MapItemKind.small,
            count: smallCount,
          ),
        );
      }
      return kept;
    }

    final keptTop = condensed(
      catalog.itemsIn(focus),
      minimumShare: 10.0 / size.width,
      limit: 16,
    );
    if (keptTop.isEmpty) {
      return FlowScene(bars: const [], ribbons: const [], size: size);
    }

    final total = math.max(
      keptTop.fold<double>(0.0, (s, e) => s + e.size.toDouble()),
      1.0,
    );
    final roughScale = size.width * 0.85 / total;

    FlowInput buildInput(
      MapItem item,
      int depth,
      String parentKey,
      Tone tone,
    ) {
      final tempId = nextId++;
      final key = catalog.keyOf(item, parentKey: parentKey);
      itemsByTempId[tempId] = item;
      keysByTempId[tempId] = key;
      tonesByTempId[tempId] = tone;

      final estWidth = item.size.toDouble() * roughScale;
      if (depth >= levels ||
          item.kind != MapItemKind.folder ||
          estWidth < 22.0) {
        return FlowInput(id: tempId, size: item.size.toDouble());
      }

      final kids = condensed(
        catalog.childrenOfItem(item),
        minimumShare: math.min(1.0, 9.0 / estWidth),
        limit: 9,
      );
      if (kids.length <= 1) {
        return FlowInput(id: tempId, size: item.size.toDouble());
      }

      final children = <FlowInput>[];
      for (var i = 0; i < kids.length; i++) {
        final kid = kids[i];
        final childTone = kid.kind == MapItemKind.small
            ? tone.shifted(lightness: -0.05, chroma: 0.8)
            : tone.shifted(
                lightness:
                    _shifts[i % _shifts.length] * (depth == 1 ? 1.0 : 0.6),
              );
        children.add(buildInput(kid, depth + 1, key, childTone));
      }
      return FlowInput(
        id: tempId,
        size: item.size.toDouble(),
        children: children,
      );
    }

    var familySlot = 0;
    final roots = <FlowInput>[];
    for (final item in keptTop) {
      final Tone tone;
      switch (item.kind) {
        case MapItemKind.free:
          tone = const Tone.free();
        case MapItemKind.hidden:
        case MapItemKind.unscanned:
          tone = const Tone.hidden();
        case MapItemKind.small:
          tone = const Tone.neutral();
        case MapItemKind.folder:
        case MapItemKind.file:
          tone = Tone.family(familySlot++);
      }
      roots.add(buildInput(item, 1, '', tone));
    }

    final layout = FlowLayout.layout(
      roots: roots,
      width: size.width,
      levels: levels,
      rowHeight: rowHeight,
      between: between,
      spacing: spacing,
    );

    final yOffset = math.max(0.0, (size.height - layout.size.height) * 0.18);
    final tempToBarIndex = <int, int>{};
    for (var i = 0; i < layout.bars.length; i++) {
      tempToBarIndex[layout.bars[i].id] = i;
    }

    Path? freeDots(Rect rect) {
      if (rect.width < 16 || rect.height < 12) return null;
      final path = Path();
      for (var y = rect.top + 8; y < rect.bottom - 5; y += 10) {
        for (var x = rect.left + 8; x < rect.right - 5; x += 10) {
          path.addOval(Rect.fromCircle(center: Offset(x, y), radius: 1.0));
        }
      }
      return path;
    }

    final bars = <FlowBarVisual>[];
    for (var i = 0; i < layout.bars.length; i++) {
      final b = layout.bars[i];
      final rect = b.rect.shift(Offset(0, yOffset));
      final item = itemsByTempId[b.id]!;
      final maxChars = math.max(2, (rect.width / 8.0).floor());
      final label = rect.width >= 44
          ? MarkLabel(
              name: item.title.length > maxChars
                  ? '${item.title.substring(0, maxChars - 1)}…'
                  : item.title,
              fontSize: 11.5,
            )
          : null;

      bars.add(
        FlowBarVisual(
          item: item,
          key: keysByTempId[b.id]!,
          level: b.level,
          parent: b.parent != null ? tempToBarIndex[b.parent!] : null,
          rect: rect,
          tone: tonesByTempId[b.id]!,
          dots: item.kind == MapItemKind.free ? freeDots(rect) : null,
          label: label,
        ),
      );
    }

    final ribbons = <FlowRibbonVisual>[];
    for (final r in layout.ribbons) {
      final pIdx = tempToBarIndex[r.parent];
      final cIdx = tempToBarIndex[r.child];
      if (pIdx == null || cIdx == null) continue;
      final topY = r.topY + yOffset;
      final bottomY = r.bottomY + yOffset;
      final midY = (topY + bottomY) / 2.0;
      final path = Path()
        ..moveTo(r.topStart, topY)
        ..lineTo(r.topEnd, topY)
        ..cubicTo(r.topEnd, midY, r.bottomEnd, midY, r.bottomEnd, bottomY)
        ..lineTo(r.bottomStart, bottomY)
        ..cubicTo(r.bottomStart, midY, r.topStart, midY, r.topStart, topY)
        ..close();
      ribbons.add(FlowRibbonVisual(parent: pIdx, child: cIdx, path: path));
    }

    return FlowScene(bars: bars, ribbons: ribbons, size: size);
  }
}

class MapScene {
  MapScene.bubbles(BubbleScene scene)
    : mode = MapMode.bubbles,
      bubbles = scene,
      flow = null;

  MapScene.flow(FlowScene scene)
    : mode = MapMode.flow,
      bubbles = null,
      flow = scene;

  final MapMode mode;
  final BubbleScene? bubbles;
  final FlowScene? flow;

  static MapScene build(
    MapMode mode, {
    required MapCatalog catalog,
    required int focus,
    required Size size,
  }) {
    return switch (mode) {
      MapMode.bubbles => MapScene.bubbles(
        BubbleScene.build(catalog: catalog, focus: focus, size: size),
      ),
      MapMode.flow => MapScene.flow(
        FlowScene.build(catalog: catalog, focus: focus, size: size),
      ),
    };
  }

  int? deepestMark(Set<int> ids) {
    return switch (mode) {
      MapMode.bubbles => bubbles?.deepestCell(ids),
      MapMode.flow => flow?.deepestBar(ids),
    };
  }

  Tone? toneOfTopItem(int id) {
    switch (mode) {
      case MapMode.bubbles:
        final b = bubbles;
        if (b == null) return null;
        for (final idx in b.top) {
          if (b.cells[idx].item.id == id) return b.cells[idx].tone;
        }
        return null;
      case MapMode.flow:
        final f = flow;
        if (f == null) return null;
        for (final bar in f.bars) {
          if (bar.level == 0 && bar.item.id == id) return bar.tone;
        }
        return null;
    }
  }
}
