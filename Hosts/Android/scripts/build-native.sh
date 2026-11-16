#!/bin/sh
# Compila o host Swift (biblioteca dinâmica CajuAndroidHost) para arm64-v8a e organiza os .so em
# app/src/main/jniLibs/arm64-v8a, com o runtime do Swift e a libc++ (DT_NEEDED transitivo).
#
# Requer o toolchain swift.org da mesma versão do Swift SDK for Android (6.4.2; ver README.md): com ele o
# `swift build --product` liga direto, inclusive o alvo C++ do VMA. O toolchain do Xcode não liga no Android.
# CAJU_VALIDATION=1 copia também a camada de validação do Khronos (scripts/fetch-validation-layer.sh).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
ndk="${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME (NDK r30)}"
export TOOLCHAINS="${TOOLCHAINS:-org.swift.642202610261a}"
config="${CAJU_CONFIG:-debug}"
case "$config" in release) dir=Release ;; *) dir=Debug ;; esac
triple=aarch64-unknown-linux-android29

# Swift SDK for Android: ~/Library/org.swift.swiftpm (macOS), ~/.swiftpm ou ~/.config/swiftpm (Linux, CI).
sdk_root="$(find "$HOME/Library/org.swift.swiftpm" "$HOME/.swiftpm" "$HOME/.config/swiftpm" -maxdepth 4 -type d \
  -path '*android*.artifactbundle/swift-android' 2>/dev/null | head -n 1)"
[ -n "$sdk_root" ] || { echo "Swift SDK for Android não encontrado (swift sdk install ...)" >&2; exit 1; }
runtime="$sdk_root/swift-resources/usr/lib/swift-aarch64/android"
llvm="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*)"
out="$here/app/src/main/jniLibs/arm64-v8a"

cd "$here"
swift build -c "$config" --swift-sdk "$triple" --product CajuAndroidHost

mkdir -p "$out"
rm -f "${out:?}"/*.so
cp ".build/out/Products/$dir-android-aarch64/libCajuAndroidHost.so" "$out/"

readelf="$llvm/bin/llvm-readelf"
pending="libCajuAndroidHost.so"
while [ -n "$pending" ]; do
  next=""
  for lib in $pending; do
    for needed in $("$readelf" -d "$out/$lib" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
      if [ -f "$runtime/$needed" ] && [ ! -f "$out/$needed" ]; then
        cp "$runtime/$needed" "$out/"
        next="$next $needed"
      fi
    done
  done
  pending="$next"
done
cp "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$out/"
if [ "${CAJU_VALIDATION:-0}" = "1" ]; then
  layer="$here/.build/validation-layer/arm64-v8a/libVkLayer_khronos_validation.so"
  [ -f "$layer" ] || { echo "falta $layer: rode scripts/fetch-validation-layer.sh" >&2; exit 1; }
  cp "$layer" "$out/"
fi
echo "ok: $out"
