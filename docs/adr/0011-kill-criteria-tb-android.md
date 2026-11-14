# ADR 0011: Kill-criteria do TB-Android

**Status:** Aceito (decisão do dono em 2026-11-14). Revisa o limite de 5 dias do [ADR 0006](0006-ordem-de-execucao.md) (que continua valendo no restante).

## Contexto
O ADR 0006 exigia kill-criteria explícitos, definidos antes do início do TB-Android (Swift no Android + Vulkan próprio no Galaxy S22+ Snapdragon). A proposta do brief era: sem triângulo no dia 3 ou sem `.apk` rodando no dia 5, parar.

## Decisão
- O TB-Android é **interrompido se ultrapassar 3 dias** de trabalho (limite do dono, mais curto que os 5 dias do ADR 0006).
- "Interromper" significa: encerrar a trilha, registrar o que foi aprendido (SDK, build, Vulkan) e **reabrir os ADRs 0001/0008** para decidir o próximo passo. iOS/macOS e os módulos puros seguem sem esperar.
- O que conta como "dia" e o que é "concluído" (ex.: triângulo no S22+) fica no brief da trilha; o relógio começa quando a trilha é iniciada.

## Alternativas
Manter 5 dias (rejeitado pelo dono); critérios por marco intermediário (triângulo no dia 3, `.apk` no dia 5): substituídos pelo limite total único.

## Consequências
Risco de parar antes de resolver arestas do Swift SDK for Android; mitigado por registrar achados e reabrir ADRs, em vez de perder o aprendizado.

## Quando reabrir
Se o primeiro ciclo mostrar que 3 dias é irrealista para o escopo mínimo (triângulo no aparelho), ou após a decisão pós-interrupção.
