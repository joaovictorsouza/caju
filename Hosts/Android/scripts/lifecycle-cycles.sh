#!/bin/sh
# Critério da V-1 (fatia G): N ciclos de rotação + Home/volta no aparelho, medindo o RSS do processo e os
# erros da camada de validação (APK de depuração com CAJU_VALIDATION=1). Restaura a rotação ao final.
# Uso: scripts/lifecycle-cycles.sh [ciclos] [arquivo de log]
# CAJU_CYCLE=rotate|home|both (padrão both) isola uma das metades do ciclo para investigar vazamento.
set -eu
cycles="${1:-50}"
log="${2:-lifecycle.log}"
pkg=dev.caju.host
activity="$pkg/android.app.NativeActivity"
orig_auto="$(adb shell settings get system accelerometer_rotation | tr -d '\r')"
orig_rot="$(adb shell settings get system user_rotation | tr -d '\r')"
restore() {
  adb shell settings put system user_rotation "$orig_rot" > /dev/null
  adb shell settings put system accelerometer_rotation "$orig_auto" > /dev/null
}
trap restore EXIT
rss() { adb shell "grep VmRSS /proc/\$(pidof $pkg)/status" | awk '{print $2}'; }

adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0
adb shell am force-stop "$pkg"
adb logcat -c
adb shell am start -n "$activity" > /dev/null
sleep 4
# Um ciclo de aquecimento (caches de pipeline/render pass, primeira recriação) antes da linha de base.
adb shell settings put system user_rotation 1; sleep 2; adb shell settings put system user_rotation 0; sleep 2
adb shell input keyevent KEYCODE_HOME; sleep 2; adb shell am start -n "$activity" > /dev/null; sleep 3
base="$(rss)"
echo "RSS base (kB): $base" | tee "$log"
i=1
mode="${CAJU_CYCLE:-both}"
while [ "$i" -le "$cycles" ]; do
  if [ "$mode" != home ]; then
    adb shell settings put system user_rotation 1; sleep 1.5
    adb shell settings put system user_rotation 0; sleep 1.5
  fi
  if [ "$mode" != rotate ]; then
    adb shell input keyevent KEYCODE_HOME; sleep 1.5
    adb shell am start -n "$activity" > /dev/null; sleep 2
  fi
  now="$(rss)"
  echo "ciclo $i: RSS $now kB (Δ $((now - base)) kB)" | tee -a "$log"
  i=$((i + 1))
done
sleep 2
final="$(rss)"
echo "RSS final (kB): $final; ΔRSS = $((final - base)) kB" | tee -a "$log"
echo "--- logcat (Caju, CajuVulkan) ---" >> "$log"
adb logcat -d -s Caju CajuVulkan CajuVulkanDriver >> "$log"
errors="$(grep -c ' E CajuVulkan:' "$log" || true)"
crashes="$(adb logcat -d -b crash | grep -c "$pkg" || true)"
echo "erros de validação: $errors; crashes: $crashes" | tee -a "$log"
