#!/usr/bin/env bash
# Testes de golden, determinismo e fuzz determinístico para `caju-tools` (Trilha T-1).
# Uso: scripts/test-caju-tools.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

GOLDENS_DIR="$ROOT_DIR/Tests/CajuToolsGoldens"
INPUTS_DIR="$GOLDENS_DIR/inputs"
EXPECTED_DIR="$GOLDENS_DIR/expected"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/caju-tools-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Permite passar flags extras (ex.: CAJU_SWIFT_FLAGS=--disable-sandbox) se o ambiente exigir.
read -r -a SWIFT_FLAGS <<< "${CAJU_SWIFT_FLAGS:-}"

echo "[1/6] Compilando caju-tools..."
swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product caju-tools
BIN_DIR="$(swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"
BIN_PATH="$BIN_DIR/caju-tools"

if [ ! -x "$BIN_PATH" ]; then
    echo "ERRO: binário não encontrado em $BIN_PATH" >&2
    exit 1
fi

run_swift_tools() {
    swift run ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --skip-build caju-tools "$@"
}

assert_exit() {
    local expected_code="$1"
    shift
    set +e
    "$@" >/dev/null 2>"$WORK_DIR/last_stderr.txt"
    local actual_code=$?
    set -e
    if [ "$actual_code" -ne "$expected_code" ]; then
        echo "ERRO: esperado exit $expected_code, veio $actual_code para: $*" >&2
        cat "$WORK_DIR/last_stderr.txt" >&2
        exit 1
    fi
}

echo "[2/6] Verificando ajuda e códigos de saída de uso (exit 0 / exit 2)..."
run_swift_tools --help > "$WORK_DIR/help.txt"
cmp -s "$WORK_DIR/help.txt" "$EXPECTED_DIR/help.txt" || {
    echo "ERRO: saída de --help diverge do golden" >&2
    diff -u "$EXPECTED_DIR/help.txt" "$WORK_DIR/help.txt" >&2
    exit 1
}

assert_exit 2 "$BIN_PATH" subcomando-inexistente
assert_exit 2 "$BIN_PATH" texture
assert_exit 2 "$BIN_PATH" texture "$INPUTS_DIR/sample.png"
assert_exit 2 "$BIN_PATH" validate-gltf
assert_exit 2 "$BIN_PATH" validate-gltf --flag-desconhecida
assert_exit 2 "$BIN_PATH" manifest

echo "[3/6] Verificando goldens de validate-gltf..."
run_swift_tools validate-gltf "$INPUTS_DIR/valid.gltf" > "$WORK_DIR/validate-gltf.txt"
cmp -s "$WORK_DIR/validate-gltf.txt" "$EXPECTED_DIR/validate-gltf-valid.txt"

run_swift_tools validate-gltf "$INPUTS_DIR/valid.gltf" --json > "$WORK_DIR/validate-gltf.json"
cmp -s "$WORK_DIR/validate-gltf.json" "$EXPECTED_DIR/validate-gltf-valid.json"

run_swift_tools validate-gltf "$INPUTS_DIR/valid.glb" > "$WORK_DIR/validate-glb.txt"
cmp -s "$WORK_DIR/validate-glb.txt" "$EXPECTED_DIR/validate-glb-valid.txt"

assert_exit 1 "$BIN_PATH" validate-gltf "$INPUTS_DIR/invalid-bad-accessor.gltf"
assert_exit 1 "$BIN_PATH" validate-gltf "$INPUTS_DIR/invalid-cycle.gltf"
assert_exit 1 "$BIN_PATH" validate-gltf "$INPUTS_DIR/nao-existe.gltf"

echo "[4/6] Verificando goldens de texture (KTX2 RGBA8 + validação)..."
run_swift_tools texture "$INPUTS_DIR/sample.png" -o "$WORK_DIR/sample.ktx2" > "$WORK_DIR/texture-ok.txt"
cmp -s "$WORK_DIR/texture-ok.txt" "$EXPECTED_DIR/texture-ok.txt"
cmp -s "$WORK_DIR/sample.ktx2" "$EXPECTED_DIR/sample.ktx2"

run_swift_tools texture --validate "$WORK_DIR/sample.ktx2" > "$WORK_DIR/texture-validate.txt"
cmp -s "$WORK_DIR/texture-validate.txt" "$EXPECTED_DIR/texture-validate.txt"

# Testa também rgba8-unorm com mipmaps e limitação documentada do ASTC
"$BIN_PATH" texture "$INPUTS_DIR/sample.png" -o "$WORK_DIR/sample-mips.ktx2" --format rgba8-unorm --mipmaps >/dev/null
"$BIN_PATH" texture --validate "$WORK_DIR/sample-mips.ktx2" >/dev/null
assert_exit 1 "$BIN_PATH" texture "$INPUTS_DIR/sample.png" -o "$WORK_DIR/astc.ktx2" --format astc-4x4

