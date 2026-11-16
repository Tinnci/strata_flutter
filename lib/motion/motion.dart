import 'dart:math' as math;

/// A damped spring on one number, tuned to overshoot a little so marks feel
/// like jelly.
class Spring {
  Spring({this.value = 0.0, this.velocity = 0.0});

  double value;
  double velocity;

  static const double stiffness = 300.0;
  static const double damping = 13.0;

  void step(double target, double dt) {
    var remaining = math.min(dt, 0.1);
    while (remaining > 0) {
      final h = math.min(remaining, 1.0 / 240.0);
      final force = stiffness * (target - value) - damping * velocity;
      velocity += force * h;
      value += velocity * h;
      remaining -= h;
    }
  }

  bool isResting(double target) {
    return (value - target).abs() < 0.002 && velocity.abs() < 0.02;
  }

  /// The same spring released from 0 towards 1, as a function of time (seconds).
  static double response(double time) {
    if (time <= 0) return 0.0;
    final omega = math.sqrt(stiffness);
    final zeta = damping / (2.0 * omega);
    final damped = omega * math.sqrt(1.0 - zeta * zeta);
    return 1.0 -
        math.exp(-zeta * omega * time) *
            (math.cos(damped * time) +
                zeta * omega / damped * math.sin(damped * time));
  }
}
