import CajuCore
import Testing

private final class Log { var items: [String] = [] }

private func sys(
    _ name: String, _ stage: CajuStage = .update, reads: [CajuComponentID] = [],
    writes: [CajuComponentID] = [],
    after: [String] = [], log: Log
) -> CajuSystemDescriptor {
    var r = CajuComponentMask.none
    var w = CajuComponentMask.none
    for id in reads { r = r.union(CajuComponentMask(id)) }
    for id in writes { w = w.union(CajuComponentMask(id)) }
    return CajuSystemDescriptor(name: name, stage: stage, reads: r, writes: w, after: after) { _ in
        log.items.append(name)
    }
}

@Suite("CajuScheduler")
struct CajuSchedulerTests {
    @Test func conflictingSystemsKeepRegistrationOrderAndIndependentOnesShareBatch() throws {
        let log = Log()
        let s = CajuScheduler(world: CajuWorld())
        try s.add(sys("move", writes: [Pos.componentID], log: log))
        try s.add(sys("health", writes: [Health.componentID], log: log))
        try s.add(sys("draw", reads: [Pos.componentID], log: log))
        try s.build()
        #expect(s.executionOrder(of: .update) == ["move", "health", "draw"])
        #expect(s.batches(of: .update) == [["move", "health"], ["draw"]])
        try s.tick(delta: 0.016)
        #expect(log.items == ["move", "health", "draw"])
    }

    @Test func explicitAfterReordersIndependentSystems() throws {
        let log = Log()
        let s = CajuScheduler(world: CajuWorld())
        try s.add(sys("a", after: ["b"], log: log))
        try s.add(sys("b", log: log))
        try s.build()
        #expect(s.executionOrder(of: .update) == ["b", "a"])
    }

    @Test func buildValidatesGraph() throws {
        let log = Log()
        var s = CajuScheduler(world: CajuWorld())
        try s.add(sys("a", log: log))
        #expect(throws: CajuSchedulerError.duplicateSystemName("a")) { try s.add(sys("a", log: log)) }

        s = CajuScheduler(world: CajuWorld())
        try s.add(sys("a", after: ["zzz"], log: log))
        #expect(throws: CajuSchedulerError.unknownDependency(system: "a", after: "zzz")) { try s.build() }

        s = CajuScheduler(world: CajuWorld())
        try s.add(sys("a", .update, after: ["b"], log: log))
        try s.add(sys("b", .preUpdate, log: log))
        #expect(throws: CajuSchedulerError.crossStageDependency(system: "a", after: "b")) { try s.build() }

        s = CajuScheduler(world: CajuWorld())
        try s.add(sys("a", after: ["b"], log: log))
        try s.add(sys("b", after: ["a"], log: log))
        #expect(throws: CajuSchedulerError.dependencyCycle(["a", "b"])) { try s.build() }

        s = CajuScheduler(world: CajuWorld())
        #expect(throws: CajuSchedulerError.notBuilt) { try s.tick(delta: 0.1) }
        try s.build()
        #expect(throws: CajuSchedulerError.alreadyBuilt) { try s.build() }
        #expect(throws: CajuSchedulerError.alreadyBuilt) { try s.add(sys("x", log: log)) }
    }

