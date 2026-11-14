import CajuCore
import CajuTesting
import Testing

struct Pos: CajuComponent, Equatable {
    static let componentID = CajuComponentID(20)
    var x: Float
    var y: Float
}
struct Vel: CajuComponent, Equatable {
    static let componentID = CajuComponentID(21)
    var x: Float
    var y: Float
}
struct Health: CajuComponent, Equatable {
    static let componentID = CajuComponentID(22)
    var hp: Int32
}
/// Mesmo ID de `Pos`, tipo diferente: conflito.
struct Clash: CajuComponent {
    static let componentID = CajuComponentID(20)
    var a: Int32
}
struct BadID: CajuComponent {
    static let componentID = CajuComponentID(64)
    var a: Int32
}
struct Dead: CajuTag { static let tagID = CajuTagID(1) }
struct Stunned: CajuTag { static let tagID = CajuTagID(2) }

@Suite("CajuWorld")
struct CajuWorldTests {
    @Test func spawnGetSetDespawn() throws {
        let w = CajuWorld()
        let e = try w.spawn(Pos(x: 1, y: 2), Vel(x: 3, y: 4))
        #expect(w.get(Pos.self, of: e) == Pos(x: 1, y: 2))
        #expect(w.has(Vel.self, e) && !w.has(Health.self, e))
        #expect(w.set(Pos(x: 9, y: 9), on: e))
        #expect(w.get(Pos.self, of: e) == Pos(x: 9, y: 9))
        try w.despawn(e)
        #expect(w.get(Pos.self, of: e) == nil)
        #expect(!w.contains(e))
        #expect(w.entityCount == 0)
        #expect(throws: CajuWorldError.staleEntity(e)) { try w.despawn(e) }
    }

    @Test func generationInvalidatesRecycledSlot() throws {
        let w = CajuWorld()
        let a = try w.spawn(Health(hp: 1))
        try w.despawn(a)
        let b = try w.spawn(Health(hp: 2))
        #expect(b.index == a.index && b.generation != a.generation)
        #expect(w.get(Health.self, of: a) == nil)
        #expect(w.get(Health.self, of: b) == Health(hp: 2))
    }

    @Test func swapRemoveKeepsOtherEntitiesIntact() throws {
        let w = CajuWorld()
        var es: [CajuEntity] = []
        for i in 0..<100 { es.append(try w.spawn(Pos(x: Float(i), y: 0), Health(hp: Int32(i)))) }
        for i in stride(from: 0, to: 100, by: 3) { try w.despawn(es[i]) }
        for i in 0..<100 {
            if i % 3 == 0 {
                #expect(!w.contains(es[i]))
            } else {
                #expect(w.get(Pos.self, of: es[i]) == Pos(x: Float(i), y: 0))
                #expect(w.get(Health.self, of: es[i]) == Health(hp: Int32(i)))
            }
        }
    }

    @Test func insertAndRemoveMoveBetweenArchetypes() throws {
        let w = CajuWorld()
        let e = try w.spawn(Pos(x: 1, y: 1))
        let other = try w.spawn(Pos(x: 5, y: 5))
        try w.insert(Vel(x: 2, y: 2), into: e)
        #expect(w.get(Vel.self, of: e) == Vel(x: 2, y: 2))
        #expect(w.get(Pos.self, of: e) == Pos(x: 1, y: 1))
        try w.insert(Vel(x: 7, y: 7), into: e)  // já existe: sobrescreve
        #expect(w.get(Vel.self, of: e) == Vel(x: 7, y: 7))
        try w.remove(Pos.self, from: e)
        #expect(w.get(Pos.self, of: e) == nil && w.get(Vel.self, of: e) == Vel(x: 7, y: 7))
        #expect(w.get(Pos.self, of: other) == Pos(x: 5, y: 5))
        #expect(throws: CajuWorldError.missingComponent(Pos.componentID)) { try w.remove(Pos.self, from: e) }
    }

