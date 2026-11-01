#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p AppIcon.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" BrandLogo.png --out "AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" BrandLogo.png --out "AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
