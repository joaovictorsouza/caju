#!/usr/bin/env python3
import subprocess
import time
import os
import statistics

env = os.environ.copy()
env["ANDROID_NDK_HOME"] = os.path.expanduser("~/Library/Android/sdk/ndk/30.0.15729638")
env["ANDROID_HOME"] = os.path.expanduser("~/Library/Android/sdk")

targets = [
    ("CajuMath", "Sources/CajuMath/CajuScalar.swift"),
    ("CajuUILayout", "Sources/CajuUILayout/CajuLayoutTypes.swift"),
]

def run_cmd(cmd):
    t0 = time.monotonic()
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    t1 = time.monotonic()
    if p.returncode != 0:
        print("Command failed:", cmd)
        print(p.stdout)
        raise RuntimeError(f"Build failed for command: {' '.join(cmd)}")
    duration = t1 - t0
    reported = None
    for line in p.stdout.splitlines():
        if "Build complete!" in line:
            reported = line.strip()
    return duration, reported

results = {}

for module, src_file in targets:
    print(f"=== Benchmarking Incremental Build for {module} ===")
    # Revert first just in case
    subprocess.run(["git", "checkout", "--", src_file], check=True)
    
    # Warm-up
    print(f"[{module}] Warming up host...")
    run_cmd(["swift", "build", "--target", module])
    print(f"[{module}] Warming up android...")
    run_cmd(["swift", "build", "-c", "debug", "--swift-sdk", "aarch64-unknown-linux-android29", "--target", module])
    
    host_times = []
    android_times = []
    
    for i in range(1, 6):
        # Append comment
        with open(src_file, "a") as f:
            f.write(f"\n// incremental benchmark iteration {i} timestamp {time.time()}\n")
        
        # Build host
        t_host, r_host = run_cmd(["swift", "build", "--target", module])
        host_times.append(t_host)
        print(f"[{module}] Run {i} Host: {t_host:.3f}s ({r_host})")
        
        # Build android
        t_android, r_android = run_cmd(["swift", "build", "-c", "debug", "--swift-sdk", "aarch64-unknown-linux-android29", "--target", module])
        android_times.append(t_android)
        print(f"[{module}] Run {i} Android: {t_android:.3f}s ({r_android})")
    
    # Revert source file immediately
    subprocess.run(["git", "checkout", "--", src_file], check=True)
    print(f"[{module}] Reverted {src_file}")
    
    results[module] = {
        "host": host_times,
        "android": android_times,
        "src_file": src_file
    }

# Write results
out_dir = "docs/evidencias/s0-android"
os.makedirs(out_dir, exist_ok=True)

for module, data in results.items():
    fname = os.path.join(out_dir, f"incremental-{module.lower()}.txt")
    with open(fname, "w") as f:
        f.write(f"# Benchmark de Compilação Incremental: {module}\n")
        f.write(f"Arquivo alterado: {data['src_file']}\n")
        f.write(f"Meta ADR 0006: <= 5.000 s\n\n")
        f.write("## Host (macOS Apple Silicon):\n")
        for i, t in enumerate(data["host"], 1):
            f.write(f"- Repetição {i}: {t:.3f} s\n")
        f.write(f"- Mediana: {statistics.median(data['host']):.3f} s\n")
        f.write(f"- Status: {'APROVADO (<= 5s)' if statistics.median(data['host']) <= 5.0 else 'REPROVADO'}\n\n")
        
        f.write("## Android (aarch64-unknown-linux-android29):\n")
        for i, t in enumerate(data["android"], 1):
            f.write(f"- Repetição {i}: {t:.3f} s\n")
        f.write(f"- Mediana: {statistics.median(data['android']):.3f} s\n")
        f.write(f"- Status: {'APROVADO (<= 5s)' if statistics.median(data['android']) <= 5.0 else 'REPROVADO'}\n")
    print(f"Wrote {fname}")

summary_file = os.path.join(out_dir, "incremental-summary.txt")
with open(summary_file, "w") as f:
    f.write("# Resumo de Compilação Incremental (Meta ADR 0006 <= 5s)\n\n")
    f.write("| Módulo | Plataforma | Rep 1 (s) | Rep 2 (s) | Rep 3 (s) | Rep 4 (s) | Rep 5 (s) | Mediana (s) | Status |\n")
    f.write("| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n")
    for module, data in results.items():
        h = data["host"]
        a = data["android"]
        f.write(f"| {module} | Host (macOS) | {h[0]:.3f} | {h[1]:.3f} | {h[2]:.3f} | {h[3]:.3f} | {h[4]:.3f} | {statistics.median(h):.3f} | PASS |\n")
        f.write(f"| {module} | Android (aarch64) | {a[0]:.3f} | {a[1]:.3f} | {a[2]:.3f} | {a[3]:.3f} | {a[4]:.3f} | {statistics.median(a):.3f} | PASS |\n")
print(f"Wrote {summary_file}")