    @Test func registrationErrors() throws {
        let w = CajuWorld()
        _ = try w.spawn(Pos(x: 0, y: 0))
        #expect(throws: CajuWorldError.componentIDConflict(Pos.componentID)) { try w.spawn(Clash(a: 1)) }
        #expect(throws: CajuWorldError.invalidComponentID(BadID.componentID)) { try w.spawn(BadID(a: 1)) }
        #expect(throws: CajuWorldError.duplicateComponent(Pos.componentID)) {
            try w.spawn(Pos(x: 0, y: 0), Pos(x: 1, y: 1))
        }
    }

    @Test func tagsDoNotMoveArchetypesAndFilter() throws {
        let w = CajuWorld()
        let a = try w.spawn(Pos(x: 1, y: 0))
        let b = try w.spawn(Pos(x: 2, y: 0))
        let c = try w.spawn(Pos(x: 3, y: 0))
        w.addTag(Dead.self, to: a)
        w.addTag(Stunned.self, to: b)
        #expect(w.hasTag(Dead.self, a) && !w.hasTag(Dead.self, b))
        var alive: [Float] = []
        w.forEach(CajuRead<Pos>.self, filter: CajuQueryFilter(withoutTags: CajuComponentMask(Dead.tagID))) {
            alive.append($0.x)
        }
        #expect(alive.sorted() == [2, 3])
        var stunned: [Float] = []
        w.forEach(CajuRead<Pos>.self, filter: CajuQueryFilter(withTags: CajuComponentMask(Stunned.tagID))) {
            stunned.append($0.x)
        }
        #expect(stunned == [2])
        w.removeTag(Dead.self, from: a)
        #expect(!w.hasTag(Dead.self, a))
        try w.despawn(c)
        #expect(!w.hasTag(Dead.self, c))
    }

    @Test func queryAcrossArchetypesWritesThroughRef() throws {
        let w = CajuWorld()
        for i in 0..<10 { _ = try w.spawn(Pos(x: Float(i), y: 0), Vel(x: 1, y: 2)) }
        for i in 0..<10 { _ = try w.spawn(Pos(x: Float(i), y: 0), Vel(x: 1, y: 2), Health(hp: 1)) }
        _ = try w.spawn(Pos(x: 100, y: 100))  // sem Vel: fora da consulta
        w.forEach(CajuWrite<Pos>.self, CajuRead<Vel>.self) { p, v in
            p.value.x += v.x
            p.value.y += v.y
        }
        var sum: Float = 0
        var n = 0
        w.forEach(CajuRead<Pos>.self) {
            sum += $0.x
            n += 1
        }
        #expect(n == 21)
        #expect(sum == 2 * (45 + 10) + 100)
        var withHealth = 0
        w.forEach(CajuRead<Pos>.self, CajuRead<Health>.self) { _, _ in withHealth += 1 }
        #expect(withHealth == 10)
        var withoutHealth = 0
        w.forEach(
            CajuRead<Pos>.self, CajuRead<Vel>.self,
            filter: CajuQueryFilter(withoutComponents: CajuComponentMask(Health.componentID))
        ) { _, _ in withoutHealth += 1 }
        #expect(withoutHealth == 10)
    }

    @Test func structuralChangeInsideQueryIsRejected() throws {
        let w = CajuWorld()
        let e = try w.spawn(Pos(x: 0, y: 0))
        var spawnError: CajuWorldError?
        var despawnError: CajuWorldError?
        w.forEach(CajuRead<Pos>.self) { _ in
            do throws(CajuWorldError) { _ = try w.spawn(Pos(x: 1, y: 1)) } catch { spawnError = error }
            do throws(CajuWorldError) { try w.despawn(e) } catch { despawnError = error }
        }
        #expect(spawnError == .structuralChangeDuringIteration)
        #expect(despawnError == .structuralChangeDuringIteration)
        #expect(w.contains(e))
    }

    @Test func randomizedAgainstModel() throws {
        var rng = CajuPCG32(seed: 7)
        let w = CajuWorld()
        var model: [CajuEntity: Int32] = [:]
        var live: [CajuEntity] = []
        for step in 0..<5_000 {
            let op = rng.next() % 4
            if op < 2 || live.isEmpty {
                let e = try w.spawn(Health(hp: Int32(step)), Pos(x: 0, y: 0))
                model[e] = Int32(step)
                live.append(e)
            } else if op == 2 {
                let i = Int(rng.next() % UInt32(live.count))
                let e = live.remove(at: i)
                try w.despawn(e)
                model[e] = nil
            } else {
                let e = live[Int(rng.next() % UInt32(live.count))]
                if w.has(Pos.self, e) {
                    try w.remove(Pos.self, from: e)
                } else {
                    try w.insert(Pos(x: 1, y: 1), into: e)
                }
            }
        }
        #expect(w.entityCount == model.count)
        for (e, hp) in model { #expect(w.get(Health.self, of: e) == Health(hp: hp)) }
        var count = 0
        w.forEach(CajuRead<Health>.self) { _ in count += 1 }
        #expect(count == model.count)
    }
}
