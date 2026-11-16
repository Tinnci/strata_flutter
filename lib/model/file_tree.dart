import 'dart:math' as math;

enum NodeKind { directory, file, smallItems }

class TreeNode {
  const TreeNode({
    required this.id,
    required this.parent,
    required this.name,
    required this.size,
    required this.kind,
    this.itemCount = 1,
    this.children = const [],
  });

  final int id;
  final int? parent;
  final String name;
  final int size;
  final NodeKind kind;
  final int itemCount;
  final List<int> children;
}

class VolumeInfo {
  const VolumeInfo({
    required this.name,
    required this.totalBytes,
    required this.availableBytes,
  });

  final String name;
  final int totalBytes;
  final int availableBytes;
}

class FileTree {
  const FileTree({
    required this.nodes,
    required this.rootPath,
    required this.scannedAt,
    required this.entryCount,
  });

  static const int root = 0;

  final List<TreeNode> nodes;
  final String rootPath;
  final DateTime scannedAt;
  final int entryCount;

  List<int> childrenOf(int index) {
    if (index < 0 || index >= nodes.length) return const [];
    return nodes[index].children;
  }
}

enum MapItemKind { folder, file, small, hidden, unscanned, free }

class MapItem {
  const MapItem({
    required this.id,
    required this.name,
    required this.size,
    required this.kind,
    this.count = 0,
  });

  static const int freeId = -1;
  static const int hiddenId = -2;

  final int id;
  final String name;
  final int size;
  final MapItemKind kind;
  final int count;

  bool get isEntry =>
      id >= 0 && (kind == MapItemKind.folder || kind == MapItemKind.file);

  String get title => switch (kind) {
        MapItemKind.small => '$count 个小项',
        MapItemKind.free => '可用',
        _ => name,
      };

  bool get isOutsideScan =>
      kind == MapItemKind.hidden ||
      kind == MapItemKind.unscanned ||
      kind == MapItemKind.free;
}

class Crumb {
  const Crumb({required this.index, required this.name});

  final int index;
  final String name;
}

class MapCatalog {
  const MapCatalog({
    required this.tree,
    this.volume,
    this.isLive = false,
  });

  final FileTree tree;
  final VolumeInfo? volume;
  final bool isLive;

  int get hiddenBytes {
    final v = volume;
    if (v == null) return 0;
    final scanned = tree.nodes[FileTree.root].size;
    final accounted = scanned + v.availableBytes;
    return v.totalBytes > accounted ? v.totalBytes - accounted : 0;
  }

  int get totalBytes => volume?.totalBytes ?? tree.nodes[FileTree.root].size;

  MapItem item(int index) {
    final node = tree.nodes[index];
    return switch (node.kind) {
      NodeKind.directory => MapItem(
          id: index,
          name: node.name,
          size: node.size,
          kind: MapItemKind.folder,
        ),
      NodeKind.file => MapItem(
          id: index,
          name: node.name,
          size: node.size,
          kind: MapItemKind.file,
        ),
      NodeKind.smallItems => MapItem(
          id: index,
          name: '',
          size: node.size,
          kind: MapItemKind.small,
          count: node.itemCount,
        ),
    };
  }

  List<MapItem> childrenOfIndex(int index) {
    return tree
        .childrenOf(index)
        .where((c) => tree.nodes[c].size > 0)
        .map(item)
        .toList(growable: false);
  }

  List<MapItem> childrenOfItem(MapItem mapItem) {
    if (mapItem.kind == MapItemKind.folder && mapItem.id >= 0) {
      return childrenOfIndex(mapItem.id);
    }
    return const [];
  }

