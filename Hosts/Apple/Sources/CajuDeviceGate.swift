import CajuPlatform
import CajuRHI
import CajuRHIMetal
import Foundation

/// Gate de aparelho (S-0, ADR 0006): com `-caju-gate` o host mede, sem intervenção humana,
/// (1) p50/p95 do quadro em regime estável e (2) 50 ciclos de liberar/recriar a superfície com
/// tamanho alternado (rotação), reportando ΔRSS e recursos vivos. Saída em `print` (linhas `CAJU-GATE`),
/// lida com `xcrun devicectl device process launch --console`.
struct CajuDeviceGate {
    private enum Phase { case warmup, soak, cycles, done }
    private var phase = Phase.warmup
    private var frame = 0
    private var cycle = 0
    private var frameMillis: [Double] = []
    private var cpuMillisSamples: [Double] = []
    private var rssBefore = 0
    private var resourcesBefore = 0
    private var rssSoakStart = 0

    static let warmupFrames = 120
    /// 5 min a 60 Hz por padrão (ADR 0006); `-caju-soak-frames N` sobrescreve.
    static let soakFrames: Int = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-caju-soak-frames"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        return 18000
    }()
    static let cycleCount = 50

    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    mutating func step(gpu: CajuDemoGPU, base: CajuSurfaceDescriptor, tick: CajuFrameTick, cpuMillis: Double, taps: Int) {
        switch phase {
        case .warmup:
            frame += 1
            if frame == 1 { Self.log("CAJU-GATE start model=\(CajuDeviceGate.model())") }
            if frame >= Self.warmupFrames {
                phase = .soak
                frame = 0
                rssSoakStart = Self.residentBytes()
            }
        case .soak:
            frame += 1
            frameMillis.append(tick.deltaSeconds * 1000)
            cpuMillisSamples.append(cpuMillis)
            if frame >= Self.soakFrames {
                let sorted = frameMillis.sorted()
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count) * 0.95)]
                let cpu = cpuMillisSamples.sorted()
                let cpuP50 = cpu[cpu.count / 2]
                let cpuP95 = cpu[Int(Double(cpu.count) * 0.95)]
                let rssDelta = Double(Self.residentBytes() - rssSoakStart) / 1_048_576
                Self.log(
                    "CAJU-GATE soak frames=\(frame) p50_ms=\(p50) p95_ms=\(p95) max_ms=\(sorted.last ?? 0) "
                        + "cpu_p50_ms=\(cpuP50) cpu_p95_ms=\(cpuP95) cpu_max_ms=\(cpu.last ?? 0) "
                        + "thermal=\(ProcessInfo.processInfo.thermalState.rawValue) deltaRSS_MB=\(rssDelta) taps=\(taps)")
                phase = .cycles
                resourcesBefore = gpu.device.liveResourceCount
                rssBefore = Self.residentBytes()
            }
        case .cycles:
            gpu.releaseSurface()  // "vai para segundo plano"
            var d = base
            let shrink = cycle % 2 == 0 ? 64 : 0  // alterna o tamanho (rotação)
            d.pixelWidth = max(64, base.pixelWidth - shrink)
            d.pixelHeight = max(64, base.pixelHeight - shrink)
            do { try gpu.recreateSurface(d) } catch { Self.log("CAJU-GATE cycle \(cycle) erro: \(error)") }
            cycle += 1
            if cycle >= Self.cycleCount {
                phase = .done
                let delta = Double(Self.residentBytes() - rssBefore) / 1_048_576
                Self.log(
                    "CAJU-GATE cycles=\(cycle) deltaRSS_MB=\(delta) resources=\(resourcesBefore)->"
                        + "\(gpu.device.liveResourceCount) allocatedBytes=\(gpu.device.allocatedBytes)")
                Self.log("CAJU-GATE done")
            }
        case .done:
            break
        }
    }

    /// `print` e arquivo em Documents (`gate.log`), para ler com `devicectl device copy from` se o console cair.
    static func log(_ line: String) {
        print(line)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("gate.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func model() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
