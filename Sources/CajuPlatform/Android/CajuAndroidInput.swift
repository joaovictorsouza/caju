#if os(Android)
    import CVulkan

    /// Lê toques de uma `AInputQueue` anexada ao `ALooper` da Game Thread.
    struct CajuAndroidInput {
        private var queue: OpaquePointer?

        mutating func attach(_ native: CajuNativeInputQueue) {
            let looper = ALooper_prepare(Int32(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS))
            let queue = OpaquePointer(native.raw)
            AInputQueue_attachLooper(queue, looper, 1, nil, nil)
            self.queue = queue
        }

        mutating func detach() {
            if let queue { AInputQueue_detachLooper(queue) }
            queue = nil
        }

        /// Entrega os toques pendentes, sem bloquear nem alocar.
        func drain(_ sink: (CajuTouchEvent) -> Void) {
            guard let queue else { return }
            _ = ALooper_pollOnce(0, nil, nil, nil)
            var event: OpaquePointer?
            while AInputQueue_getEvent(queue, &event) >= 0 {
                guard let event else { continue }
                defer { AInputQueue_finishEvent(queue, event, 0) }
                if AInputQueue_preDispatchEvent(queue, event) != 0 { continue }
                guard AInputEvent_getType(event) == Int32(AINPUT_EVENT_TYPE_MOTION) else { continue }
                let action = AMotionEvent_getAction(event)
                let masked = action & Int32(AMOTION_EVENT_ACTION_MASK)
                let index = Int(
                    (action & Int32(AMOTION_EVENT_ACTION_POINTER_INDEX_MASK))
                        >> Int32(AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT))
                let phase: CajuTouchPhase
                switch masked {
                case Int32(AMOTION_EVENT_ACTION_DOWN), Int32(AMOTION_EVENT_ACTION_POINTER_DOWN):
                    phase = .began
                case Int32(AMOTION_EVENT_ACTION_UP), Int32(AMOTION_EVENT_ACTION_POINTER_UP): phase = .ended
                case Int32(AMOTION_EVENT_ACTION_CANCEL): phase = .cancelled
                case Int32(AMOTION_EVENT_ACTION_MOVE): phase = .moved
                default: continue
                }
                let count = AMotionEvent_getPointerCount(event)
                let isMove = phase == .moved
                for pointer in (isMove ? 0 : index)..<(isMove ? count : index + 1) {
                    sink(
                        CajuTouchEvent(
                            phase: phase,
                            pointerID: AMotionEvent_getPointerId(event, pointer),
                            x: AMotionEvent_getX(event, pointer),
                            y: AMotionEvent_getY(event, pointer)))
                }
            }
        }
    }
#endif
