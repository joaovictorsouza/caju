#!/bin/sh
# Compila o host Swift para arm64-v8a e organiza os .so em app/src/main/jniLibs/arm64-v8a.
#
# Por que liga à mão: o toolchain do Xcode não traz `swift-autolink-extract`, que o
# `swift build` precisa para o passo de link no Android. Compilamos só os objetos
# (`--target`) e ligamos com o clang/lld do NDK + o runtime do Swift SDK for Android.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
ndk="${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME (NDK r30)}"
config="${CAJU_CONFIG:-debug}"
triple=aarch64-unknown-linux-android29

sdk_root="$(ls -d "$HOME"/Library/org.swift.swiftpm/swift-sdks/*android*.artifactbundle/swift-android | head -n 1)"
runtime="$sdk_root/swift-resources/usr/lib/swift-aarch64/android"
llvm="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*)"
out="$here/app/src/main/jniLibs/arm64-v8a"

cd "$here"
swift build -c "$config" --swift-sdk "$triple" --target CajuAndroidHost

objects="$(find .build/out/Intermediates.noindex -path "*Debug-android-aarch64*" -name "*.o" \
  \( -path "*CajuAndroidHost-t.build*" -o -path "*CajuPlatform-t.build*" -o -path "*CajuRHIVulkan-t.build*" \
     -o -path "*CajuRHI-t.build*" -o -path "*CajuCore-t.build*" -o -path "*CajuMath-t.build*" \) | sort)"

mkdir -p "$out"
rm -f "${out:?}"/*.so
# shellcheck disable=SC2086
"$llvm/bin/aarch64-linux-android29-clang" -shared -fuse-ld=lld \
  -Wl,-soname,libCajuAndroidHost.so -Wl,-z,max-page-size=16384 -Wl,-rpath,'$ORIGIN' \
  -Wl,--export-dynamic-symbol=ANativeActivity_onCreate \
  -o "$out/libCajuAndroidHost.so" $objects "$runtime/aarch64/swiftrt.o" \
  -L"$runtime" -lswiftCore -lswift_Concurrency -lswift_StringProcessing -lswiftSynchronization \
  -lswiftAndroid -lvulkan -landroid -llog -lc++_shared -ldl -lm

# Runtime do Swift empacotado junto: resolve as dependências (DT_NEEDED) transitivas
# da lib do host dentro do Swift SDK (Swift 6.4.2; ver docs/adr/0012).
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
echo "ok: $out"
