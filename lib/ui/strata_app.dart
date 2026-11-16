import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../model/disk_backend.dart';
import '../model/file_tree.dart';
import '../motion/morph.dart';
import '../motion/motion_state.dart';
import '../render/map_renderer.dart';
import '../scene/map_scene.dart';
import '../theme/theme.dart';

class HoverInfo {
  const HoverInfo({
    required this.title,
    required this.size,
    required this.share,
    required this.detail,
  });

  final String title;
  final String size;
  final String share;
  final String detail;
}

class PointerState {
  const PointerState({this.location, this.info});

  final Offset? location;
  final HoverInfo? info;
}

class StrataController extends ChangeNotifier {
  StrataController({this.backend = const SampleDiskBackend()}) {
    catalog = SampleCatalog.build();
    if (backend.supportsSystemActions) {
      Future.microtask(initialize);
    }
  }

  final DiskBackend backend;
  late MapCatalog catalog;
  List<DiskVolume> _volumes = const [];
  DiskVolume? _selectedVolume;
  bool _scanning = false;
  bool _diskMenuOpen = false;
  String? _scanError;
  StrataTheme _theme = StrataTheme.abyss;
  MapMode _mode = MapMode.bubbles;
  int _focus = FileTree.root;
  Size _mapSize = Size.zero;
  MapScene? _scene;
  int? _highlighted;
  int? _flowFocus;

  final MotionState motion = MotionState();
  final ValueNotifier<PointerState> pointer = ValueNotifier<PointerState>(
    const PointerState(),
  );
  final ValueNotifier<int> canvasTick = ValueNotifier<int>(0);
  VoidCallback? onRequestAnimate;

  StrataTheme get theme => _theme;
  MapMode get mode => _mode;
  int get focus => _focus;
  MapScene? get scene => _scene;
  int? get highlighted => _highlighted;
  int? get flowFocus => _flowFocus;
  Size get mapSize => _mapSize;
  List<DiskVolume> get volumes => _volumes;
  DiskVolume? get selectedVolume => _selectedVolume;
  bool get scanning => _scanning;
  bool get diskMenuOpen => _diskMenuOpen;
  String? get scanError => _scanError;

  void setDiskMenuOpen(bool open) {
    if (_diskMenuOpen == open) return;
    _diskMenuOpen = open;
    notifyListeners();
  }

  Future<void> initialize() async {
    try {
      _volumes = await backend.listVolumes();
      if (_volumes.isNotEmpty) {
        final preferred = _volumes.firstWhere(
          (v) => v.isSystemDrive,
          orElse: () => _volumes.first,
        );
        await selectVolume(preferred);
      }
    } catch (e) {
      _scanError = e.toString();
      notifyListeners();
    }
  }

  Future<void> selectVolume(DiskVolume volume) async {
    _diskMenuOpen = false;
    _selectedVolume = volume;
    await scanPath(volume.mountPoint, volume: volume);
  }

  Future<void> rescan() async {
    final v = _selectedVolume;
    if (v != null) {
      await scanPath(v.mountPoint, volume: v);
    } else if (backend.supportsSystemActions) {
      await initialize();
    }
  }

