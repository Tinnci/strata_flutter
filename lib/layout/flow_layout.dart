import 'dart:math' as math;
import 'dart:ui';

class FlowInput {
  const FlowInput({
    required this.id,
    required this.size,
    this.children = const [],
  });

  final int id;
  final double size;
  final List<FlowInput> children;
}

class FlowBar {
  const FlowBar({
    required this.id,
    required this.parent,
    required this.level,
    required this.rect,
  });

  final int id;
  final int? parent;
  final int level;
  final Rect rect;
}

class FlowRibbon {
  const FlowRibbon({
    required this.parent,
    required this.child,
    required this.topStart,
    required this.topEnd,
    required this.bottomStart,
    required this.bottomEnd,
    required this.topY,
    required this.bottomY,
  });

  final int parent;
  final int child;
  final double topStart;
  final double topEnd;
  final double bottomStart;
  final double bottomEnd;
  final double topY;
  final double bottomY;
}

class FlowResult {
  const FlowResult({
    this.bars = const [],
    this.ribbons = const [],
    this.size = Size.zero,
    this.scale = 0.0,
  });

  final List<FlowBar> bars;
  final List<FlowRibbon> ribbons;
  final Size size;
  final double scale;
}

class _FlowNode {
  _FlowNode(this.input);

  final FlowInput input;
  List<_FlowNode> children = const [];
  double width = 0.0;
  double inner = 0.0;
  double span = 0.0;
}

abstract final class FlowLayout {
  static FlowResult layout({
    required List<FlowInput> roots,
    required double width,
    required int levels,
    required double rowHeight,
    required double between,
    required double spacing,
  }) {
    if (roots.isEmpty || width <= 0 || levels <= 0) {
      return const FlowResult();
    }

    _FlowNode build(FlowInput input, int depth) {
      final node = _FlowNode(input);
      if (depth < levels) {
        node.children = input.children
            .map((c) => build(c, depth + 1))
            .toList(growable: false);
      }
      return node;
    }

    final top = roots.map((r) => build(r, 1)).toList(growable: false);
    final total = math.max(
      roots.fold<double>(0.0, (a, b) => a + b.size),
      double.minPositive,
    );

    double measure(_FlowNode node, double scale) {
      node.width = node.input.size * scale;
      node.inner = 0.0;
      for (final child in node.children) {
        node.inner += measure(child, scale);
      }
      node.inner += spacing * math.max(node.children.length - 1, 0);
      node.span = math.max(node.width, node.inner);
      return node.span;
    }

    double rowSpan(double scale) {
      return top.fold<double>(0.0, (sum, node) => sum + measure(node, scale)) +
          spacing * (top.length - 1);
    }

    var low = 0.0;
    var high = width / total;
    for (var i = 0; i < 48; i++) {
      final middle = (low + high) / 2.0;
      if (rowSpan(middle) > width) {
        high = middle;
      } else {
        low = middle;
      }
    }
    final used = rowSpan(low);

    final bars = <FlowBar>[];
    final ribbons = <FlowRibbon>[];
    var deepest = 0;

    void place(_FlowNode node, double left, int level, int? parent) {
      final x = left + (node.span - node.width) / 2.0;
      final y = level * (rowHeight + between);
      if (level > deepest) deepest = level;
      bars.add(FlowBar(
        id: node.input.id,
        parent: parent,
        level: level,
        rect: Rect.fromLTWH(x, y, node.width, rowHeight),
      ));
      if (node.children.isEmpty) return;

      var childLeft = left + (node.span - node.inner) / 2.0;
      var anchor = x;
      for (final child in node.children) {
        place(child, childLeft, level + 1, node.input.id);
        final childX = childLeft + (child.span - child.width) / 2.0;
        ribbons.add(FlowRibbon(
          parent: node.input.id,
          child: child.input.id,
          topStart: anchor,
          topEnd: anchor + child.width,
          bottomStart: childX,
          bottomEnd: childX + child.width,
          topY: y + rowHeight,
          bottomY: y + rowHeight + between,
        ));
        anchor += child.width;
        childLeft += child.span + spacing;
      }
    }

    var left = (width - used) / 2.0;
    for (final node in top) {
      place(node, left, 0, null);
      left += node.span + spacing;
    }

    return FlowResult(
      bars: bars,
      ribbons: ribbons,
      size: Size(width, (deepest + 1) * rowHeight + deepest * between),
      scale: low,
    );
  }
}