  List<MapItem> itemsIn(int focus) {
    var items = List<MapItem>.from(childrenOfIndex(focus));
    if (focus != FileTree.root) return items;

    var opened = false;
    while (items.isNotEmpty && items.first.kind == MapItemKind.folder) {
      final first = items.first;
      final total = items.fold<int>(0, (sum, e) => sum + e.size);
      if (first.size <= 0.6 * total) break;
      final inside = childrenOfIndex(first.id);
      if (inside.length <= 1) break;
      items = [...inside, ...items.skip(1)]
        ..sort((a, b) => b.size.compareTo(a.size));
      opened = true;
    }

    if (opened) {
      final seen = <String>{};
      for (final it in items) {
        if (it.id >= 0 && tree.nodes[it.id].parent != FileTree.root) {
          seen.add(it.name);
        }
      }
      items = items.map((it) {
        if (it.kind == MapItemKind.folder &&
            it.id >= 0 &&
            tree.nodes[it.id].parent == FileTree.root &&
            seen.contains(it.name)) {
          return MapItem(
            id: it.id,
            name: '/${it.name}',
            size: it.size,
            kind: it.kind,
            count: it.count,
          );
        }
        return it;
      }).toList();
    }

    if (hiddenBytes > 0) {
      items.add(MapItem(
        id: MapItem.hiddenId,
        name: isLive ? '还没扫到' : '系统与保留空间',
        size: hiddenBytes,
        kind: isLive ? MapItemKind.unscanned : MapItemKind.hidden,
      ));
    }
    if (volume != null && volume!.availableBytes > 0) {
      items.add(MapItem(
        id: MapItem.freeId,
        name: '',
        size: volume!.availableBytes,
        kind: MapItemKind.free,
      ));
    }
    return items;
  }

  String keyOf(MapItem mapItem, {String parentKey = ''}) {
    if (mapItem.id >= 0) return 'n:${mapItem.id}';
    if (mapItem.kind == MapItemKind.small) return '$parentKey/small';
    return 'k:${mapItem.kind.name}';
  }

  List<Crumb> crumbsTo(int focus) {
    final chain = <Crumb>[];
    int? current = focus;
    while (current != null && current >= 0 && current < tree.nodes.length) {
      final node = tree.nodes[current];
      final label = current == FileTree.root
          ? (volume?.name ?? tree.rootPath)
          : node.name;
      chain.add(Crumb(index: current, name: label));
      current = node.parent;
    }
    return chain.reversed.toList(growable: false);
  }
}

abstract final class Format {
  static String size(int bytes) {
    if (bytes < 1000) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes.toDouble();
    var unitIndex = -1;
    while (value >= 1000 && unitIndex < units.length - 1) {
      value /= 1000.0;
      unitIndex++;
    }
    final decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 1);
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  static String percent(double share) {
    final pct = (share * 100).clamp(0.0, 100.0);
    if (pct >= 10) return '${pct.toStringAsFixed(0)}%';
    if (pct >= 1) return '${pct.toStringAsFixed(1)}%';
    return '<1%';
  }

  static String count(int value) {
    final s = value.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final rev = s.length - i;
      buf.write(s[i]);
      if (rev > 1 && rev % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }
}

class _DemoFolder {
  const _DemoFolder(this.name, [this.gb = 0.0, this.inside = const []]);

  final String name;
  final double gb;
  final List<_DemoFolder> inside;
}

abstract final class DemoDisk {
  static const int _gb = 1000000000;

