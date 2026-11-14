#!/usr/bin/env bash
# Rejeita construções proibidas em código de engine (CLAUDE.md, docs/standards/codigo-swift.md):
# `try!`, `fatalError`, `precondition` e `as!`. Testes são isentos.
# Exceção pontual: comentário `// caju-allow: <motivo>` na mesma linha (revisar no PR).
set -euo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rnE '(try!|as!|\bfatalError\(|\bprecondition\()' Sources --include='*.swift' | grep -v 'caju-allow:' || true)
if [ -n "$hits" ]; then
  echo "Construções proibidas encontradas:"; echo "$hits"; exit 1
fi
echo "check-forbidden: ok"
