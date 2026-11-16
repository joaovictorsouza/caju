internal import CMiniaudio

/// Callback de áudio em C puro (`@convention(c)`).
///
/// Garantias de ausência de alocação no caminho em tempo real:
/// 1. `@convention(c)` impede por compilação qualquer captura de contexto ou *closure* Swift.
/// 2. `pUserData` aponta diretamente para `ma_engine` alocado manualmente (sem objeto ARC nem `Unmanaged`).
/// 3. Nenhuma coleção Swift (`Array`, `Dictionary`, `String`), nenhuma alocação e nenhum *lock* Swift
///    existem neste corpo: apenas leitura direta do grafo do `miniaudio`.
let cajuAudioDataCallback: ma_device_data_proc = { device, framesOut, _, frameCount in
    guard let device, let framesOut, let userData = device.pointee.pUserData else {
        return
    }
    let engine = userData.assumingMemoryBound(to: ma_engine.self)
    ma_engine_read_pcm_frames(engine, framesOut, UInt64(frameCount), nil)
}

enum CajuAudioMiniaudioMap {
    static func check(_ result: ma_result) throws(CajuAudioError) {
        if result == MA_SUCCESS {
            return
        }
        throw mapError(result)
    }

    static func mapError(_ result: ma_result) -> CajuAudioError {
        switch result {
        case MA_OUT_OF_MEMORY:
            return .outOfMemory
        case MA_DOES_NOT_EXIST:
            return .fileNotFound
        case MA_ACCESS_DENIED:
            return .accessDenied
        case MA_INVALID_DATA, MA_CRC_MISMATCH:
            return .invalidData
        case MA_FORMAT_NOT_SUPPORTED, MA_INVALID_FILE:
            return .unsupportedFormat
        case MA_NO_DEVICE, MA_NO_BACKEND, MA_API_NOT_FOUND, MA_BACKEND_NOT_ENABLED,
            MA_FAILED_TO_INIT_BACKEND, MA_FAILED_TO_OPEN_BACKEND_DEVICE,
            MA_FAILED_TO_START_BACKEND_DEVICE, MA_FAILED_TO_STOP_BACKEND_DEVICE,
            MA_UNAVAILABLE:
            return .deviceUnavailable
        case MA_INVALID_OPERATION, MA_DEVICE_NOT_INITIALIZED, MA_DEVICE_ALREADY_INITIALIZED,
            MA_DEVICE_NOT_STARTED, MA_DEVICE_NOT_STOPPED:
            return .invalidState
        case MA_INVALID_ARGS, MA_OUT_OF_RANGE, MA_INVALID_DEVICE_CONFIG:
            return .invalidConfiguration(.invalidFormat)
        default:
            return .backend(code: result.rawValue)
        }
    }

    static func attenuationModel(_ model: CajuAudioAttenuationModel) -> ma_attenuation_model {
        switch model {
        case .none: return ma_attenuation_model_none
        case .inverse: return ma_attenuation_model_inverse
        case .linear: return ma_attenuation_model_linear
        case .exponential: return ma_attenuation_model_exponential
        }
    }

    static func positioning(_ positioning: CajuAudioPositioning) -> ma_positioning {
        switch positioning {
        case .absolute: return ma_positioning_absolute
        case .relative: return ma_positioning_relative
        }
    }
}
