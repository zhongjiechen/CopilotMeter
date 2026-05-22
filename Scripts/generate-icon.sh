#!/usr/bin/env bash
# Generates two assets from docs/copilotmeter.png:
#
#   1. Resources/AppIcon.icns        — the macOS .app / DMG icon. Composes the
#      coloured helmet illustration on top of a complementary blue gradient
#      squircle (matches Big Sur+ icon conventions) and packages it.
#
#   2. Resources/MenuBarIcon.png     — a 22pt monochrome template image used
#      by SwiftUI as the menu-bar glyph. Rendered with .template so macOS
#      tints it correctly in light/dark mode. Bundled as @1x/@2x/@3x.
#
# Requires: rsvg-convert, magick (ImageMagick), iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Resources"
TMP_DIR="$ROOT/.build/icon-tmp"
ICONSET="$TMP_DIR/AppIcon.iconset"
LOGO_SRC="$ROOT/docs/copilotmeter.png"

mkdir -p "$ICONSET" "$TMP_DIR"
rm -rf "$ICONSET"/*

if [[ ! -f "$LOGO_SRC" ]]; then
    echo "error: $LOGO_SRC not found" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. App icon — colored squircle + helmet artwork
# ---------------------------------------------------------------------------

SVG_FILE="$TMP_DIR/app-icon.svg"
MASTER="$TMP_DIR/icon-1024.png"

# Stage the logo PNG with transparent margins so it sits comfortably inside
# the safe area (about 80% of the canvas). We also fuzz-remove the near-white
# studio background so the helmet sits directly on the blue squircle instead
# of looking like a white sticker.
STAGED_LOGO="$TMP_DIR/logo-square.png"
magick "$LOGO_SRC" \
    -background none \
    -alpha set \
    -fuzz 8% -fill none -draw 'color 0,0 floodfill' \
    -channel A -blur 0x1 +channel \
    -trim +repage \
    -resize 760x760 \
    -gravity center -extent 824x824 \
    "$STAGED_LOGO"

cat > "$SVG_FILE" <<SVG
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <!-- Background gradient that picks up the helmet's blue palette -->
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%"  stop-color="#A6D5FF"/>
      <stop offset="50%" stop-color="#6FB8FF"/>
      <stop offset="100%" stop-color="#3F8FE9"/>
    </linearGradient>
    <!-- Top gloss for that macOS Big Sur feel -->
    <linearGradient id="gloss" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%"  stop-color="rgba(255,255,255,0.40)"/>
      <stop offset="55%" stop-color="rgba(255,255,255,0.0)"/>
    </linearGradient>
    <!-- macOS squircle (corner radius ≈ 22% of size) -->
    <clipPath id="squircle">
      <rect x="100" y="100" width="824" height="824" rx="184" ry="184"/>
    </clipPath>
    <!-- Soft drop shadow under the helmet artwork -->
    <filter id="logoShadow" x="-10%" y="-10%" width="120%" height="130%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
      <feOffset dy="8"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
      <feComposite in2="SourceGraphic" operator="over"/>
    </filter>
  </defs>

  <g clip-path="url(#squircle)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
    <rect x="100" y="100" width="824" height="440" fill="url(#gloss)"/>
    <!-- Faint diagonal sheen -->
    <path d="M 100 720 L 924 380" stroke="rgba(255,255,255,0.10)"
          stroke-width="130" fill="none"/>
    <!-- Helmet artwork (the user-provided logo) -->
    <image x="100" y="100" width="824" height="824"
           xlink:href="$STAGED_LOGO"
           filter="url(#logoShadow)"
           preserveAspectRatio="xMidYMid meet"/>
  </g>
</svg>
SVG

echo "==> Rendering 1024x1024 master from SVG"
rsvg-convert -w 1024 -h 1024 "$SVG_FILE" -o "$MASTER"
file "$MASTER"

echo "==> Generating iconset sizes"
declare -a SIZES=(16 32 128 256 512)
for sz in "${SIZES[@]}"; do
    magick "$MASTER" -resize "${sz}x${sz}" "$ICONSET/icon_${sz}x${sz}.png"
    dbl=$((sz * 2))
    magick "$MASTER" -resize "${dbl}x${dbl}" "$ICONSET/icon_${sz}x${sz}@2x.png"
done

echo "==> Building Resources/AppIcon.icns"
iconutil --convert icns "$ICONSET" --output "$OUT_DIR/AppIcon.icns"

# ---------------------------------------------------------------------------
# 2. Menu bar icon — monochrome template
# ---------------------------------------------------------------------------
#
# Drawn as a tight silhouette of the helmet at @1x = 18x18, then exported at
# @2x = 36x36 and @3x = 54x54. We render solid black on transparent; macOS
# tints it via the .template rendering mode in SwiftUI.

MB_SVG="$TMP_DIR/menubar.svg"
cat > "$MB_SVG" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Menu-bar template (64×64 viewBox, exported at 18/36/54 px).

  Rules for menu-bar template images on macOS:
    * Anything non-transparent = ink. macOS only honours the alpha channel.
    * To create a "hole" in a shape you MUST use either fill-rule=evenodd
      compound paths or a mask — using fill=#fff on top does NOT work.
    * At 18 px, only large, well-separated forms are legible. We rely on:
        - helmet body (outer outline silhouette)
        - eye-shaped visor (cut OUT, not painted over)
        - antenna line + dot
        - 3 chart bars rendered INSIDE the visor cutout
-->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <!-- Helmet + ears, with visor cut-out (fill-rule evenodd). -->
  <path fill="#000" fill-rule="evenodd"
        d="
        M 14 24
        C 14 14, 22 10, 32 10
        C 42 10, 50 14, 50 24
        L 50 42
        C 50 50, 42 54, 32 54
        C 22 54, 14 50, 14 42
        Z

        M 17 16  L 12 9  L 23 13  Z

        M 47 16  L 52 9  L 41 13  Z

        M 21 26
        h 22
        a 4 4 0 0 1 4 4
        v 10
        a 4 4 0 0 1 -4 4
        h -22
        a 4 4 0 0 1 -4 -4
        v -10
        a 4 4 0 0 1 4 -4
        Z
        "/>

  <!-- Antenna -->
  <rect x="31" y="2" width="2" height="9" rx="1" ry="1" fill="#000"/>
  <circle cx="32" cy="3" r="2.4" fill="#000"/>

  <!-- Three little bars inside the (now transparent) visor cutout. -->
  <rect x="24" y="38"  width="3" height="4"  rx="0.8" fill="#000"/>
  <rect x="30" y="35"  width="3" height="7"  rx="0.8" fill="#000"/>
  <rect x="36" y="32"  width="3" height="10" rx="0.8" fill="#000"/>
</svg>
SVG

# We export at the three Retina sizes typical for menu bar icons (18 / 36 / 54)
# and copy them into Resources/ where the .app bundle picker will find them.
echo "==> Rendering menu-bar template at 18 / 36 / 54 px"
rsvg-convert -w 18 -h 18 "$MB_SVG" -o "$OUT_DIR/MenuBarIcon.png"
rsvg-convert -w 36 -h 36 "$MB_SVG" -o "$OUT_DIR/MenuBarIcon@2x.png"
rsvg-convert -w 54 -h 54 "$MB_SVG" -o "$OUT_DIR/MenuBarIcon@3x.png"

echo "==> Done"
ls -la "$OUT_DIR/AppIcon.icns" "$OUT_DIR/MenuBarIcon"*.png
