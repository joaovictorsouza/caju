/// Áudio multiplataforma sobre `miniaudio` (`CMiniaudio`).
///
/// Módulo da Camada 3 responsável pela engine de áudio, decodificação em memória, fontes 2D/3D,
/// buses de mixagem e integração com ciclo de vida sem alocação no *callback* de áudio.
public enum CajuAudioModule {}

/// Erro tipado de todas as operações do `CajuAudio` (`throws(CajuAudioError)`).
///
/// Os casos carregam contexto estruturado sem alocar `String` no caminho quente.
public enum CajuAudioError: Error, Sendable, Equatable {
    /// A engine já foi encerrada (`shutdown()`).
    case alreadyShutdown
    /// Um parâmetro ou descritor viola limites ou invariantes do módulo.
    case invalidConfiguration(CajuAudioConfigurationIssue)
    /// Handle nulo, expirado (outra geração) ou de recurso já destruído.
    case invalidHandle(index: UInt32, generation: UInt32)
    /// Dados codificados ou PCM inválidos ou corrompidos.
    case invalidData
    /// Formato de áudio não suportado pelo decodificador ou dispositivo.
    case unsupportedFormat
    /// Arquivo não encontrado ao carregar clipe.
    case fileNotFound
    /// Permissão negada ao acessar arquivo ou dispositivo de áudio.
    case accessDenied
    /// Sem memória disponível para alocar o recurso.
    case outOfMemory
    /// Nenhum backend ou dispositivo de áudio disponível, ou falha ao iniciar dispositivo.
    case deviceUnavailable
    /// Operação inválida no estado atual (ex.: `renderFrames` em modo com dispositivo).
    case invalidState
    /// Limite interno de capacidade de handles atingido.
    case capacityExceeded
    /// Erro retornado pelo backend `miniaudio` não mapeado para caso específico.
    case backend(code: Int32)
}

/// Motivos pelos quais uma configuração ou descritor de áudio é rejeitado.
public enum CajuAudioConfigurationIssue: UInt8, Sendable, Equatable {
    case invalidSampleRate
    case invalidChannelCount
    case invalidListenerCount
    case emptyBuffer
    case sampleCountMismatch
    case invalidDistanceRange
    case invalidConeAngles
    case invalidVolume
    case invalidPitch
    case invalidPan
    case invalidRolloff
    case nonFiniteValue
    case invalidFormat
    case unsupportedInOfflineMode
    case unsupportedInDeviceMode
}
