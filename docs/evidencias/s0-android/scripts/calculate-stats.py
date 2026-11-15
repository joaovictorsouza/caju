#!/usr/bin/env python3
"""
Calcula estatísticas (mediana e p95) dos benchmarks Caju rodados no Galaxy S22+ vs Mac.
Lê os arquivos brutos caju-bench-android-run1..5.json e caju-bench-mac-run1..5.json.
"""

import json
import glob
import os
import statistics

def parse_multi_json(content):
    decoder = json.JSONDecoder()
    pos = 0
    objs = []
    content = content.strip()
    while pos < len(content):
        while pos < len(content) and content[pos].isspace():
            pos += 1
        if pos >= len(content):
            break
        obj, end_pos = decoder.raw_decode(content, idx=pos)
        objs.append(obj)
        pos = end_pos
    return objs

def percentile_95(values):
    """
    Percentil 95 usando interpolação linear padrão (R-7 / NumPy default).
    Para N=5: index = 0.95 * (5 - 1) = 3.8.
    """
    s = sorted(values)
    n = len(s)
    if n == 1:
        return s[0]
    idx = 0.95 * (n - 1)
    lower = int(idx)
    upper = lower + 1
    weight = idx - lower
    if upper >= n:
        return s[-1]
    return s[lower] + weight * (s[upper] - s[lower])

def load_runs(pattern):
    runs_data = []
    for fpath in sorted(glob.glob(pattern)):
        with open(fpath) as f:
            suites = parse_multi_json(f.read())
            runs_data.append(suites)
    return runs_data

def aggregate_benchmarks(runs_data):
    # map: (suite, name) -> list of ns_per_op
    data = {}
    order = []
    for run in runs_data:
        for suite_obj in run:
            suite = suite_obj["suite"]
            for res in suite_obj["results"]:
                key = (suite, res["name"])
                if key not in data:
                    data[key] = []
                    order.append(key)
                data[key].append(res["ns_per_op"])
    return order, data

def main():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    android_pattern = os.path.join(base_dir, "caju-bench-android-run*.json")
    mac_pattern = os.path.join(base_dir, "caju-bench-mac-run*.json")

    android_runs = load_runs(android_pattern)
    mac_runs = load_runs(mac_pattern)

    order_a, data_a = aggregate_benchmarks(android_runs)
    order_m, data_m = aggregate_benchmarks(mac_runs)

    print(f"Execuções carregadas: {len(android_runs)} Android, {len(mac_runs)} Mac")
    print(f"Total de benchmarks por execução: {len(order_a)}")

    current_suite = None
    rows = []

    for suite, name in order_a:
        vals_a = data_a.get((suite, name), [])
        vals_m = data_m.get((suite, name), [])

        med_a = statistics.median(vals_a)
        p95_a = percentile_95(vals_a)

        med_m = statistics.median(vals_m)
        p95_m = percentile_95(vals_m)

        ratio = med_a / med_m if med_m > 0 else 0.0

        rows.append({
            "suite": suite,
            "name": name,
            "android_med": med_a,
            "android_p95": p95_a,
            "android_runs": vals_a,
            "mac_med": med_m,
            "mac_p95": p95_m,
            "mac_runs": vals_m,
            "ratio": ratio
        })

    # Imprimir tabela formatada em Markdown
    print("\n| Suíte | Benchmark | S22+ Mediana (ns) | S22+ p95 (ns) | Mac Mediana (ns) | Mac p95 (ns) | Razão S22+/Mac |")
    print("| :--- | :--- | :---: | :---: | :---: | :---: | :---: |")
    for r in rows:
        print(f"| {r['suite']} | `{r['name']}` | {r['android_med']:.2f} | {r['android_p95']:.2f} | {r['mac_med']:.2f} | {r['mac_p95']:.2f} | {r['ratio']:.2f}x |")

    # Salva também um JSON consolidado para referência
    stats_json_path = os.path.join(base_dir, "bench-stats-summary.json")
    with open(stats_json_path, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\nSalvo resumo consolidado em: {stats_json_path}")

if __name__ == "__main__":
    main()
