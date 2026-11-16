import '../scene/map_scene.dart';
import 'morph.dart';
import 'motion.dart';

enum MapTransitionKind { none, popIn, swap, morph }

abstract final class SwapTiming {
  static const double duration = 0.46;
  static const double arrival = 0.20;

  static double leaving(int order, double elapsed) {
    final start = (order < 30 ? order : 30) * 0.007;
    final t = ((elapsed - start) / 0.25).clamp(0.0, 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
  }
}

class ActiveTransition {
  ActiveTransition({
    required this.kind,
    required this.startSeconds,
    this.previous,
    this.morph,
    this.lifts = const {},
    this.flowFocus,
  });

  final MapTransitionKind kind;
  final double startSeconds;
  final MapScene? previous;
  final Morph? morph;
  final Map<int, double> lifts;
  final int? flowFocus;

  double get duration => switch (kind) {
    MapTransitionKind.swap => SwapTiming.duration,
    MapTransitionKind.morph => morph?.duration ?? 0.5,
    _ => 0.0,
  };

  double progress(double nowSeconds) {
    final d = duration;
    if (d <= 0) return 1.0;
    final t = ((nowSeconds - startSeconds) / d).clamp(0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
  }

  bool isOver(double nowSeconds) => nowSeconds - startSeconds >= duration;
}

/// Holds animated spring lifts per mark and transition timelines outside Flutter's
/// widget tree so 60/120fps canvas frames never trigger widget rebuilds.
class MotionState {
  final Map<int, Spring> _lifts = {};
  double? _lastTickSeconds;
  Set<int> targets = {};
  double _appearStartSeconds = -1000.0;
  double nowSeconds = 0.0;
  ActiveTransition? transition;
  bool _finished = false;

  double lift(int id) => _lifts[id]?.value ?? 0.0;

  double appear(int order) {
    final delay = (order < 30 ? order : 30) * 0.022;
    return Spring.response(nowSeconds - _appearStartSeconds - delay);
  }

  void begin(
    MapTransitionKind kind, {
    MapScene? previous,
    Morph? morph,
    int? flowFocus,
    required double atSeconds,
  }) {
    final leavingLifts = _lifts.map((k, v) => MapEntry(k, v.value));
    _lifts.clear();
    targets = {};
    _lastTickSeconds = null;
    nowSeconds = atSeconds;
    switch (kind) {
      case MapTransitionKind.popIn:
        _appearStartSeconds = atSeconds;
        transition = null;
      case MapTransitionKind.none:
        _appearStartSeconds = -1000.0;
        transition = null;
      case MapTransitionKind.swap:
        _appearStartSeconds =
            atSeconds + (previous == null ? 0.0 : SwapTiming.arrival);
        transition = previous != null
            ? ActiveTransition(
                kind: kind,
                startSeconds: atSeconds,
                previous: previous,
              )
            : null;
      case MapTransitionKind.morph:
        _appearStartSeconds = -1000.0;
        transition = morph != null
            ? ActiveTransition(
                kind: kind,
                startSeconds: atSeconds,
                morph: morph,
                lifts: leavingLifts,
                flowFocus: flowFocus,
              )
            : null;
    }
  }

  bool takeFinished() {
    final was = _finished;
    _finished = false;
    return was;
  }

  bool advance(double toSeconds) {
    final dt = _lastTickSeconds != null ? (toSeconds - _lastTickSeconds!) : 0.0;
    _lastTickSeconds = toSeconds;
    nowSeconds = toSeconds;

    for (final id in targets) {
      _lifts.putIfAbsent(id, () => Spring());
    }

    var moving = (toSeconds - _appearStartSeconds) < 1.6;
    final currentTransition = transition;
    if (currentTransition != null) {
      if (currentTransition.isOver(toSeconds)) {
        transition = null;
        _finished = true;
      } else {
        moving = true;
      }
    }

    for (final id in _lifts.keys.toList(growable: false)) {
      final target = targets.contains(id) ? 1.0 : 0.0;
      final spring = _lifts[id]!;
      spring.step(target, dt);
      if (spring.isResting(target)) {
        if (target == 0.0) {
          _lifts.remove(id);
        } else {
          spring.value = 1.0;
          spring.velocity = 0.0;
        }
      } else {
        moving = true;
      }
    }

    if (!moving) _lastTickSeconds = null;
    return moving;
  }
}
