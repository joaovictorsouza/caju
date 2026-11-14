#if os(Android)
    import CVulkan
#endif

/// Log da plataforma: `logcat` (tag `Caju`) no Android; no-op nas demais.
/// Não use no caminho quente (aloca `String`).
public func cajuLog(_ message: String) {
    #if os(Android)
        _ = message.withCString { __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), "Caju", $0) }
    #endif
}
