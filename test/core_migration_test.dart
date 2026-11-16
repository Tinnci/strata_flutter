import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_flutter/layout/bubble_layout.dart';
import 'package:strata_flutter/layout/flow_layout.dart';
import 'package:strata_flutter/layout/geometry.dart';
import 'package:strata_flutter/layout/squarify.dart';
import 'package:strata_flutter/model/disk_backend.dart';
import 'package:strata_flutter/model/file_tree.dart';
import 'package:strata_flutter/motion/morph.dart';
import 'package:strata_flutter/motion/motion.dart';
import 'package:strata_flutter/scene/map_scene.dart';
import 'package:strata_flutter/theme/theme.dart';
import 'package:strata_flutter/ui/strata_app.dart';

class _FailingBackend implements DiskBackend {
  @override
  bool get supportsSystemActions => true;

  @override
  Future<List<DiskVolume>> listVolumes() async => const [];

  @override
  Future<MapCatalog> scanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) async =>
      throw StateError('unimplemented');

  @override
  Stream<ScanUpdate> watchScanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) =>
      Stream.error(StateError('unimplemented'));

  @override
  Future<void> revealInExplorer(String path) async {}

  @override
  Future<void> moveToTrash(String path) async {}
}

void main() {
  group('Geometry & Squarify', () {
    test('polygon area, centroid, containment, and inset', () {
      const rect = Rect.fromLTWH(0, 0, 100, 100);
      final poly = Geometry.roundedRect(rect, radius: 10);
      expect(Geometry.area(poly), greaterThan(9500));
      expect(Geometry.contains(poly, const Offset(50, 50)), isTrue);
      expect(Geometry.contains(poly, const Offset(-5, 50)), isFalse);

      final shrunk = Geometry.inset(poly, 5);
      expect(Geometry.area(shrunk), lessThan(Geometry.area(poly)));
      expect(
        Geometry.soften(shrunk, cap: 8).length,
        greaterThan(shrunk.length),
      );
    });

    test('squarify preserves total area', () {
      const bounds = Rect.fromLTWH(0, 0, 200, 100);
      final rects = Squarify.rects([60, 30, 10], bounds);
      expect(rects.length, 3);
      final sum = rects.fold<double>(0, (acc, r) => acc + r.width * r.height);
      expect(sum, closeTo(20000, 1e-6));
    });
  });

  group('BubbleLayout & FlowLayout', () {
    test('bubble layout converges within tolerance', () {
      final region = Geometry.roundedRect(
        const Rect.fromLTWH(0, 0, 400, 300),
        radius: 24,
      );
      final sizes = [500.0, 250.0, 150.0, 100.0];
      final cells = BubbleLayout.ordered(sizes: sizes, region: region);
      expect(cells.length, sizes.length);

      final totalArea = cells.fold<double>(
        0,
        (sum, c) => sum + Geometry.area(c),
      );
      expect(totalArea, closeTo(Geometry.area(region), 1e-3));
      for (var i = 0; i < sizes.length; i++) {
        final share = Geometry.area(cells[i]) / totalArea;
        expect(share, closeTo(sizes[i] / 1000.0, 0.02));
      }
    });

    test('flow layout keeps uniform scale across levels', () {
      final result = FlowLayout.layout(
        roots: const [
          FlowInput(
            id: 1,
            size: 100,
            children: [FlowInput(id: 2, size: 60), FlowInput(id: 3, size: 40)],
          ),
        ],
        width: 500,
        levels: 2,
        rowHeight: 32,
        between: 24,
        spacing: 8,
      );
      expect(result.bars.length, 3);
      expect(result.ribbons.length, 2);
      final rootBar = result.bars.firstWhere((b) => b.id == 1);
      final child2 = result.bars.firstWhere((b) => b.id == 2);
      final child3 = result.bars.firstWhere((b) => b.id == 3);
      expect(
        child2.rect.width + child3.rect.width,
        closeTo(rootBar.rect.width, 1e-6),
      );
    });
  });

  group('Theme & Motion', () {
    test('OKLCH theme conversion and ink contrast', () {
      for (final theme in StrataTheme.all) {
        final fill = theme.fill(const Tone.family(0));
        final ink = theme.ink(fill);
        expect(fill.color.a, closeTo(1.0, 1e-6));
        expect(ink.l == 0.2 || ink.l == 0.97, isTrue);
      }
    });

    test('Spring overshoots and settles at target', () {
      final spring = Spring();
      var peak = 0.0;
      for (var i = 0; i < 120; i++) {
        spring.step(1.0, 1.0 / 60.0);
        if (spring.value > peak) peak = spring.value;
      }
      expect(peak, greaterThan(1.0));
      expect(spring.isResting(1.0), isTrue);
      expect(Spring.response(1.5), closeTo(1.0, 0.02));
    });

    test('Morph matches inner folder items across drill-down scenes', () {
      final catalog = SampleCatalog.build();
      final topItems = catalog.itemsIn(FileTree.root);
      final folder = topItems.firstWhere(
        (it) =>
            it.kind == MapItemKind.folder &&
            catalog.childrenOfItem(it).length > 1,
      );
      const size = Size(800, 600);
      for (final mode in MapMode.values) {
        final outer = MapScene.build(
          mode,
          catalog: catalog,
          focus: FileTree.root,
          size: size,
        );
        final inner = MapScene.build(
          mode,
          catalog: catalog,
          focus: folder.id,
          size: size,
        );
        final morph = Morph(
          outer: outer,
          inner: inner,
          leavesOuter: true,
          anchor: outer.deepestMark({folder.id}),
          bounds: size,
        );
        expect(morph.matchCount, greaterThan(0));
        final midPose = morph.pose(0.5);
        expect(midPose.outerAlpha, isNotEmpty);
        expect(midPose.innerAlpha, isNotEmpty);
      }
    });

    test('FlowScene keeps positive bar widths on deep dense trees', () {
      final nodes = <TreeNode>[];
      final rootChildren = <int>[];
      nodes.add(const TreeNode(
        id: 0,
        parent: null,
        name: 'C:\\',
        size: 1000000,
        kind: NodeKind.directory,
        children: [],
      ));
      for (var i = 0; i < 10; i++) {
        final l1Id = nodes.length;
        rootChildren.add(l1Id);
        final l1Children = <int>[];
        nodes.add(TreeNode(
          id: l1Id,
          parent: 0,
          name: 'dir_$i',
          size: 100000,
          kind: NodeKind.directory,
          children: l1Children,
        ));
        for (var j = 0; j < 10; j++) {
          final l2Id = nodes.length;
          l1Children.add(l2Id);
          final l2Children = <int>[];
          nodes.add(TreeNode(
            id: l2Id,
            parent: l1Id,
            name: 'sub_${i}_$j',
            size: 10000,
            kind: NodeKind.directory,
            children: l2Children,
          ));
          for (var k = 0; k < 10; k++) {
            final l3Id = nodes.length;
            l2Children.add(l3Id);
            nodes.add(TreeNode(
              id: l3Id,
              parent: l2Id,
              name: 'leaf_${i}_${j}_$k',
              size: 1000,
              kind: NodeKind.directory,
            ));
          }
        }
      }
      nodes[0] = TreeNode(
        id: 0,
        parent: null,
        name: 'C:\\',
        size: 1000000,
        kind: NodeKind.directory,
        children: rootChildren,
      );
      final catalog = MapCatalog(
        tree: FileTree(
          nodes: nodes,
          rootPath: 'C:\\',
          scannedAt: DateTime.now(),
          entryCount: nodes.length,
        ),
      );
      final flow = FlowScene.build(
        catalog: catalog,
        focus: FileTree.root,
        size: const Size(800, 600),
      );
      expect(flow.bars, isNotEmpty);
      expect(flow.bars.first.rect.width, greaterThan(20.0));
    });

    test('StrataController never falls back to SampleCatalog on native failure', () async {
      final controller = StrataController(backend: _FailingBackend());
      expect(controller.phase, CatalogPhase.loading);
      expect(controller.catalog, isNull);

      await controller.initialize();
      expect(controller.phase, CatalogPhase.error);
      expect(controller.catalog, isNull);
      expect(controller.scanError, isNotNull);
      controller.dispose();
    });
  });
}
