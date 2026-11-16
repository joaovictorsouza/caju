#!/bin/sh
# Baixa a camada de validação do Khronos para Android (só arm64-v8a) em .build/validation-layer.
# Versão fixa e hash conferido (ADR 0024). O Android não traz a camada: ela vai dentro do APK de depuração
# (CAJU_VALIDATION=1 scripts/build-native.sh) e só carrega em app debuggável.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
version=1.4.363.1
sha256=2c17b00a95b18fd63244b27332ef86f45c9269769f798a6261ce80b869c41af4
url="https://github.com/KhronosGroup/Vulkan-ValidationLayers/releases/download/vulkan-sdk-$version/android-binaries-$version.zip"
dest="$here/.build/validation-layer"
lib="$dest/arm64-v8a/libVkLayer_khronos_validation.so"
[ -f "$lib" ] && { echo "ok: $lib"; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/layers.zip" "$url"
echo "$sha256  $tmp/layers.zip" | shasum -a 256 -c -
mkdir -p "$dest/arm64-v8a"
unzip -j -o -q "$tmp/layers.zip" "*arm64-v8a/libVkLayer_khronos_validation.so" -d "$dest/arm64-v8a"
echo "ok: $lib"
