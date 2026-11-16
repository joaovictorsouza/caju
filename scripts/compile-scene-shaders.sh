#!/bin/sh
# Compila os shaders de cena da R-1a (Shaders/CajuRender/*.vert|frag) para SPIR-V e gera
# Sources/CajuRender/CajuSceneShaderSPIRV.swift. Requer glslc (Vulkan SDK ou NDK). O MSL equivalente é
# mantido à mão em Sources/CajuRender/CajuSceneShaderMSL.swift (Slang unifica os dois depois; ADR 0001).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/Shaders/CajuRender"
out="$root/Sources/CajuRender/CajuSceneShaderSPIRV.swift"
words() { glslc -O -mfmt=num -o - "$1" | tr -d '\n' | sed 's/,$//; s/,/, /g'; }
{
  echo "// GERADO por scripts/compile-scene-shaders.sh a partir de Shaders/CajuRender. Não edite."
  echo ""
  echo "/// SPIR-V dos shaders de cena (Vulkan)."
  echo "enum CajuSceneShaderSPIRV {"
  echo "    static let vertex: [UInt32] = [$(words "$src/scene.vert")]"
  echo ""
  echo "    static let fragment: [UInt32] = [$(words "$src/scene.frag")]"
  echo ""
  echo "    static let skinnedVertex: [UInt32] = [$(words "$src/scene_skinned.vert")]"
  echo "}"
} > "$out"
swift format format -i "$out"
echo "gerado $out"
