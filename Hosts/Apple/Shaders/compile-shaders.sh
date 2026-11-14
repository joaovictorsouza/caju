#!/usr/bin/env bash
# Slang -> MSL offline (ADR 0001). Um arquivo .metal por ponto de entrada, porque o Slang numera os
# bindings por módulo e perde os uniformes do estágio de vértice quando vários pontos de entrada saem
# juntos (slangc 2026.8). Saída determinística em Generated/; o Xcode compila os .metal no metallib do app.
# Bindings resultantes: cubeUniforms = buffer(0); uiUniforms = buffer(1); atlas = texture(0); sampler(0).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Generated
compile() { slangc demo.slang -target metal -entry "$1" -stage "$2" -o "Generated/$1.metal"; }
compile cubeVertex vertex
compile cubeFragment fragment
compile uiVertex vertex
compile uiFragment fragment
echo "shaders: ok ($(slangc -version))"
