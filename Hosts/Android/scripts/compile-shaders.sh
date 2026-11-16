#!/bin/sh
# Compila os GLSL de Hosts/Android/shaders para SPIR-V e gera os arquivos Swift com as palavras:
# - shaders/triangle.{vert,frag}        → Hosts/Android/Sources/CajuAndroidHost/TriangleShaders.swift
# - shaders/conformance/*.{vert,frag}   → Hosts/Android/Sources/CajuConformanceRunner/ConformanceShaders.swift
# Requer glslc (Vulkan SDK ou NDK em shader-tools/).
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
shaders="$root/Hosts/Android/shaders"

words() { glslc -O -mfmt=num -o - "$1" | tr -d '\n' | sed 's/,$//; s/,/, /g'; }

generate() {  # $1 = saída, $2 = nome do enum, $3 = doc, depois pares "nome arquivo"
  out="$1"; name="$2"; doc="$3"; shift 3
  {
    echo "// GERADO por Hosts/Android/scripts/compile-shaders.sh a partir de Hosts/Android/shaders. Não edite."
    echo ""
    echo "/// $doc"
    echo "enum $name {"
    first=1
    while [ $# -gt 0 ]; do
      [ $first -eq 1 ] || echo ""
      first=0
      echo "    static let $1: [UInt32] = [$(words "$2")]"
      shift 2
    done
    echo "}"
  } > "$out"
  swift format format -i "$out"
  echo "gerado $out"
}

generate "$root/Hosts/Android/Sources/CajuAndroidHost/TriangleShaders.swift" TriangleShaders \
  "SPIR-V do triângulo do host (vertex e fragment)." \
  vertex "$shaders/triangle.vert" fragment "$shaders/triangle.frag"

generate "$root/Hosts/Android/Sources/CajuConformanceRunner/ConformanceShaders.swift" ConformanceShaders \
  "SPIR-V do triângulo de conformidade do RHI (\`CajuConformanceBackend.makeTriangleShaders\`)." \
  vertex "$shaders/conformance/triangle.vert" fragment "$shaders/conformance/red.frag"