  Future<void> scanPath(
    String rootPath, {
    DiskVolume? volume,
  }) async {
    if (!backend.supportsSystemActions || _scanning) return;
    _scanning = true;
    _scanError = null;
    notifyListeners();

    try {
      catalog = await backend.scanPath(rootPath, volume: volume);
      _focus = FileTree.root;
      _highlighted = null;
      _flowFocus = null;
      pointer.value = const PointerState();
      _rebuild(MapTransitionKind.swap);
    } catch (e) {
      _scanError = e.toString();
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  Future<void> revealItem(MapItem item) async {
    if (!backend.supportsSystemActions || !item.isEntry) return;
    final path = catalog.pathOf(item.id);
    if (path == null) return;
    try {
      await backend.revealInExplorer(path);
    } catch (e) {
      _scanError = e.toString();
      notifyListeners();
    }
  }

  Future<void> trashItem(MapItem item) async {
    if (!backend.supportsSystemActions || !item.isEntry) return;
    final path = catalog.pathOf(item.id);
    if (path == null) return;
    try {
      await backend.moveToTrash(path);
      await rescan();
    } catch (e) {
      _scanError = e.toString();
      notifyListeners();
    }
  }

  MapItem? hitItemAt(Offset location) {
    final s = _scene;
    if (s == null) return null;
    switch (s.mode) {
      case MapMode.bubbles:
        final chain = s.bubbles!.hit(location);
        return chain.isNotEmpty ? s.bubbles!.cells[chain.last].item : null;
      case MapMode.flow:
        final idx = s.flow!.hit(location);
        return idx != null ? s.flow!.bars[idx].item : null;
    }
  }

  set theme(StrataTheme value) {
    if (_theme.id == value.id) return;
    _theme = value;
    notifyListeners();
    canvasTick.value++;
  }

  set mode(MapMode value) {
    if (_mode == value) return;
    _mode = value;
    _rebuild(MapTransitionKind.swap);
    notifyListeners();
  }

  void setMapSize(Size size) {
    if ((size.width - _mapSize.width).abs() < 1 &&
        (size.height - _mapSize.height).abs() < 1) {
      return;
    }
    final first = _scene == null;
    _mapSize = size;
    _rebuild(first ? MapTransitionKind.popIn : MapTransitionKind.none);
  }

  void goTo(int nodeId) {
    if (nodeId == _focus) return;
    final previousFocus = _focus;
    final previousScene = _scene;
    final previousFlowFocus = _flowFocus;
    _focus = nodeId;
    _highlighted = null;
    _flowFocus = null;
    pointer.value = const PointerState();

    if (previousScene == null ||
        _mapSize.width <= 80 ||
        _mapSize.height <= 80) {
      _rebuild(MapTransitionKind.swap);
      notifyListeners();
      return;
    }

    final nextScene = MapScene.build(
      _mode,
      catalog: catalog,
      focus: _focus,
      size: _mapSize,
    );
    _scene = nextScene;

    final entering = _isDescendant(nodeId, of: previousFocus);
    final outer = entering ? previousScene : nextScene;
    final inner = entering ? nextScene : previousScene;
    final targetId = entering ? nodeId : previousFocus;
    final anchor = outer.deepestMark({targetId});
    final morph = Morph(
      outer: outer,
      inner: inner,
      leavesOuter: entering,
      anchor: anchor,
      bounds: _mapSize,
    );

    final nowSec = DateTime.now().microsecondsSinceEpoch / 1e6;
    if (morph.matchCount > 0) {
      motion.begin(
        MapTransitionKind.morph,
        morph: morph,
        flowFocus: previousFlowFocus,
        atSeconds: nowSec,
      );
    } else {
      motion.begin(
        MapTransitionKind.swap,
        previous: previousScene,
        atSeconds: nowSec,
      );
    }
    onRequestAnimate?.call();
    canvasTick.value++;
    notifyListeners();
  }

  bool _isDescendant(int nodeId, {required int of}) {
    int? current = nodeId;
    while (current != null &&
        current >= 0 &&
        current < catalog.tree.nodes.length) {
      if (current == of) return true;
      current = catalog.tree.nodes[current].parent;
    }
    return false;
  }

  void goUp() {
    if (_focus == FileTree.root) return;
    final parent = catalog.tree.nodes[_focus].parent ?? FileTree.root;
    goTo(parent);
  }

  void _rebuild(MapTransitionKind kind) {
    if (_mapSize.width <= 80 || _mapSize.height <= 80) return;
    final previous = _scene;
    _scene = MapScene.build(
      _mode,
      catalog: catalog,
      focus: _focus,
      size: _mapSize,
    );
    final nowSec = DateTime.now().microsecondsSinceEpoch / 1e6;
    motion.begin(kind, previous: previous, atSeconds: nowSec);
    if (kind != MapTransitionKind.none) {
      onRequestAnimate?.call();
    }
    canvasTick.value++;
  }

  void pointerMoved(Offset? location) {
    final s = _scene;
    if (location == null || s == null) {
      if (motion.targets.isNotEmpty ||
          _highlighted != null ||
          _flowFocus != null ||
          pointer.value.location != null) {
        motion.targets = {};
        _flowFocus = null;
        pointer.value = const PointerState();
        if (_highlighted != null) {
          _highlighted = null;
          notifyListeners();
        }
        onRequestAnimate?.call();
      }
      return;
    }

    switch (s.mode) {
      case MapMode.bubbles:
        final b = s.bubbles!;
        final chain = b.hit(location);
        motion.targets = chain.toSet();
        final topId = chain.isNotEmpty ? b.cells[chain.first].item.id : null;
        final deepCell = chain.isNotEmpty ? b.cells[chain.last] : null;
        _updateHover(location, deepCell?.item, topId);
      case MapMode.flow:
        final f = s.flow!;
        final hitIdx = f.hit(location);
        motion.targets = hitIdx != null ? {hitIdx} : {};
        _flowFocus = hitIdx;
        int? topId;
        if (hitIdx != null) {
          var cur = hitIdx;
          while (f.bars[cur].parent != null) {
            cur = f.bars[cur].parent!;
          }
          topId = f.bars[cur].item.id;
        }
        _updateHover(
          location,
          hitIdx != null ? f.bars[hitIdx].item : null,
          topId,
        );
    }
    onRequestAnimate?.call();
  }

  void highlightFromList(int? itemId) {
    final s = _scene;
    if (s == null || itemId == null) {
      motion.targets = {};
      _flowFocus = null;
      if (_highlighted != null) {
        _highlighted = null;
        notifyListeners();
      }
      onRequestAnimate?.call();
      return;
    }
    final mark = s.deepestMark({itemId});
    motion.targets = mark != null ? {mark} : {};
    _flowFocus = s.mode == MapMode.flow ? mark : null;
    if (_highlighted != itemId) {
      _highlighted = itemId;
      notifyListeners();
    }
    onRequestAnimate?.call();
  }

  void _updateHover(Offset location, MapItem? item, int? topId) {
    if (_highlighted != topId) {
      _highlighted = topId;
      notifyListeners();
    }
    if (item == null) {
      pointer.value = PointerState(location: location, info: null);
      return;
    }
    final total = math.max(catalog.totalBytes, 1);
    final share = Format.percent(item.size / total);
    final detail = switch (item.kind) {
      MapItemKind.folder => '${catalog.childrenOfItem(item).length} 个子项 · 点击进入',
      MapItemKind.free => '磁盘剩余可用空间',
      MapItemKind.hidden => '系统占用或受限目录',
      _ => '',
    };
    pointer.value = PointerState(
      location: location,
      info: HoverInfo(
        title: item.title,
        size: Format.size(item.size),
        share: share,
        detail: detail,
      ),
    );
  }

  void clickedAt(Offset location) {
    final s = _scene;
    if (s == null) return;
    MapItem? targetItem;
    switch (s.mode) {
      case MapMode.bubbles:
        final chain = s.bubbles!.hit(location);
        if (chain.isNotEmpty) {
          targetItem = s.bubbles!.cells[chain.last].item;
        }
      case MapMode.flow:
        final idx = s.flow!.hit(location);
        if (idx != null) {
          targetItem = s.flow!.bars[idx].item;
        }
    }
    if (targetItem != null &&
        targetItem.kind == MapItemKind.folder &&
        targetItem.id >= 0 &&
        catalog.childrenOfIndex(targetItem.id).isNotEmpty) {
      goTo(targetItem.id);
    }
  }

  @override
  void dispose() {
    pointer.dispose();
    canvasTick.dispose();
    super.dispose();
  }
}

class StrataRootView extends StatefulWidget {
  const StrataRootView({
    super.key,
    this.controller,
    this.backend = const SampleDiskBackend(),
  });

  final StrataController? controller;
  final DiskBackend backend;

  @override
  State<StrataRootView> createState() => _StrataRootViewState();
}

class _StrataRootViewState extends State<StrataRootView> {
  late final StrataController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? StrataController(backend: widget.backend);
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _controller.goUp,
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final theme = _controller.theme;
            return Material(
              color: theme.background.color,
              child: DefaultTextStyle(
                style: TextStyle(
                  color: theme.text.color,
                  fontFamily: 'Segoe UI',
                ),
                child: Stack(
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 340,
                          child: _SidePanel(controller: _controller),
                        ),
                        Expanded(child: _MapArea(controller: _controller)),
                      ],
                    ),
                    if (_controller.diskMenuOpen) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => _controller.setDiskMenuOpen(false),
                        ),
                      ),
                      Positioned(
                        left: 22,
                        top: 78,
                        child: _DiskPickerOverlay(controller: _controller),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    final theme = controller.theme;
    final catalog = controller.catalog;
    final atTop = controller.focus == FileTree.root;
    final items = catalog
        .itemsIn(controller.focus)
        .where((e) => e.kind != MapItemKind.free)
        .take(9)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 16, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (atTop)
            _DiskHeader(
              controller: controller,
              catalog: catalog,
              theme: theme,
            )
          else
            _FolderHeader(
              controller: controller,
              catalog: catalog,
              theme: theme,
            ),
          const SizedBox(height: 26),
          Text(
            atTop ? '最大的' : '里面最大的',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: theme.secondaryText.color,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => Container(
                height: 1,
                color: theme.line.color.withValues(alpha: 0.1),
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final tone =
                    controller.scene?.toneOfTopItem(item.id) ??
                    const Tone.neutral();
                final swatch = theme.fill(tone).color;
                final isOn = controller.highlighted == item.id;
                return MouseRegion(
                  onEnter: (_) => controller.highlightFromList(item.id),
                  onExit: (_) => controller.highlightFromList(null),
                  cursor: item.kind == MapItemKind.folder && item.id >= 0
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: () {
                      if (item.kind == MapItemKind.folder && item.id >= 0) {
                        controller.goTo(item.id);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: theme.line.color.withValues(
                          alpha: isOn ? 0.09 : 0.0,
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: swatch,
                              borderRadius: BorderRadius.circular(3.5),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            Format.size(item.size),
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.secondaryText.color,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (controller.scanning)
                Text(
                  '正在扫描磁盘…',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.secondaryText.color,
                  ),
                )
              else ...[
                Text(
                  '${controller.backend.supportsSystemActions ? "已扫描" : "预览数据"} · ${Format.count(catalog.tree.entryCount)} 项',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.secondaryText.color,
                  ),
                ),
                if (controller.backend.supportsSystemActions) ...[
                  const SizedBox(width: 10),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: controller.rescan,
                      child: Text(
                        '重新扫描',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.secondaryText.color,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DiskHeader extends StatelessWidget {
  const _DiskHeader({
    required this.controller,
    required this.catalog,
    required this.theme,
  });

  final StrataController controller;
  final MapCatalog catalog;
  final StrataTheme theme;

  @override
  Widget build(BuildContext context) {
    final files = catalog.tree.nodes[FileTree.root].size;
    final hidden = catalog.hiddenBytes;
    final free = catalog.volume?.availableBytes ?? 0;
    final solid = theme.tones[2].color;
    final muted = theme.hidden.lighter(theme.isDark ? 0.07 : -0.08).color;
    final canPick = controller.volumes.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: canPick ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: canPick
                ? () => controller.setDiskMenuOpen(!controller.diskMenuOpen)
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    catalog.volume?.name ?? catalog.tree.rootPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (canPick) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: theme.secondaryText.color,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _CapacityBar(
          parts: [(files, solid), (hidden, muted), (free, null)],
          outline: theme.line.color.withValues(alpha: 0.42),
        ),
        const SizedBox(height: 13),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Figure(
                label: '文件',
                value: Format.size(files),
                swatch: solid,
                theme: theme,
              ),
            ),
            Expanded(
              child: _Figure(
                label: '系统与保留',
                value: Format.size(hidden),
                swatch: muted,
                theme: theme,
              ),
            ),
            Expanded(
              child: _Figure(
                label: '可用',
                value: Format.size(free),
                swatch: null,
                theme: theme,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    required this.controller,
    required this.catalog,
    required this.theme,
  });

  final StrataController controller;
  final MapCatalog catalog;
  final StrataTheme theme;

  @override
  Widget build(BuildContext context) {
    final crumbs = catalog.crumbsTo(controller.focus);
    final node = catalog.tree.nodes[controller.focus];
    final total = math.max(catalog.totalBytes, 1);
    final solid = theme.tones[2].color;
    final parents = crumbs.length > 1
        ? crumbs.sublist(math.max(0, crumbs.length - 4), crumbs.length - 1)
        : const <Crumb>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final c in parents) ...[
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => controller.goTo(c.index),
                  child: Text(
                    c.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.secondaryText.color,
                    ),
                  ),
                ),
              ),
              Text(
                '›',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.secondaryText.color,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          crumbs.isNotEmpty ? crumbs.last.name : '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 18),
        _CapacityBar(
          parts: [(node.size, solid), (math.max(0, total - node.size), null)],
          outline: theme.line.color.withValues(alpha: 0.42),
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            Expanded(
              child: _Figure(
                label: '大小',
                value: Format.size(node.size),
                swatch: solid,
                theme: theme,
              ),
            ),
            Expanded(
              child: _Figure(
                label: '占整块磁盘',
                value: Format.percent(node.size / total),
                swatch: null,
                theme: theme,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.parts, required this.outline});

  final List<(int, Color?)> parts;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    final total = math.max(parts.fold<int>(0, (s, p) => s + p.$1), 1);
    return Container(
      height: 10,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: outline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (final (bytes, color) in parts)
            if (bytes > 0)
              Expanded(
                flex: math.max(1, ((bytes / total) * 1000).round()),
                child: Container(color: color ?? Colors.transparent),
              ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.swatch,
    required this.theme,
  });

  final String label;
  final String value;
  final Color? swatch;
  final StrataTheme theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: swatch ?? Colors.transparent,
                borderRadius: BorderRadius.circular(2),
                border: swatch == null
                    ? Border.all(
                        color: theme.line.color.withValues(alpha: 0.55),
                        width: 1,
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: theme.secondaryText.color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _MapArea extends StatelessWidget {
  const _MapArea({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    final theme = controller.theme;
    final crumbs = controller.catalog.crumbsTo(controller.focus);
    final parentName = controller.focus != FileTree.root && crumbs.length > 1
        ? crumbs[crumbs.length - 2].name
        : null;

    return Column(
      children: [
        SizedBox(
          height: 54,
          child: Padding(
            padding: const EdgeInsets.only(left: 6, right: 22),
            child: Row(
              children: [
                if (parentName != null)
                  _BackPill(
                    label: parentName,
                    theme: theme,
                    onTap: controller.goUp,
                  ),
                const Spacer(),
                _ModeSwitch(controller: controller),
                const SizedBox(width: 16),
                _ThemeDots(controller: controller),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 22, 22),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _MapCanvas(controller: controller),
                _HoverCardOverlay(controller: controller),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BackPill extends StatelessWidget {
  const _BackPill({
    required this.label,
    required this.theme,
    required this.onTap,
  });

  final String label;
  final StrataTheme theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 15, 7),
          decoration: BoxDecoration(
            color: theme.line.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chevron_left,
                size: 16,
                color: theme.secondaryText.color,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: theme.text.color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    final theme = controller.theme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.line.color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in MapMode.values)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => controller.mode = mode,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: theme.line.color.withValues(
                      alpha: controller.mode == mode ? 0.14 : 0.0,
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    mode == MapMode.bubbles ? '气泡' : '流动',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: controller.mode == mode
                          ? theme.text.color
                          : theme.secondaryText.color,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeDots extends StatelessWidget {
  const _ThemeDots({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in StrataTheme.all) ...[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => controller.theme = t,
              child: Tooltip(
                message: t.name,
                child: Container(
                  width: 21,
                  height: 21,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: controller.theme.text.color.withValues(
                        alpha: controller.theme.id == t.id ? 0.9 : 0.0,
                      ),
                      width: 1.5,
                    ),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [t.tones[0].color, t.tones[1].color],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (t != StrataTheme.all.last) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _MapCanvas extends StatefulWidget {
  const _MapCanvas({required this.controller});

  final StrataController controller;

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<_MapCanvas>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final nowSec = DateTime.now().microsecondsSinceEpoch / 1e6;
      final moving = widget.controller.motion.advance(nowSec);
      widget.controller.motion.takeFinished();
      widget.controller.canvasTick.value++;
      if (!moving && _ticker.isActive) {
        _ticker.stop();
      }
    });
    widget.controller.onRequestAnimate = () {
      if (mounted && !_ticker.isActive) {
        _ticker.start();
      }
    };
  }

  @override
  void dispose() {
    widget.controller.onRequestAnimate = null;
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.controller.setMapSize(size);
        });
        return MouseRegion(
          onHover: (e) => widget.controller.pointerMoved(e.localPosition),
          onExit: (_) => widget.controller.pointerMoved(null),
          child: GestureDetector(
            onTapUp: (e) => widget.controller.clickedAt(e.localPosition),
            onSecondaryTapUp: (e) => _showContextMenu(context, e),
            child: RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: _StrataPainter(controller: widget.controller),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    TapUpDetails details,
  ) async {
    if (!widget.controller.backend.supportsSystemActions) return;
    final item = widget.controller.hitItemAt(details.localPosition);
    if (item == null || !item.isEntry) return;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: const [
        PopupMenuItem(value: 'reveal', child: Text('在资源管理器中显示')),
        PopupMenuItem(value: 'trash', child: Text('移到回收站…')),
      ],
    );
    if (!context.mounted) return;
    if (action == 'reveal') {
      await widget.controller.revealItem(item);
    } else if (action == 'trash') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('移到回收站？'),
          content: Text('确定将“${item.title}”（${Format.size(item.size)}）移到回收站吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('移到回收站'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await widget.controller.trashItem(item);
      }
    }
  }
}

class _DiskPickerOverlay extends StatelessWidget {
  const _DiskPickerOverlay({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    final theme = controller.theme;
    return Container(
      width: 300,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: theme.background.lighter(theme.isDark ? 0.06 : 0.035).color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.line.color.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: theme.isDark ? 0.4 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final vol in controller.volumes)
            _DiskPickerRow(
              volume: vol,
              isCurrent:
                  controller.selectedVolume?.mountPoint == vol.mountPoint,
              theme: theme,
              onTap: () => controller.selectVolume(vol),
            ),
        ],
      ),
    );
  }
}

class _DiskPickerRow extends StatefulWidget {
  const _DiskPickerRow({
    required this.volume,
    required this.isCurrent,
    required this.theme,
    required this.onTap,
  });

  final DiskVolume volume;
  final bool isCurrent;
  final StrataTheme theme;
  final VoidCallback onTap;

  @override
  State<_DiskPickerRow> createState() => _DiskPickerRowState();
}

class _DiskPickerRowState extends State<_DiskPickerRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.volume.totalBytes;
    final avail = widget.volume.availableBytes;
    final used = math.max(0, total - avail);
    final share = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final theme = widget.theme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: theme.line.color.withValues(alpha: _hovering ? 0.09 : 0.0),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: widget.isCurrent
                    ? Icon(Icons.check, size: 13, color: theme.text.color)
                    : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.volume.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '可用 ${Format.size(avail)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.secondaryText.color,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 5,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: theme.line.color.withValues(alpha: 0.32),
                          width: 0.8,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: share,
                        child: Container(color: theme.tones[2].color),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StrataPainter extends CustomPainter {
  _StrataPainter({required this.controller})
    : super(repaint: controller.canvasTick);

  final StrataController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = controller.scene;
    if (scene == null) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final motion = controller.motion;
    final theme = controller.theme;
    final live = MapFrame(
      theme: theme,
      lift: motion.lift,
      appear: motion.appear,
    );

    final transition = motion.transition;
    if (transition != null) {
      switch (transition.kind) {
        case MapTransitionKind.morph:
          if (transition.morph != null) {
            transition.morph!.draw(
              progress: transition.progress(motion.nowSeconds),
              theme: theme,
              lifts: transition.lifts,
              flowFocus: transition.flowFocus,
              canvas: canvas,
            );
            canvas.restore();
            return;
          }
        case MapTransitionKind.swap:
          if (transition.previous != null) {
            final elapsed = motion.nowSeconds - transition.startSeconds;
            MapRenderer.drawScene(
              transition.previous!,
              frame: MapFrame.leaving(theme, elapsed),
              flowFocus: null,
              canvas: canvas,
            );
          }
        case MapTransitionKind.none:
        case MapTransitionKind.popIn:
          break;
      }
    }

    MapRenderer.drawScene(
      scene,
      frame: live,
      flowFocus: controller.flowFocus,
      canvas: canvas,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StrataPainter oldDelegate) => false;
}

class _HoverCardOverlay extends StatelessWidget {
  const _HoverCardOverlay({required this.controller});

  final StrataController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PointerState>(
      valueListenable: controller.pointer,
      builder: (context, state, _) {
        final info = state.info;
        final location = state.location;
        if (info == null || location == null) {
          return const SizedBox.shrink();
        }
        final bounds = controller.mapSize;
        const width = 250.0;
        final x = location.dx + 18 + width > bounds.width
            ? location.dx - 18 - width
            : location.dx + 18;
        final y = math.min(
          math.max(location.dy + 14, 0.0),
          math.max(0.0, bounds.height - 86),
        );
        final theme = controller.theme;
        return Positioned(
          left: x,
          top: y,
          child: IgnorePointer(
            child: Container(
              width: width,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: theme.background
                    .lighter(theme.isDark ? 0.07 : 0.04)
                    .color,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: theme.line.color.withValues(alpha: 0.18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: theme.isDark ? 0.35 : 0.12,
                    ),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${info.size} · ${info.share}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (info.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      info.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.secondaryText.color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
