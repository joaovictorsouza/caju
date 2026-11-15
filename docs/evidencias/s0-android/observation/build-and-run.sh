#!/bin/bash
set -euo pipefail

export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/30.0.15729638"
export ANDROID_NDK_ROOT="$HOME/Library/Android/sdk/ndk/30.0.15729638"
export ANDROID_HOME="$HOME/Library/Android/sdk"

WORK_DIR="/tmp/obs-android"
OUT_DIR="$WORK_DIR/out"
OBS_DEVICE_DIR="/data/local/tmp/obs"
DEVICE_SERIAL="RQCT202D4FM"

echo "==> 1. Compilando objetos Swift para Android arm64..."
cd "$WORK_DIR"
swift build -c release --swift-sdk aarch64-unknown-linux-android29 --target obs-android || true

sdk_root="$(ls -d "$HOME"/Library/org.swift.swiftpm/swift-sdks/*android*.artifactbundle/swift-android | head -n 1)"
runtime="$sdk_root/swift-resources/usr/lib/swift-aarch64/android"
llvm="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*)"
readelf="$llvm/bin/llvm-readelf"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*

objects="$(find .build/out/Intermediates.noindex -path "*Release-android-aarch64*" -name '*.o')"

echo "==> 2. Ligando executável obs-android com Clang/LLD do NDK..."
"$llvm/bin/aarch64-linux-android29-clang" -fuse-ld=lld \
  -Wl,-z,max-page-size=16384 \
  -Wl,-rpath,'$ORIGIN' \
  -o "$OUT_DIR/obs-android" \
  $objects \
  "$runtime/aarch64/swiftrt.o" \
  -L"$runtime" \
  -lswiftCore \
  -lswift_Concurrency \
  -lswift_StringProcessing \
  -lswiftSynchronization \
  -lswiftObservation \
  -lswiftAndroid \
  -lc++_shared \
  -ldl \
  -lm

echo "==> 3. Resolvendo e empacotando dependências transitivas do runtime..."
cp "$llvm/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT_DIR/"

python3 -c "
import subprocess, os, shutil
out = '$OUT_DIR'
runtime = '$runtime'
readelf = '$readelf'
while True:
    needed_any = False
    for fname in os.listdir(out):
        fpath = os.path.join(out, fname)
        if not (fname.endswith('.so') or fname == 'obs-android'):
            continue
        res = subprocess.run([readelf, '-d', fpath], capture_output=True, text=True)
        for line in res.stdout.splitlines():
            if 'Shared library: [' in line:
                lib = line.split('Shared library: [')[1].split(']')[0]
                src = os.path.join(runtime, lib)
                dst = os.path.join(out, lib)
                if os.path.exists(src) and not os.path.exists(dst):
                    shutil.copy(src, dst)
                    needed_any = True
    if not needed_any:
        break
"

echo "==> Conteúdo de $OUT_DIR:"
ls -lh "$OUT_DIR"

echo "==> 4. Enviando binários via adb para o Galaxy S22+ ($DEVICE_SERIAL)..."
adb -s "$DEVICE_SERIAL" shell rm -rf "$OBS_DEVICE_DIR"
adb -s "$DEVICE_SERIAL" shell mkdir -p "$OBS_DEVICE_DIR"
adb -s "$DEVICE_SERIAL" push "$OUT_DIR"/* "$OBS_DEVICE_DIR/"
adb -s "$DEVICE_SERIAL" shell chmod +x "$OBS_DEVICE_DIR/obs-android"

echo "==> 5. Executando obs-android no aparelho..."
adb -s "$DEVICE_SERIAL" shell "cd $OBS_DEVICE_DIR && LD_LIBRARY_PATH=. ./obs-android"
