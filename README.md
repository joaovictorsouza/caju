# caju

Engine 3D multiplataforma em Swift. Veja `CLAUDE.md` e `docs/planejamento-engine.md`.

```sh
swift build && swift test            # Linux/macOS
swift run -c release caju-bench      # benchmarks (JSON)
swift format lint --strict -r Sources Tests Package.swift && scripts/check-forbidden.sh
```
