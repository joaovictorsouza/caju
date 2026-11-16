import CajuCore
import CajuScene

/// Clipes, player, *crossfade*, máscaras e amostragem SIMD de animação esquelética (AN-1).
///
/// Mantém o tipo marcador `CajuAnimModule` para verificação de linkagem em `CajuModulesTests`.
public enum CajuAnimModule {}

/// Ponto de entrada e sistema ECS de animação esquelética.
public enum CajuAnim {
    /// Limite máximo de juntas por esqueleto no MVP: 128 `(?)`.
    public static let maxJointCount = Int(CajuPoseArena.maxJointCount)

    /// Cria o sistema ECS que avança `CajuAnimPlayback`, aplica *cull* fora da tela e grava
    /// poses em espaço do modelo (sem `inverseBind`) na `CajuPoseArena`, sem alocação no quadro estável.
    ///
    /// - Parameters:
    ///   - library: Repositório de esqueletos, clipes e *scratch buffer* pré-alocado.
    ///   - arena: Arena contígua do mundo onde as matrizes em espaço do modelo são gravadas.
    ///   - stage: Estágio do `CajuScheduler` em que o sistema executa (padrão `.update`).
    ///   - advanceTimeWhenCulled: Se `true` (padrão), o relógio da animação continua avançando
    ///     mesmo quando a amostragem é pulada pelo *cull* fora da tela.
    ///   - filter: Filtro opcional de consulta (por exemplo, excluir entidades com *tag* de *cull*).
    ///   - shouldSample: *Hook* opcional de *cull*; retorna `false` para pular a amostragem e a
    ///     escrita na arena. Além dele, `playback.isCulled == true` também pula a amostragem.
    public static func poseUpdateSystem(
        library: CajuAnimLibrary,
        arena: CajuPoseArena,
        stage: CajuStage = .update,
        advanceTimeWhenCulled: Bool = true,
        filter: CajuQueryFilter = .none,
        shouldSample: @escaping (CajuAnimPlayback, CajuSkinPose) -> Bool = { playback, _ in !playback.isCulled
        }
    ) -> CajuSystemDescriptor {
        CajuSystemDescriptor(
            name: "CajuAnim.poseUpdate",
            stage: stage,
            reads: .none,
            writes: CajuComponentMask(CajuAnimPlayback.componentID, CajuSkinPose.componentID)
        ) { ctx throws(CajuAccessError) in
            library.resetFrameCounters()
            let dt = Float(ctx.time.delta)

            try ctx.forEach(
                CajuWrite<CajuAnimPlayback>.self,
                CajuWrite<CajuSkinPose>.self,
                filter: filter
            ) { playbackRef, poseRef in
                var pb = playbackRef.value
                guard let skeleton = library.skeleton(at: pb.skeletonID) else {
                    library.recordError(.skeletonIndexOutOfBounds(Int(pb.skeletonID)))
                    return
                }
                guard let clip = library.clip(at: pb.clipID) else {
                    library.recordError(.clipIndexOutOfBounds(Int(pb.clipID)))
                    return
                }

                let prevClip = pb.isCrossfading ? library.clip(at: pb.previousClipID) : nil
                let allowSample = !pb.isCulled && shouldSample(pb, poseRef.value)

                if allowSample || advanceTimeWhenCulled {
                    pb.advance(
                        by: dt,
                        currentDuration: clip.duration,
                        previousDuration: prevClip?.duration
                    )
                }
                playbackRef.value = pb

                guard allowSample else {
                    library.recordCulled()
                    return
                }

                var pose = poseRef.value
                do throws(CajuAnimError) {
                    if pb.isCrossfading, let prevClip {
                        let weights = pb.crossfadeWeights
                        try CajuAnimSampler.sampleCrossfadeAndWrite(
                            fromClip: prevClip,
                            fromTime: pb.previousTime,
                            fromMask: pb.previousMask,
                            toClip: clip,
                            toTime: pb.time,
                            toMask: pb.mask,
                            weight: weights.to,
                            skeleton: skeleton,
                            isCulled: false,
                            into: &pose,
                            arena: arena,
                            scratch: &library.scratch
                        )
                    } else {
                        try CajuAnimSampler.sampleAndWrite(
                            clip: clip,
                            time: pb.time,
                            skeleton: skeleton,
                            mask: pb.mask,
                            isCulled: false,
                            into: &pose,
                            arena: arena,
                            scratch: &library.scratch
                        )
                    }
                    poseRef.value = pose
                    library.recordSampled()
                } catch {
                    library.recordError(error)
                }
            }
        }
    }
}
