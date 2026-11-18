import CajuCore
import CajuMath
import CajuScene

extension CajuPhysics {
    /// Integra `CajuKinematicBody` no `CajuTransform` (estágio `update`, antes da propagação de transform).
    ///
    /// Posição `+= v·dt`; rotação `= normalize(q(eixo, |ω|·dt) · rotação)`. Sem colisão nem resposta.
    public static func kinematicSystem() -> CajuSystemDescriptor {
        CajuSystemDescriptor(
            name: "CajuPhysics.kinematic", stage: .update,
            reads: CajuComponentMask(CajuKinematicBody.componentID),
            writes: CajuComponentMask(CajuTransform.componentID)
        ) { ctx throws(CajuAccessError) in
            let dt = Float(ctx.time.delta)
            try ctx.forEach(CajuRead<CajuKinematicBody>.self, CajuWrite<CajuTransform>.self) { body, t in
                t.value.positionStorage += body.linearVelocity * dt
                let w = body.angularVelocity
                let speed = (w * w).sum().squareRoot()
                if speed > 0, speed.isFinite,
                    let dq = CajuQuat(axis: CajuVec3(storage: w / speed), radians: speed * dt)
                {
                    let r = t.value.rotation
                    t.value.rotation = (dq * r).normalized() ?? r
                }
            }
        }
    }
}

/// Espaço de nomes dos sistemas de física (consultas no ECS e kinematic; ver `README.md`).
public enum CajuPhysics {}