    @Test func stagesRunInOrderAndFixedStepAccumulates() throws {
        let log = Log()
        let s = CajuScheduler(world: CajuWorld(), fixedStep: 0.1, maxFixedSteps: 3)
        for stage in CajuStage.allCases.reversed() { try s.add(sys("\(stage)", stage, log: log)) }
        try s.build()
        try s.tick(delta: 0.25)  // 2 passos fixos, resta 0.05
        #expect(
            log.items == ["first", "fixedUpdate", "fixedUpdate", "preUpdate", "update", "postUpdate", "last"])
        log.items.removeAll()
        try s.tick(delta: 0.06)  // 0.11 acumulado: 1 passo
        #expect(log.items.filter { $0 == "fixedUpdate" }.count == 1)
        #expect(s.time.frame == 2)
        #expect(abs(s.time.elapsed - 0.31) < 1e-9)
    }

    @Test func undeclaredAccessIsReported() throws {
        let w = CajuWorld()
        _ = try w.spawn(Pos(x: 0, y: 0), Vel(x: 1, y: 1))
        let s = CajuScheduler(world: w)
        try s.add(
            CajuSystemDescriptor(
                name: "bad", reads: CajuComponentMask(Pos.componentID),
                writes: CajuComponentMask(Vel.componentID)
            ) { ctx throws(CajuAccessError) in
                try ctx.forEach(CajuWrite<Pos>.self) { _ in }  // só declarou ler Pos
            })
        try s.build()
        #expect(
            throws: CajuSchedulerError.accessViolation(
                system: "bad", component: Pos.componentID, isWrite: true)
        ) { try s.tick(delta: 0.016) }

        let s2 = CajuScheduler(world: w)
        try s2.add(
            CajuSystemDescriptor(name: "bad2", reads: CajuComponentMask(Pos.componentID)) {
                ctx throws(CajuAccessError) in
                try ctx.forEach(CajuRead<Health>.self) { _ in }
            })
        try s2.build()
        #expect(
            throws: CajuSchedulerError.accessViolation(
                system: "bad2", component: Health.componentID, isWrite: false)
        ) { try s2.tick(delta: 0.016) }
    }

    @Test func declaredAccessRunsAndCommandsApplyAtSync() throws {
        let w = CajuWorld()
        let e = try w.spawn(Pos(x: 0, y: 0), Vel(x: 1, y: 2))
        let s = CajuScheduler(world: w)
        try s.add(
            CajuSystemDescriptor(
                name: "integrate", reads: CajuComponentMask(Vel.componentID),
                writes: CajuComponentMask(Pos.componentID)
            ) { ctx throws(CajuAccessError) in
                let dt = Float(ctx.time.delta)
                try ctx.forEach(CajuWrite<Pos>.self, CajuRead<Vel>.self) { p, v in
                    p.value.x += v.x * dt
                    p.value.y += v.y * dt
                }
            })
        try s.add(
            CajuSystemDescriptor(
                name: "reaper", stage: .postUpdate, reads: CajuComponentMask(Pos.componentID)
            ) { ctx throws(CajuAccessError) in
                try ctx.forEach(CajuRead<Pos>.self) { _ in }
                ctx.commands.push(.despawn(e))
            })
        try s.build()
        try s.tick(delta: 0.5)
        #expect(!w.contains(e))
    }

    @Test func commandBufferDropsWhenFull() throws {
        let b = CajuCommandBuffer(capacity: 2)
        let e = CajuEntity(index: 0, generation: 0)
        #expect(b.push(.despawn(e)) && b.push(.despawn(e)) && !b.push(.despawn(e)))
        #expect(b.droppedCount == 1 && b.count == 2)
        b.apply(to: CajuWorld())  // entidades inválidas: ignoradas
        #expect(b.count == 0)
    }
}

@Suite("Tempo, mensagens e estados")
struct CajuSupportTests {
    @Test func fixedTimestepCapsCatchUp() {
        var f = CajuFixedTimestep(step: 0.01, maxSteps: 4)
        #expect(f.advance(by: 1.0) == 4)
        #expect(f.accumulator == 0)  // excesso descartado
        #expect(f.advance(by: -1) == 0 && f.advance(by: .nan) == 0)
        #expect(f.advance(by: 0.015) == 1)
        #expect(abs(f.alpha - 0.5) < 1e-9)
        #expect(CajuFixedTimestep(step: 0).step == 1.0 / 60.0)
    }

    @Test func messagesAreVisibleAfterSwapAndBounded() {
        let q = CajuMessageQueue<Int32>(capacity: 3)
        for i in 0..<5 { q.send(Int32(i)) }
        #expect(q.droppedCount == 2 && q.readCount == 0)
        q.swap()
        var seen: [Int32] = []
        q.forEachMessage { seen.append($0) }
        #expect(seen == [0, 1, 2] && q[1] == 1 && q[3] == nil && q[-1] == nil)
        q.send(9)
        q.swap()
        #expect(q.readCount == 1 && q[0] == 9)
        q.swap()
        #expect(q.readCount == 0)
    }

    @Test func stateMachineDefersAndCancels() {
        var s = CajuStateMachine(initial: 0)
        #expect(s.consumeTransition() == nil)
        s.request(1)
        s.request(2)
        #expect(s.current == 0 && s.pending == 2)
        let t = s.consumeTransition()
        #expect(t?.from == 0 && t?.to == 2 && s.current == 2 && s.pending == nil)
        s.request(5)
        s.request(2)  // volta ao atual: cancela
        #expect(s.consumeTransition() == nil)
    }
}
