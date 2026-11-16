#!/bin/sh
# Compila o executável da suíte de conformidade do RHI (backend Vulkan), envia ao aparelho por adb com o
# runtime do Swift e roda em /data/local/tmp (sem janela, sem APK). Sai com o código do executável.
# Requer o toolchain swift.org 6.4.2 (TOOLCHAINS) e o NDK r30 (ANDROID_NDK_HOME); ver README.md.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
ndk="${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME (NDK r30)}"
config="${CAJU_CONFIG:-debug}"
case "$config" in release) dir=Release ;; *) dir=Debug ;; esac
triple=aarch64-unknown-linux-android29
remote=/data/local/tmp/caju-conformance

# Swift SDK for Android: ~/Library/org.swift.swiftpm (macOS), ~/.swiftpm ou ~/.config/swiftpm (Linux, CI).
sdk_root="$(find "$HOME/Library/org.swift.swiftpm" "$HOME/.swiftpm" "$HOME/.config/swiftpm" -maxdepth 4 -type d \
  -path '*android*.artifactbundle/swift-android' 2>/dev/null | head -n 1)"
[ -n "$sdk_root" ] || { echo "Swift SDK for Android não encontrado (swift sdk install ...)" >&2; exit 1; }
runtime="$sdk_root/swift-resources/usr/lib/swift-aarch64/android"
llvm="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*)"
stage="$here/.build/conformance-stage"

cd "$here"
swift build -c "$config" --swift-sdk "$triple" --product caju-conformance
rm -rf "$stage"
mkdir -p "$stage"
cp ".build/out/Products/$dir-android-aarch64/caju-conformance" "$stage/"

# Runtime do Swift (DT_NEEDED transitivo) e libc++.
readelf="$llvm/bin/llvm-readelf"
pending="caju-conformance"
while [ -n "$pending" ]; do
  next=""
  for lib in $pending; do
    for needed in $("$readelf" -d "$stage/$lib" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
      if [ -f "$runtime/$needed" ] && [ ! -f "$stage/$needed" ]; then
        cp "$runtime/$needed" "$stage/"
        next="$next $needed"
      fi
    done
  done
  pending="$next"
done
cp "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$stage/"

adb shell "rm -rf $remote && mkdir -p $remote"
adb push "$stage/." "$remote/" > /dev/null
adb shell "cd $remote && chmod 755 caju-conformance && LD_LIBRARY_PATH=$remote ./caju-conformance"
