#if os(Android)
    import CVulkan

    /// Ponte NativeActivity → Game Thread (ADR 0008).
    ///
    /// Os *callbacks* da `ANativeActivity` chegam na UI thread do Java; aqui eles só
    /// enfileiram eventos. O jogo roda inteiro numa ``CajuGameThread`` própria.
    public enum CajuAndroidActivity {
        /// Chame de `ANativeActivity_onCreate` (símbolo exportado pelo host).
        ///
        /// - Parameters:
        ///   - activity: o `ANativeActivity*` recebido.
        ///   - main: corpo da Game Thread; deve chamar ``CajuAndroidGameLoop/run(channel:delegate:)``.
        public static func onCreate(
            activity rawActivity: UnsafeMutableRawPointer,
            main: @escaping @Sendable (CajuAndroidChannel) -> Void
        ) {
            let activity = rawActivity.assumingMemoryBound(to: ANativeActivity.self)
            guard let channel = try? CajuAndroidChannel() else {
                cajuLog("falha ao criar o canal de eventos")
                return
            }
            let state = CajuAndroidActivityState(channel: channel)
            let thread = CajuGameThread(name: "CajuGame") { main(channel) }
            state.thread = thread
            guard (try? thread.start()) != nil else {
                cajuLog("falha ao criar a Game Thread")
                return
            }
            activity.pointee.instance = Unmanaged.passRetained(state).toOpaque()

            let callbacks = activity.pointee.callbacks!
            callbacks.pointee.onStart = { push($0, .started) }
            callbacks.pointee.onResume = { push($0, .resumed) }
            callbacks.pointee.onPause = { push($0, .paused) }
            callbacks.pointee.onStop = { push($0, .stopped) }
            callbacks.pointee.onLowMemory = { push($0, .lowMemory) }
            callbacks.pointee.onWindowFocusChanged = { push($0, .focusChanged($1 != 0)) }
            callbacks.pointee.onSaveInstanceState = { _, outSize in
                outSize?.pointee = 0
                return nil
            }
            callbacks.pointee.onNativeWindowCreated = { activity, window in
                guard let window else { return }
                push(activity, .surfaceCreated(CajuNativeWindow(raw: UnsafeMutableRawPointer(window))))
            }
            callbacks.pointee.onNativeWindowResized = { activity, _ in push(activity, .surfaceResized) }
            callbacks.pointee.onNativeWindowDestroyed = { activity, _ in
                guard let state = stateOf(activity) else { return }
                state.channel.events.push(.surfaceDestroyed)
                // A janela só pode ser liberada pelo sistema depois que a Game Thread a soltou.
                if !state.channel.surfaceReleased.wait(timeoutMilliseconds: 2000) {
                    cajuLog("timeout esperando a Game Thread soltar a janela")
                }
            }
            callbacks.pointee.onInputQueueCreated = { activity, queue in
                guard let queue else { return }
                push(activity, .inputQueueCreated(CajuNativeInputQueue(raw: UnsafeMutableRawPointer(queue))))
            }
            callbacks.pointee.onInputQueueDestroyed = { activity, _ in
                guard let state = stateOf(activity) else { return }
                state.channel.events.push(.inputQueueDestroyed)
                if !state.channel.inputReleased.wait(timeoutMilliseconds: 2000) {
                    cajuLog("timeout esperando a Game Thread soltar a fila de entrada")
                }
            }
            callbacks.pointee.onDestroy = { activity in
                guard let activity, let raw = activity.pointee.instance else { return }
                let state = Unmanaged<CajuAndroidActivityState>.fromOpaque(raw).takeRetainedValue()
                state.channel.events.push(.destroyed)
                state.thread?.join()
                activity.pointee.instance = nil
            }
        }
    }

    private final class CajuAndroidActivityState: @unchecked Sendable {
        let channel: CajuAndroidChannel
        var thread: CajuGameThread?
        init(channel: CajuAndroidChannel) { self.channel = channel }
    }

    private func stateOf(_ activity: UnsafeMutablePointer<ANativeActivity>?) -> CajuAndroidActivityState? {
        guard let raw = activity?.pointee.instance else { return nil }
        return Unmanaged<CajuAndroidActivityState>.fromOpaque(raw).takeUnretainedValue()
    }

    private func push(_ activity: UnsafeMutablePointer<ANativeActivity>?, _ event: CajuAndroidEvent) {
        stateOf(activity)?.channel.events.push(event)
    }
#endif
