import CoreGraphics
import Foundation
import Testing

@testable import SmthzCore

private typealias Tree = LayoutNode<String>

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

private func split(_ axis: SplitAxis, _ a: Tree, _ b: Tree, ratio: Double = 0.5) -> Tree {
    .split(axis: axis, ratio: ratio, first: a, second: b)
}

@Test func insertOnAllFourSides() throws {
    let base = Tree.leaf("a")
    #expect(base.inserting("b", beside: "a", side: .left) == split(.horizontal, .leaf("b"), .leaf("a")))
    #expect(base.inserting("b", beside: "a", side: .right) == split(.horizontal, .leaf("a"), .leaf("b")))
    #expect(base.inserting("b", beside: "a", side: .top) == split(.vertical, .leaf("b"), .leaf("a")))
    #expect(base.inserting("b", beside: "a", side: .bottom) == split(.vertical, .leaf("a"), .leaf("b")))
}

@Test func insertRejectsMissingTargetAndDuplicate() {
    let t = split(.horizontal, .leaf("a"), .leaf("b"))
    #expect(t.inserting("c", beside: "zzz", side: .left) == nil)
    #expect(t.inserting("b", beside: "a", side: .left) == nil)
}

@Test func insertInsideNestedTreeKeepsOrder() throws {
    let t = split(.horizontal, .leaf("a"), .leaf("b"))
    let r = try #require(t.inserting("c", beside: "b", side: .bottom))
    #expect(r.leaves == ["a", "b", "c"])
    #expect(r == split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c"))))
}

@Test func removeCollapsesToSibling() {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c")))
    #expect(t.removing("a") == split(.vertical, .leaf("b"), .leaf("c")))
    #expect(t.removing("b") == split(.horizontal, .leaf("a"), .leaf("c")))
    #expect(t.removing("zzz") == t)
}

@Test func removingOnlyLeafIsNil() {
    #expect(Tree.leaf("a").removing("a") == nil)
}

@Test func siblingMatchesOrcaExamples() {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), split(.horizontal, .leaf("c"), .leaf("d"))))
    #expect(t.sibling(of: "a") == "b")  // sibling subtree's first leaf
    #expect(t.sibling(of: "b") == "c")
    #expect(t.sibling(of: "c") == "d")
    #expect(t.sibling(of: "d") == "c")
    #expect(Tree.leaf("a").sibling(of: "a") == nil)
    #expect(t.sibling(of: "zzz") == nil)
}

@Test func equalizeThreeSideBySide() throws {
    let t = split(.horizontal, split(.horizontal, .leaf("a"), .leaf("b"), ratio: 0.8), .leaf("c"), ratio: 0.2)
    let e = t.equalized()
    guard case .split(_, let outer, let first, _) = e, case .split(_, let inner, _, _) = first else {
        Issue.record("shape changed"); return
    }
    #expect(outer == 0.667)
    #expect(inner == 0.5)
    // Other-axis children do not weigh in.
    let mixed = split(.horizontal, split(.vertical, .leaf("a"), .leaf("b")), .leaf("c")).equalized()
    guard case .split(_, let r, _, _) = mixed else { return }
    #expect(r == 0.5)
    let thirds = split(.horizontal, .leaf("a"), split(.horizontal, .leaf("b"), .leaf("c"))).equalized()
    guard case .split(_, let r3, _, _) = thirds else { return }
    #expect(r3 == 0.333)
}

private func randomTree(_ rng: inout SplitMix64, leaves n: Int) -> Tree {
    var t = Tree.leaf("p0")
    for i in 1..<n {
        let target = t.leaves[rng.below(t.leaves.count)]
        let side = PaneSide.allCases[rng.below(4)]
        let ratio = 0.2 + Double(rng.below(60)) / 100
        t = t.inserting("p\(i)", beside: target, side: side, ratio: ratio)!
    }
    return t
}

