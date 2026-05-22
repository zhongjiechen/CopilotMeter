#!/usr/bin/env bash
# Generates the macOS .app / DMG icon from docs/copilotmeter.png:
# composes the coloured helmet illustration on top of a complementary
# blue gradient squircle (Big Sur+ conventions) and packages it into
# Resources/AppIcon.icns.
#
# (The menu-bar glyph is an SF Symbol — `chart.bar.fill` / `chart.bar`,
# wired in App.swift — so no separate template image is generated here.)
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

echo "==> Done"
ls -la "$OUT_DIR/AppIcon.icns"