echo "[5/6] Verificando goldens de manifest e determinismo (2 execuções)..."
run_swift_tools manifest "$INPUTS_DIR/manifest_tree" > "$WORK_DIR/manifest1.json"
run_swift_tools manifest "$INPUTS_DIR/manifest_tree" > "$WORK_DIR/manifest2.json"
cmp -s "$WORK_DIR/manifest1.json" "$EXPECTED_DIR/manifest.json"
cmp -s "$WORK_DIR/manifest1.json" "$WORK_DIR/manifest2.json"

"$BIN_PATH" texture "$INPUTS_DIR/sample.png" -o "$WORK_DIR/det1.ktx2" > "$WORK_DIR/det1.txt"
"$BIN_PATH" texture "$INPUTS_DIR/sample.png" -o "$WORK_DIR/det2.ktx2" > "$WORK_DIR/det2.txt"
cmp -s "$WORK_DIR/det1.ktx2" "$WORK_DIR/det2.ktx2"
cmp -s "$WORK_DIR/det1.txt" "$WORK_DIR/det2.txt"

"$BIN_PATH" validate-gltf "$INPUTS_DIR/valid.gltf" --json > "$WORK_DIR/gltf1.json"
"$BIN_PATH" validate-gltf "$INPUTS_DIR/valid.gltf" --json > "$WORK_DIR/gltf2.json"
cmp -s "$WORK_DIR/gltf1.json" "$WORK_DIR/gltf2.json"

echo "[6/6] Executando fuzz determinístico (semente fixa 20261115)..."
python3 - "$BIN_PATH" "$INPUTS_DIR" "$EXPECTED_DIR" "$WORK_DIR" <<'PY'
import os
import random
import subprocess
import sys

bin_path, inputs_dir, expected_dir, work_dir = sys.argv[1:5]
rng = random.Random(20261115)

def load(path):
    with open(path, "rb") as f:
        return bytearray(f.read())

def mutate(seed_bytes):
    buf = bytearray(seed_bytes)
    op = rng.randrange(5)
    if op == 0 and len(buf) > 1:
        # Truncamento
        cut = rng.randrange(0, len(buf))
        return buf[:cut]
    elif op == 1 and len(buf) > 0:
        # Sobrescrever bytes aleatórios
        flips = rng.randint(1, min(16, len(buf)))
        for _ in range(flips):
            pos = rng.randrange(len(buf))
            buf[pos] = rng.randrange(256)
        return buf
    elif op == 2 and len(buf) > 0:
        # Flip de bit
        pos = rng.randrange(len(buf))
        buf[pos] ^= 1 << rng.randrange(8)
        return buf
    elif op == 3:
        # Inserir bloco aleatório
        pos = rng.randrange(len(buf) + 1)
        ins = bytes(rng.randrange(256) for _ in range(rng.randint(1, 32)))
        return buf[:pos] + bytearray(ins) + buf[pos:]
    else:
        # Carga totalmente aleatória
        return bytearray(rng.randrange(256) for _ in range(rng.randint(0, 512)))

def run_fuzz_case(args, payload, ext, case_id):
    path = os.path.join(work_dir, f"fuzz_{case_id}.{ext}")
    with open(path, "wb") as f:
        f.write(payload)
    proc = subprocess.run([bin_path, *args, path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if proc.returncode not in (0, 1):
        sys.stderr.write(
            f"FALHA DE FUZZ case={case_id} args={args} exit={proc.returncode} stderr={proc.stderr!r}\n"
        )
        sys.exit(1)

valid_gltf = load(os.path.join(inputs_dir, "valid.gltf"))
valid_glb = load(os.path.join(inputs_dir, "valid.glb"))
sample_ktx2 = load(os.path.join(expected_dir, "sample.ktx2"))
sample_png = load(os.path.join(inputs_dir, "sample.png"))

# 200 casos de fuzz para validate-gltf (glTF JSON, GLB e aninhamento profundo)
for i in range(100):
    run_fuzz_case(["validate-gltf"], mutate(valid_gltf), "gltf", f"gltf_{i}")
for i in range(100):
    run_fuzz_case(["validate-gltf"], mutate(valid_glb), "glb", f"glb_{i}")

# Caso especial: aninhamento JSON profundo além do limite (64)
deep_json = (b"[" * 256) + (b"]" * 256)
run_fuzz_case(["validate-gltf"], deep_json, "gltf", "deep_json")

# 80 casos de fuzz para KTX2 (--validate) e PNG (texture)
for i in range(50):
    run_fuzz_case(["texture", "--validate"], mutate(sample_ktx2), "ktx2", f"ktx2_{i}")
for i in range(30):
    out_ktx2 = os.path.join(work_dir, f"fuzz_out_{i}.ktx2")
    path = os.path.join(work_dir, f"fuzz_png_{i}.png")
    with open(path, "wb") as f:
        f.write(mutate(sample_png))
    proc = subprocess.run(
        [bin_path, "texture", path, "-o", out_ktx2],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if proc.returncode not in (0, 1):
        sys.stderr.write(f"FALHA DE FUZZ PNG case={i} exit={proc.returncode} stderr={proc.stderr!r}\n")
        sys.exit(1)

print("fuzz ok: 281 casos sem crash/OOB (apenas exit 0/1)")
PY

echo "test-caju-tools: todos os goldens, determinismo e fuzz passaram!"
