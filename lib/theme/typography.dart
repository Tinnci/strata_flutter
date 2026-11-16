import 'dart:io' show Platform;
import 'dart:ui' show Locale;

/// Cross-platform CJK & Latin typography configuration shared by both Flutter
/// widgets and Canvas [TextPainter] labels.
abstract final class StrataTypography {
  static String? get primaryFontFamily {
    if (Platform.isWindows) return 'Segoe UI';
    if (Platform.isMacOS) return '.AppleSystemUIFont';
    return null;
  }

  static List<String> fallbackFor(Locale? locale) {
    final lang = locale?.languageCode ?? 'zh';
    if (Platform.isWindows) {
      return switch (lang) {
        'ja' => const ['Yu Gothic UI', 'Meiryo', 'Microsoft YaHei UI', 'Segoe UI Emoji'],
        'ko' => const ['Malgun Gothic', 'Microsoft YaHei UI', 'Segoe UI Emoji'],
        _ => const ['Microsoft YaHei UI', 'Microsoft JhengHei UI', 'Yu Gothic UI', 'Segoe UI Emoji'],
      };
    }
    if (Platform.isMacOS) {
      return switch (lang) {
        'ja' => const ['Hiragino Sans', 'PingFang SC', 'Apple Color Emoji'],
        'ko' => const ['AppleSDGothicNeo', 'PingFang SC', 'Apple Color Emoji'],
        _ => const ['PingFang SC', 'PingFang TC', 'Hiragino Sans', 'Apple Color Emoji'],
      };
    }
    return switch (lang) {
      'ja' => const ['Noto Sans CJK JP', 'Noto Sans CJK SC', 'Noto Color Emoji'],
      'ko' => const ['Noto Sans CJK KR', 'Noto Sans CJK SC', 'Noto Color Emoji'],
      _ => const ['Noto Sans CJK SC', 'Noto Sans CJK TC', 'Noto Sans', 'Noto Color Emoji'],
    };
  }
}
