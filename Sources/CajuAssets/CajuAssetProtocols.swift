import CajuAssetsCore

/// Fonte de bytes de assets (disco, *bundle*, CDN). Implementada nas bordas; é onde Foundation/rede podem viver.
///
/// A leitura roda **fora do quadro** (`async`), em contexto não isolado ao ator do jogo.
public protocol CajuAssetSource: Sendable {
    func read(_ path: CajuAssetPath) async throws(CajuAssetError) -> [UInt8]
}

/// Fonte que avisa quando um arquivo muda (*hot reload* local, só em desenvolvimento).
///
/// O servidor assina `changes()` e recarrega os caminhos já carregados. Produção não precisa implementar.
public protocol CajuAssetWatching: CajuAssetSource {
    func changes() -> AsyncStream<CajuAssetPath>
}

/// Converte bytes em um asset de tipo `Asset`. Usa os parsers de `CajuAssetsCore` e valida com `AssetLimits`.
///
/// Roda fora do quadro (`async`); o resultado só é publicado no limite do quadro, nunca no meio dele.
public protocol CajuAssetLoader: Sendable {
    associatedtype Asset: CajuAsset
    func load(
        _ bytes: [UInt8], path: CajuAssetPath, limits: AssetLimits
    ) async throws(CajuAssetError) -> Asset
}

/// Contrato público do `AssetServer` (A-1). O tipo concreto chega na implementação; consumidores
/// (R-1, AN-1) dependem só deste protocolo e dos tipos de handle/estado.
///
/// **Modelo de *threads* (ADR 0021):** o servidor pertence à *thread* do jogo, como o `CajuWorld` (ADR 0003 e
/// 0008). Consultas (`state`, `value`, `error`, `revision`) são síncronas, não bloqueiam e não alocam.
/// Leitura e decodificação rodam em tarefas fora do quadro; o resultado entra por uma caixa de correio e é
/// aplicado em `applyCompletions()`, chamado uma vez por quadro, antes das consultas do quadro.
public protocol CajuAssetServing: AnyObject {
    /// Pede o asset. Deduplica por (tipo, caminho): o mesmo par devolve o mesmo handle e soma uma posse.
    /// Nunca falha na hora: erros aparecem como `state == .failed` e `error(of:)`.
    func load<A: CajuAsset>(_ type: A.Type, path: CajuAssetPath) -> CajuAssetHandle<A>

    /// Estado atual; `.stale` para handle velho ou `invalid`. Não aloca.
    func state<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetState
    /// Valor, se `state.hasValue`. Não aloca (só retém referência, se `A` for classe). Durante `reloading`
    /// devolve o valor antigo.
    func value<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> A?
    /// Último erro de carga ou de recarga; limpo por uma carga bem-sucedida.
    func error<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetError?
    /// Incrementa a cada valor publicado (1 na primeira carga). Permite a consumidores detectar troca
    /// (por exemplo, recriar buffer de GPU após *hot reload*). `0` se não houver valor ou o handle for velho.
    func revision<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> UInt32

    /// Soma uma posse. `false` se o handle for velho.
    @discardableResult func retain<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool
    /// Tira uma posse. Ao chegar a zero o slot é liberado no próximo `applyCompletions()`: o valor cai,
    /// a geração sobe e o handle vira `.stale`. `false` se o handle já era velho.
    @discardableResult func release<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool

    /// Recarrega o caminho (se carregado) mantendo o mesmo handle. Chamado pelo *hot reload*, ou à mão.
    func reload(path: CajuAssetPath)

    /// Aplica resultados de carga concluídos e libera slots sem posse. **Único ponto** onde o estado muda.
    /// Chamar uma vez por quadro, no início.
    func applyCompletions()
    /// Entrega e esvazia os eventos produzidos desde a última chamada. Sem alocação.
    func drainEvents(_ body: (CajuAssetEvent) -> Void)
}
