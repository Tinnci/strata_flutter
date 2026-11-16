# Strata Flutter

A cross-platform (Windows / macOS / Linux) disk space visualizer built with **Flutter + Rust (`flutter_rust_bridge`)**, ported from and inspired by [Glimmer-X/Strata](https://github.com/Glimmer-X/Strata).

## Upstream & Attribution

This project is a cross-platform port of **[Glimmer-X/Strata](https://github.com/Glimmer-X/Strata)** (MIT License, Copyright (c) 2026 Glimmer-X).

Ported / adapted from the original Swift/macOS project:
- **Layout algorithms**: Voronoi Treemap (`BubbleLayout` via Power Diagrams + Lloyd relaxation) and `FlowLayout` (layered bars + Bézier ribbons)
- **Color system**: Perceptual OKLCH color space (`OKColor`, `Tone`) and the 4 single-hue-family themes (`深海` / `霜` / `苔原` / `暮色`)
- **Motion & transitions**: Damped spring physics (`Spring`), hover swelling & child push-apart, and `Morph` camera zoom transitions
- **App icon**: Derived from `docs/images/icon.png` in `Glimmer-X/Strata`

## Architecture

- **`lib/`** (Flutter / Dart):
  - `layout/` — `Geometry`, `Squarify`, `BubbleLayout`, `FlowLayout`
  - `theme/` — OKLCH palette & themes
  - `scene/` & `render/` — `BubbleScene` (smooth quadratic Bézier contours), `FlowScene`, `MapRenderer`
  - `motion/` — `Spring`, `MotionState`, `Morph`
  - `ui/` — `StrataRootView`, `PebbleLoader` & `StrataLoadingView`, `DiskPicker`
- **`rust/`** (Rust + `flutter_rust_bridge`):
  - Native volume enumeration (`list_volumes`), streaming directory scanning (`scan_directory_stream` using `FindFirstFileExW` on Windows), Explorer/Finder reveal (`reveal_in_explorer`), and Recycle Bin / Trash (`move_to_trash`).

## Development

```bash
# Run tests
flutter test

# Run on Windows
flutter run -d windows
```

Regenerating Rust/Dart FFI bindings after editing `rust/src/api/`:

```bash
flutter_rust_bridge_codegen generate
```

## License

[MIT](LICENSE)
