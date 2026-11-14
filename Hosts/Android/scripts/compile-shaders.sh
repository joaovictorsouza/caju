#!/bin/sh
# Compila Hosts/Android/shaders/*.{vert,frag} para SPIR-V e gera
# Sources/CajuRHIVulkan/CajuVulkanTriangleShaders.swift. Requer glslc (Vulkan SDK/NDK).
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
shaders="$root/Hosts/Android/shaders"
out="$root/Sources/CajuRHIVulkan/CajuVulkanTriangleShaders.swift"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

words() { glslc -O -mfmt=num -o - "$1" | tr -d '\n' | sed 's/,$//; s/,/, /g'; }

{
  echo "// GERADO por Hosts/Android/scripts/compile-shaders.sh a partir de Hosts/Android/shaders. Não edite."
  echo ""
  echo "/// SPIR-V do triângulo (vertex e fragment)."
  echo "enum CajuVulkanTriangleShaders {"
  echo "    static let vertex: [UInt32] = [$(words "$shaders/triangle.vert")]"
  echo ""
  echo "    static let fragment: [UInt32] = [$(words "$shaders/triangle.frag")]"
  echo "}"
} > "$out"
echo "gerado $out"
swift format format -i "$out"
