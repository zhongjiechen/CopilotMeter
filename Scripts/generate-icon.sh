#!/usr/bin/env bash
# Generate CopilotMeter app icon by rendering an SVG with rsvg/magick, then
# packaging the result as an .icns via iconutil.
#
# Design:
#   - 1024x1024 master, ~10% safe padding inside macOS squircle
#   - Linear gradient teal -> indigo, 135° angle
#   - Three ascending white bars (today / week / month motif) with subtle inner shadow
#   - Orange accent dot at the tip of the tallest bar
#   - Soft top highlight for depth
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Resources"
TMP_DIR="$ROOT/.build/icon-tmp"
ICONSET="$TMP_DIR/AppIcon.iconset"

mkdir -p "$ICONSET"
rm -rf "$ICONSET"/*

SVG_FILE="$TMP_DIR/icon.svg"
MASTER="$TMP_DIR/icon-1024.png"

cat > "$SVG_FILE" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <!-- Diagonal teal -> indigo gradient -->
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#2DD4BF"/>
      <stop offset="55%" stop-color="#5EA9F2"/>
      <stop offset="100%" stop-color="#6366F1"/>
    </linearGradient>
    <!-- Subtle top gloss -->
    <linearGradient id="gloss" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="rgba(255,255,255,0.35)"/>
      <stop offset="55%" stop-color="rgba(255,255,255,0.0)"/>
    </linearGradient>
    <!-- Slight drop-shadow under bars -->
    <filter id="barShadow" x="-10%" y="-10%" width="120%" height="130%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="6"/>
      <feOffset dy="6"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
      <feComposite in2="SourceGraphic" operator="over"/>
    </filter>
    <!-- macOS squircle: corner radius about 22% of size -->
    <clipPath id="squircle">
      <rect x="100" y="100" width="824" height="824" rx="184" ry="184"/>
    </clipPath>
  </defs>

  <!-- Background squircle -->
  <g clip-path="url(#squircle)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
    <!-- Top gloss strip -->
    <rect x="100" y="100" width="824" height="440" fill="url(#gloss)"/>
    <!-- Faint diagonal sheen line -->
    <path d="M 100 700 L 924 380" stroke="rgba(255,255,255,0.08)" stroke-width="120" fill="none"/>
  </g>

  <!-- Drop shadow under bars (rendered as a soft ellipse) -->
  <ellipse cx="512" cy="888" rx="270" ry="14" fill="rgba(0,0,0,0.28)" filter="url(#barShadow)"/>

  <!-- Three ascending bars; corner radius 24 -->
  <g>
    <rect x="290" y="700" width="130" height="170" rx="24" ry="24" fill="rgba(255,255,255,0.86)"/>
    <rect x="455" y="540" width="130" height="330" rx="24" ry="24" fill="rgba(255,255,255,0.94)"/>
    <rect x="620" y="340" width="130" height="530" rx="24" ry="24" fill="#FFFFFF"/>
  </g>

  <!-- Accent dot at the tip of the tallest bar -->
  <g>
    <circle cx="685" cy="305" r="40" fill="#FB923C"/>
    <circle cx="685" cy="305" r="40" fill="none" stroke="rgba(255,255,255,0.85)" stroke-width="5"/>
    <circle cx="675" cy="295" r="10" fill="rgba(255,255,255,0.85)"/>
  </g>
</svg>
SVG

echo "==> Rendering 1024x1024 master from SVG"
# Use rsvg-convert directly — it handles SVG gradients and clip-paths properly.
rsvg-convert -w 1024 -h 1024 "$SVG_FILE" -o "$MASTER"
file "$MASTER"

echo "==> Generating iconset sizes"
declare -a SIZES=(16 32 128 256 512)
for sz in "${SIZES[@]}"; do
    magick "$MASTER" -resize "${sz}x${sz}" "$ICONSET/icon_${sz}x${sz}.png"
    dbl=$((sz * 2))
    magick "$MASTER" -resize "${dbl}x${dbl}" "$ICONSET/icon_${sz}x${sz}@2x.png"
done

echo "==> Building .icns"
iconutil --convert icns "$ICONSET" --output "$OUT_DIR/AppIcon.icns"

echo "==> Done"
ls -la "$OUT_DIR/AppIcon.icns" "$MASTER"