  static const _rootFolder = _DemoFolder('', 0.2, [
    _DemoFolder('Users', 0, [
      _DemoFolder('alex', 0.3, [
        _DemoFolder('Library', 0.4, [
          _DemoFolder('Developer', 0.1, [
            _DemoFolder('Xcode', 0.2, [
              _DemoFolder('DerivedData', 1.6, [
                _DemoFolder('Lumen-fkqzdh', 7.4),
                _DemoFolder('Harbor-azbtrc', 5.1),
                _DemoFolder('Cinder-rkpxwo', 3.8),
              ]),
              _DemoFolder('iOS DeviceSupport', 0, [
                _DemoFolder('iPhone17,1 26.1', 6.8),
                _DemoFolder('iPhone16,2 18.6', 4.9),
              ]),
              _DemoFolder('Archives', 3.4),
            ]),
            _DemoFolder('CoreSimulator', 0.3, [
              _DemoFolder('Devices', 48.0),
              _DemoFolder('Caches', 6.4),
            ]),
          ]),
          _DemoFolder('Application Support', 1.2, [
            _DemoFolder('Steam', 0.4, [_DemoFolder('steamapps', 62.0)]),
            _DemoFolder('MobileSync', 0, [_DemoFolder('Backup', 12.3)]),
            _DemoFolder('Adobe', 7.2),
            _DemoFolder('Google', 0.2, [_DemoFolder('Chrome', 3.9)]),
            _DemoFolder('Code', 2.3),
            _DemoFolder('Slack', 1.6),
          ]),
          _DemoFolder('Containers', 3.0, [
            _DemoFolder('com.docker.docker', 21.0),
            _DemoFolder('com.apple.mail', 5.3),
            _DemoFolder('com.apple.Safari', 2.2),
          ]),
          _DemoFolder('Caches', 2.1, [
            _DemoFolder('com.spotify.client', 4.6),
            _DemoFolder('Homebrew', 3.4),
            _DemoFolder('Google', 2.2),
            _DemoFolder('pip', 1.3),
          ]),
          _DemoFolder('Messages', 7.8),
          _DemoFolder('Mail', 4.4),
        ]),
        _DemoFolder('Pictures', 0.6, [
          _DemoFolder('Photos Library', 0.4, [
            _DemoFolder('originals', 160.0),
            _DemoFolder('resources', 13.6),
          ]),
          _DemoFolder('Lightroom', 9.6),
        ]),
        _DemoFolder('Movies', 3.0, [
          _DemoFolder('Final Cut Projects', 88.0),
          _DemoFolder('Screen Recordings', 8.2),
        ]),
        _DemoFolder('Documents', 2.2, [
          _DemoFolder('Projects', 0.5, [
            _DemoFolder('Strata', 9.2),
            _DemoFolder('Harbor', 6.1),
            _DemoFolder('Website', 2.4),
          ]),
          _DemoFolder('Design', 8.8),
          _DemoFolder('Papers', 3.1),
        ]),
        _DemoFolder('Music', 0.3, [
          _DemoFolder('Media', 21.0),
          _DemoFolder('Logic', 6.4),
        ]),
        _DemoFolder('Downloads', 16.5),
        _DemoFolder('Desktop', 4.1),
        _DemoFolder('.cache', 0.2, [
          _DemoFolder('huggingface', 38.0),
          _DemoFolder('uv', 1.4),
        ]),
        _DemoFolder('.npm', 0.1, [_DemoFolder('_cacache', 3.1)]),
        _DemoFolder('.cargo', 0.1, [
          _DemoFolder('registry', 0, [_DemoFolder('cache', 1.8)]),
        ]),
      ]),
      _DemoFolder('Shared', 1.4),
    ]),
    _DemoFolder('Applications', 2.4, [
      _DemoFolder('Xcode', 12.6),
      _DemoFolder('Final Cut Pro', 6.1),
      _DemoFolder('Photoshop 2026', 4.4),
      _DemoFolder('Logic Pro', 3.2),
      _DemoFolder('Docker', 2.1),
      _DemoFolder('Blender', 1.5),
    ]),
    _DemoFolder('Library', 1.3, [
      _DemoFolder('Audio', 0, [_DemoFolder('Apple Loops', 8.4)]),
      _DemoFolder('Application Support', 4.2),
      _DemoFolder('Developer', 0, [_DemoFolder('CommandLineTools', 3.6)]),
    ]),
    _DemoFolder('opt', 0, [_DemoFolder('homebrew', 6.8)]),
  ]);

  static MapCatalog catalog() {
    final rawParents = <int?>[];
    final rawNames = <String>[];
    final rawSizes = <int>[];
    final rawChildren = <List<int>>[];

    int addNode(_DemoFolder folder, int? parent) {
      final id = rawNames.length;
      rawParents.add(parent);
      rawNames.add(folder.name);
      rawSizes.add((folder.gb * _gb).round());
      rawChildren.add(<int>[]);
      if (parent != null) {
        rawChildren[parent].add(id);
      }
      for (final child in folder.inside) {
        addNode(child, id);
      }
      return id;
    }

    addNode(_rootFolder, null);

    int computeSize(int id) {
      var sum = rawSizes[id];
      for (final c in rawChildren[id]) {
        sum += computeSize(c);
      }
      rawSizes[id] = sum;
      return sum;
    }

    computeSize(0);

    for (final children in rawChildren) {
      children.sort((a, b) => rawSizes[b].compareTo(rawSizes[a]));
    }

    final nodes = List<TreeNode>.generate(rawNames.length, (i) {
      return TreeNode(
        id: i,
        parent: rawParents[i],
        name: rawNames[i],
        size: rawSizes[i],
        kind: NodeKind.directory,
        children: rawChildren[i],
      );
    });

    final tree = FileTree(
      nodes: nodes,
      rootPath: 'Local Disk (C:)',
      scannedAt: DateTime.now(),
      entryCount: 2418306,
    );

    final totalBytes = math.max(nodes[0].size + 185 * _gb, 1000 * _gb);
    return MapCatalog(
      tree: tree,
      volume: VolumeInfo(
        name: 'Local Disk (C:)',
        totalBytes: totalBytes,
        availableBytes: 142 * _gb,
      ),
    );
  }
}
