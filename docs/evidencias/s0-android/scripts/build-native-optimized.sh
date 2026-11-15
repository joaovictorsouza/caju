#!/bin/sh
# Compila o host Swift em Release para arm64-v8a com static stdlib e llvm-strip.
# Localizado em docs/evidencias/s0-android/scripts/ para não alterar scripts/Package.swift/CI rastreados.
set -eu
here="$(cd "$(dirname "$0")/../../../../Hosts/Android" && pwd)"
ndk="${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME (NDK r30)}"
config="${CAJU_CONFIG:-release}"
case "$config" in
  release|Release) cfgdir="Release" ;;
  debug|Debug) cfgdir="Debug" ;;
  *) cfgdir="$config" ;;
esac
triple=aarch64-unknown-linux-android29

sdk_root="$(ls -d "$HOME"/Library/org.swift.swiftpm/swift-sdks/*android*.artifactbundle/swift-android | head -n 1)"
runtime_static="$sdk_root/swift-resources/usr/lib/swift_static-aarch64/android"
llvm="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*)"
out="$here/app/src/main/jniLibs/arm64-v8a"

cd "$here"
echo "==> Compilando CajuAndroidHost ($config)..."
swift build -c "$config" --swift-sdk "$triple" --target CajuAndroidHost

objects="$(find .build/out/Intermediates.noindex -path "*${cfgdir}-android-aarch64*" -name "*.o" \
  \( -path "*CajuAndroidHost-t.build*" -o -path "*CajuPlatform-t.build*" -o -path "*CajuRHIVulkan-t.build*" \
     -o -path "*CajuRHI-t.build*" -o -path "*CajuCore-t.build*" -o -path "*CajuMath-t.build*" \) | sort)"

mkdir -p "$out"
rm -f "${out:?}"/*.so

echo "==> Ligando libCajuAndroidHost.so (static Swift stdlib)..."
# shellcheck disable=SC2086
"$llvm/bin/aarch64-linux-android29-clang" -shared -fuse-ld=lld \
  -Wl,-soname,libCajuAndroidHost.so -Wl,-z,max-page-size=16384 -Wl,-rpath,'$ORIGIN' \
  -Wl,--export-dynamic-symbol=ANativeActivity_onCreate \
  -o "$out/libCajuAndroidHost.so" $objects "$runtime_static/aarch64/swiftrt.o" \
  -L"$runtime_static" -lswiftCore -lswift_Concurrency -lswift_StringProcessing -lswiftSynchronization \
  -lswiftAndroid -lvulkan -landroid -llog -lc++_shared -ldl -lm

echo "==> Copiando libc++_shared.so..."
cp "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$out/"

echo "==> Executando llvm-strip..."
"$llvm/bin/llvm-strip" --strip-all "$out/libCajuAndroidHost.so"
"$llvm/bin/llvm-strip" --strip-all "$out/libc++_shared.so"

echo "==> Conteúdo de $out:"
ls -lh "$out"
