#!/usr/bin/env bash
# generate-app-icons.sh — regenerate Whistle/Assets.xcassets from the master
# whistle SVG. Rerun this after editing the SVG below; it overwrites every
# PNG + Contents.json under AppIcon.appiconset/ and MenuBarIcon.imageset/.
#
# Requires `rsvg-convert` and `magick` (ImageMagick):
#   brew install librsvg imagemagick
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ASSETS="Whistle/Assets.xcassets"
APPICON="$ASSETS/AppIcon.appiconset"
MENUBAR="$ASSETS/MenuBarIcon.imageset"
BACKGROUND="#1C1C1E"

mkdir -p "$APPICON" "$MENUBAR"

SVG="$(mktemp -t whistle-icon).svg"
trap 'rm -f "$SVG"' EXIT

cat > "$SVG" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" height="24" width="24">
  <g>
    <path fill="#696464" fill-rule="evenodd" d="M2 8H1v8h7.0164c0.2573 3.909 3.5095 7 7.4836 7 4.1421 0 7.5 -3.3579 7.5 -7.5S19.6421 8 15.5 8H2Z" clip-rule="evenodd"></path>
    <path fill="#f1b418" fill-rule="evenodd" d="M14 14h3v3h-3v-3Z" clip-rule="evenodd"></path>
    <path fill="#f1b418" fill-rule="evenodd" d="M10.0006 1v4H8.00064V1h1.99996ZM4.26886 2.35982l2.5 3 -1.53644 1.28036 -2.5 -3 1.53644 -1.28036Zm6.96354 3 2.5 -3 1.5365 1.28036 -2.5 3 -1.5365 -1.28036Z" clip-rule="evenodd"></path>
  </g>
</svg>
EOF

# --- App icon: flat square, dark background, glyph at ~70% of canvas.
# macOS applies its own squircle mask + shadow to Finder/Dock icons at
# display time, so this must stay a plain full-bleed square (no rounding
# baked in here).
app_icon_size() {
  local px="$1" filename="$2"
  local glyph_px=$(( px * 7 / 10 ))
  local glyph="$(mktemp -t whistle-glyph).png"
  rsvg-convert -w "$glyph_px" -h "$glyph_px" "$SVG" -o "$glyph"
  magick -size "${px}x${px}" "xc:$BACKGROUND" "$glyph" -gravity center -composite "$APPICON/$filename"
  rm -f "$glyph"
}

app_icon_size 16 icon_16x16.png
app_icon_size 32 icon_16x16@2x.png
app_icon_size 32 icon_32x32.png
app_icon_size 64 icon_32x32@2x.png
app_icon_size 128 icon_128x128.png
app_icon_size 256 icon_128x128@2x.png
app_icon_size 256 icon_256x256.png
app_icon_size 512 icon_256x256@2x.png
app_icon_size 512 icon_512x512.png
app_icon_size 1024 icon_512x512@2x.png

cat > "$APPICON/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# --- Menu bar icon: transparent, no background/recoloring. A template
# image only uses the alpha channel — AppKit discards the SVG's own RGB
# and tints it to match the system's light/dark menu bar automatically.
rsvg-convert -w 18 -h 18 "$SVG" -o "$MENUBAR/menu-bar-icon.png"
rsvg-convert -w 36 -h 36 "$SVG" -o "$MENUBAR/menu-bar-icon@2x.png"

cat > "$MENUBAR/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "menu-bar-icon.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "menu-bar-icon@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
EOF

cat > "$ASSETS/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "Generated $APPICON and $MENUBAR from the master SVG."
