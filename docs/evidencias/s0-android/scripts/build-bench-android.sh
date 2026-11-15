#!/bin/sh
# Cross-compila caju-bench (Release) para Android arm64 sem alterar Package.swift/CI.
# `swift build --product` falha no Mac (falta swift-autolink-extract no toolchain do Xcode),
# então compila só os objetos (--target) e liga à mão com o clang/lld do NDK (mesma técnica de Hosts/Android/scripts/build-native.sh).
set -eu
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
ndk="${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME (NDK r30)}"
config="${1:-release}"
case "$config" in
  release|Release) cfgdir="Release" ;;
  debug|Debug) cfgdir="Debug" ;;
  *) cfgdir="$config" ;;
esac
triple=aarch64-unknown-linux-android29
sdk_root="$(ls -d "$HOME"/Library/org.swift.swiftpm/swift-sdks/*android*.artifactbundle/swift-android | head -n 1)"
runtime="$sdk_root/swift-resources/usr/lib/swift-aarch64/android"
llvm="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*)"
out="${2:-$root/.build/android-bench}"
cd "$root"
swift build -c "$config" --swift-sdk "$triple" --target CajuBenchmarks || true
objects="$(find .build/out/Intermediates.noindex -path "*${cfgdir}-android-aarch64*" -name '*.o' \
  \( -path '*caju-bench*' -o -path '*CajuBenchmarks*' -o -path '*CajuMath-t*' -o -path '*CajuCore-t*' -o -path '*CajuCollections-t*' \
     -o -path '*CajuUILayout-t*' -o -path '*CajuPhysicsSpatial-t*' \) | sort)"
mkdir -p "$out"
"$llvm/bin/aarch64-linux-android29-clang" -fuse-ld=lld -Wl,-z,max-page-size=16384 -Wl,-rpath,'$ORIGIN' \
  -o "$out/caju-bench" $objects "$runtime/aarch64/swiftrt.o" \
  -L"$runtime" -lswiftCore -lswift_Concurrency -lswift_StringProcessing -lswiftSynchronization \
  -lswiftAndroid -lc++_shared -ldl -lm
# Runtime do Swift (DT_NEEDED transitivo)
readelf="$llvm/bin/llvm-readelf"
pending="caju-bench"
while [ -n "$pending" ]; do
  next=""
  for lib in $pending; do
    for needed in $("$readelf" -d "$out/$lib" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
      if [ -f "$runtime/$needed" ] && [ ! -f "$out/$needed" ]; then cp "$runtime/$needed" "$out/"; next="$next $needed"; fi
    done
  done
  pending="$next"
done
cp "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$out/"
echo "ok: $out"; ls -l "$out"
