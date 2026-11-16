import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A colour in OKLCH: lightness 0...1, chroma, hue in degrees.
/// Working in this space keeps steps of lightness even to the eye, which is what
/// lets one hue family carry a whole map.
class OKColor {
  const OKColor(this.l, this.c, this.h);

  final double l;
  final double c;
  final double h;

  OKColor lighter(double amount) {
    return OKColor((l + amount).clamp(0.05, 0.98), c, h);
  }

  Color get color {
    final radians = h * math.pi / 180.0;
    final a = c * math.cos(radians);
    final b = c * math.sin(radians);

    final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = l - 0.0894841775 * a - 1.2914855480 * b;

    final l3 = l_ * l_ * l_;
    final m3 = m_ * m_ * m_;
    final s3 = s_ * s_ * s_;

    int encode(double linear) {
      final v = linear.clamp(0.0, 1.0);
      final srgb = v <= 0.0031308
          ? 12.92 * v
          : 1.055 * math.pow(v, 1.0 / 2.4) - 0.055;
      return (srgb * 255.0).round().clamp(0, 255);
    }

    return Color.fromARGB(
      255,
      encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
      encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
      encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OKColor && other.l == l && other.c == c && other.h == h;

  @override
  int get hashCode => Object.hash(l, c, h);
}

enum ToneRole { family, neutral, hidden, free }

/// Which colour a mark gets, independent of the theme: a slot of the theme's
/// family plus a small shift.
class Tone {
  const Tone({
    required this.role,
    this.familyIndex = 0,
    this.lightness = 0.0,
    this.hue = 0.0,
    this.chroma = 1.0,
  });

  const Tone.family(int index, {double lightness = 0, double hue = 0, double chroma = 1})
      : this(
          role: ToneRole.family,
          familyIndex: index,
          lightness: lightness,
          hue: hue,
          chroma: chroma,
        );

  const Tone.neutral() : this(role: ToneRole.neutral);
  const Tone.hidden() : this(role: ToneRole.hidden);
  const Tone.free() : this(role: ToneRole.free);

  final ToneRole role;
  final int familyIndex;
  final double lightness;
  final double hue;
  final double chroma;

  Tone shifted({double lightness = 0, double hue = 0, double chroma = 1}) {
    return Tone(
      role: role,
      familyIndex: familyIndex,
      lightness: this.lightness + lightness,
      hue: this.hue + hue,
      chroma: this.chroma * chroma,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Tone &&
      other.role == role &&
      other.familyIndex == familyIndex &&
      other.lightness == lightness &&
      other.hue == hue &&
      other.chroma == chroma;

  @override
  int get hashCode => Object.hash(role, familyIndex, lightness, hue, chroma);
}

/// One colour scheme. Every theme is a single family: neighbouring hues at
/// different depths of light, plus one accent used for highlights.
class StrataTheme {
  const StrataTheme({
    required this.id,
    required this.name,
    required this.isDark,
    required this.background,
    required this.tones,
    required this.neutral,
    required this.hidden,
    required this.accent,
    required this.text,
    required this.secondaryText,
  });

  final String id;
  final String name;
  final bool isDark;
  final OKColor background;
  final List<OKColor> tones;
  final OKColor neutral;
  final OKColor hidden;
  final OKColor accent;
  final OKColor text;
  final OKColor secondaryText;

  OKColor fill(Tone tone) {
    final OKColor base = switch (tone.role) {
      ToneRole.family => tones[tone.familyIndex % tones.length],
      ToneRole.neutral => neutral,
      ToneRole.hidden => hidden,
      ToneRole.free => background,
    };
    return OKColor(
      (base.l + tone.lightness).clamp(0.08, 0.96),
      base.c * tone.chroma,
      base.h + tone.hue,
    );
  }

  /// The colour of a folder's own body, seen as the thin wall between cells.
  OKColor wall(Tone tone) {
    final base = fill(tone);
    return OKColor(
      base.l + (isDark ? -0.075 : -0.07),
      base.c * 0.9,
      base.h,
    );
  }

  /// Text colour that reads on a fill.
  OKColor ink(OKColor fill) {
    return fill.l > 0.63
        ? OKColor(0.2, math.min(fill.c, 0.03), fill.h)
        : OKColor(0.97, 0.01, fill.h);
  }

  OKColor get line => isDark ? text : secondaryText;

  static const abyss = StrataTheme(
    id: 'abyss',
    name: '深海',
    isDark: true,
    background: OKColor(0.215, 0.035, 252),
    tones: [
      OKColor(0.70, 0.062, 238),
      OKColor(0.45, 0.085, 254),
      OKColor(0.58, 0.075, 245),
      OKColor(0.36, 0.070, 258),
      OKColor(0.79, 0.042, 232),
      OKColor(0.52, 0.055, 222),
    ],
    neutral: OKColor(0.33, 0.030, 252),
    hidden: OKColor(0.285, 0.028, 252),
    accent: OKColor(0.91, 0.035, 80),
    text: OKColor(0.95, 0.012, 240),
    secondaryText: OKColor(0.72, 0.03, 245),
  );

  static const frost = StrataTheme(
    id: 'frost',
    name: '霜',
    isDark: false,
    background: OKColor(0.957, 0.008, 235),
    tones: [
      OKColor(0.43, 0.072, 246),
      OKColor(0.67, 0.055, 226),
      OKColor(0.53, 0.075, 236),
      OKColor(0.79, 0.040, 216),
      OKColor(0.36, 0.062, 256),
      OKColor(0.61, 0.050, 202),
    ],
    neutral: OKColor(0.875, 0.012, 235),
    hidden: OKColor(0.835, 0.014, 235),
    accent: OKColor(0.60, 0.15, 40),
    text: OKColor(0.24, 0.020, 250),
    secondaryText: OKColor(0.48, 0.020, 245),
  );

  static const moss = StrataTheme(
    id: 'moss',
    name: '苔原',
    isDark: true,
    background: OKColor(0.215, 0.020, 165),
    tones: [
      OKColor(0.71, 0.062, 150),
      OKColor(0.45, 0.062, 168),
      OKColor(0.58, 0.070, 142),
      OKColor(0.36, 0.048, 174),
      OKColor(0.80, 0.048, 132),
      OKColor(0.52, 0.042, 188),
    ],
    neutral: OKColor(0.33, 0.020, 165),
    hidden: OKColor(0.285, 0.018, 165),
    accent: OKColor(0.92, 0.055, 100),
    text: OKColor(0.95, 0.012, 150),
    secondaryText: OKColor(0.72, 0.025, 155),
  );

  static const dusk = StrataTheme(
    id: 'dusk',
    name: '暮色',
    isDark: true,
    background: OKColor(0.215, 0.022, 30),
    tones: [
      OKColor(0.71, 0.085, 48),
      OKColor(0.46, 0.090, 28),
      OKColor(0.59, 0.095, 60),
      OKColor(0.37, 0.065, 18),
      OKColor(0.80, 0.060, 76),
      OKColor(0.53, 0.060, 5),
    ],
    neutral: OKColor(0.33, 0.022, 30),
    hidden: OKColor(0.285, 0.020, 30),
    accent: OKColor(0.93, 0.030, 95),
    text: OKColor(0.95, 0.012, 60),
    secondaryText: OKColor(0.73, 0.028, 50),
  );

  static const List<StrataTheme> all = [abyss, frost, moss, dusk];

  static StrataTheme named(String id) {
    return all.firstWhere((t) => t.id == id, orElse: () => abyss);
  }
}