@Test func framesTileRectExactly() {
    var rng = SplitMix64(state: 42)
    let tree = randomTree(&rng, leaves: 20)
    let rect = CGRect(x: 10, y: 20, width: 1000, height: 700)
    let d: CGFloat = 4
    let frames = tree.frames(in: rect, divider: d)
    let strips = tree.dividers(in: rect, divider: d)
    #expect(frames.count == 20)
    #expect(strips.count == 19)
    var rects = Array(frames.values) + strips.map(\.frame)
    let area = rects.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(area - rect.width * rect.height) < 1e-6)
    for r in rects { #expect(rect.insetBy(dx: -1e-9, dy: -1e-9).contains(r)) }
    while let r = rects.popLast() {
        for o in rects { #expect(r.intersection(o).width * r.intersection(o).height < 1e-9 || r.intersection(o).isNull) }
    }
}

@Test func dividerRatioHonoursMinimumSize() {
    let t = split(.horizontal, .leaf("a"), .leaf("b"))
    let rect = CGRect(x: 0, y: 0, width: 1004, height: 500)
    let min = CGSize(width: 100, height: 50)
    let low = t.ratio(forDividerAt: [], dragLocation: CGPoint(x: 5, y: 0), in: rect, divider: 4, minimum: min)
    #expect(abs(low - 0.1) < 1e-9)
    let high = t.ratio(forDividerAt: [], dragLocation: CGPoint(x: 1000, y: 0), in: rect, divider: 4, minimum: min)
    #expect(abs(high - 0.9) < 1e-9)
    let mid = t.ratio(forDividerAt: [], dragLocation: CGPoint(x: 502, y: 0), in: rect, divider: 4, minimum: min)
    #expect(abs(mid - 0.5) < 1e-9)
    let tiny = t.ratio(forDividerAt: [], dragLocation: CGPoint(x: 10, y: 0), in: CGRect(x: 0, y: 0, width: 150, height: 10), divider: 4, minimum: min)
    #expect(tiny == 0.5)
}

@Test func dividerRatioWorksOnNestedPath() {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c")))
    let rect = CGRect(x: 0, y: 0, width: 1004, height: 504)
    // second child spans x 502..1004, y 0..504; vertical split, available 500
    let r = t.ratio(forDividerAt: [.second], dragLocation: CGPoint(x: 700, y: 252), in: rect, divider: 4, minimum: CGSize(width: 50, height: 50))
    #expect(abs(r - 0.5) < 1e-9)
}

@Test func settingRatioClamps() {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c")))
    guard case .split(_, let r1, _, _) = t.settingRatio(0.99, at: []) else { return }
    #expect(r1 == 0.95)
    guard case .split(_, _, _, .split(_, let r2, _, _)) = t.settingRatio(0.0, at: [.second]) else {
        Issue.record("shape"); return
    }
    #expect(r2 == 0.05)
    #expect(t.settingRatio(0.3, at: [.first, .first]) == t)
}

@Test func nextAndPreviousCycle() {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c")))
    #expect(t.leaf(after: "a") == "b")
    #expect(t.leaf(after: "c") == "a")
    #expect(t.leaf(before: "a") == "c")
    #expect(t.leaf(before: "c") == "b")
    #expect(t.leaf(after: "zzz") == nil)
    #expect(Tree.leaf("a").leaf(after: "a") == "a")
}

@Test func movingRelocatesLeaf() throws {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c")))
    let m = try #require(t.moving("a", beside: "c", side: .right))
    #expect(m == split(.vertical, .leaf("b"), split(.horizontal, .leaf("c"), .leaf("a"))))
    #expect(t.moving("a", beside: "a", side: .left) == nil)
    #expect(t.moving("zzz", beside: "a", side: .left) == nil)
}

@Test func jsonRoundTripAndShape() throws {
    let t = split(.horizontal, .leaf("a"), split(.vertical, .leaf("b"), .leaf("c"), ratio: 0.3), ratio: 0.5)
    let data = try JSONEncoder().encode(t)
    #expect(try JSONDecoder().decode(Tree.self, from: data) == t)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"type\":\"leaf\""))
    #expect(json.contains("\"id\":\"a\""))
    #expect(json.contains("\"ratio\":0.3"))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["ratio"] == nil)  // 0.5 omitted
    #expect(obj["axis"] as? String == "horizontal")
}

@Test func jsonRejectsDuplicatesDepthAndClampsRatio() throws {
    let dup = #"{"type":"split","axis":"horizontal","first":{"type":"leaf","id":"a"},"second":{"type":"leaf","id":"a"}}"#
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Tree.self, from: Data(dup.utf8)) }

    var deep = #"{"type":"leaf","id":"x0"}"#
    for i in 1...70 {
        deep = #"{"type":"split","axis":"vertical","first":\#(deep),"second":{"type":"leaf","id":"x\#(i)"}}"#
    }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Tree.self, from: Data(deep.utf8)) }

    let bad = #"{"type":"split","axis":"vertical","ratio":1.5,"first":{"type":"leaf","id":"a"},"second":{"type":"leaf","id":"b"}}"#
    #expect(try JSONDecoder().decode(Tree.self, from: Data(bad.utf8)) == split(.vertical, .leaf("a"), .leaf("b")))
}

@Test func randomOperationsKeepInvariants() {
    var rng = SplitMix64(state: 0xC0FFEE)
    var tree = Tree.leaf("p0")
    var counter = 1
    let rect = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    for _ in 0..<500 {
        let leaves = tree.leaves
        switch rng.below(3) {
        case 0:
            let side = PaneSide.allCases[rng.below(4)]
            if let n = tree.inserting("p\(counter)", beside: leaves[rng.below(leaves.count)], side: side) {
                tree = n; counter += 1
            }
        case 1:
            if leaves.count > 1, let n = tree.removing(leaves[rng.below(leaves.count)]) { tree = n }
        default:
            if leaves.count > 1,
                let n = tree.moving(leaves[rng.below(leaves.count)], beside: leaves[rng.below(leaves.count)], side: PaneSide.allCases[rng.below(4)])
            { tree = n }
        }
        #expect(Set(tree.leaves).count == tree.leaves.count)
        #expect(tree.frames(in: rect, divider: 2).count == tree.leaves.count)
    }
}
