import CoreGraphics
import Foundation

/// `horizontal` places the children side by side (first | second); `vertical` stacks them (first over second).
public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum PaneSide: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
}

public enum SplitBranch: String, Codable, Sendable {
    case first
    case second
}

/// Generic binary split tree used for both pane splits and tab-group splits.
public indirect enum LayoutNode<Leaf: Hashable & Codable & Sendable>: Equatable, Sendable, Codable {
    case leaf(Leaf)
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    public static var ratioClamp: ClosedRange<Double> { 0.05...0.95 }
    public static var ratioTolerance: Double { 0.005 }
    public static var maximumDepth: Int { 64 }

    private enum CodingKeys: String, CodingKey {
        case type, id, axis, ratio, first, second
    }

    public init(from decoder: any Decoder) throws {
        let wire = try LayoutNodeWire<Leaf>(from: decoder)
        var seen = Set<Leaf>()
        self = try LayoutNode.build(wire, depth: 1, seen: &seen, decoder: decoder)
    }

    private static func build(
        _ wire: LayoutNodeWire<Leaf>, depth: Int, seen: inout Set<Leaf>, decoder: any Decoder
    ) throws -> LayoutNode {
        func corrupt(_ message: String) -> DecodingError {
            DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        guard depth <= maximumDepth else { throw corrupt("layout deeper than \(maximumDepth)") }
        switch wire.type {
        case "leaf":
            guard let id = wire.id else { throw corrupt("leaf without id") }
            guard seen.insert(id).inserted else { throw corrupt("duplicate leaf") }
            return .leaf(id)
        case "split":
            guard let axis = wire.axis, let first = wire.first, let second = wire.second else {
                throw corrupt("incomplete split")
            }
            var ratio = wire.ratio ?? 0.5
            if !(ratio > 0 && ratio < 1) { ratio = 0.5 }
            let a = try build(first.node, depth: depth + 1, seen: &seen, decoder: decoder)
            let b = try build(second.node, depth: depth + 1, seen: &seen, decoder: decoder)
            return .split(axis: axis, ratio: ratio, first: a, second: b)
        default:
            throw corrupt("unknown node type \(wire.type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode("leaf", forKey: .type)
            try container.encode(id, forKey: .id)
        case .split(let axis, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(axis, forKey: .axis)
            if abs(ratio - 0.5) > Self.ratioTolerance {
                try container.encode(ratio, forKey: .ratio)
            }
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

private struct LayoutNodeWire<Leaf: Decodable>: Decodable {
    var type: String
    var id: Leaf?
    var axis: SplitAxis?
    var ratio: Double?
    var first: Box?
    var second: Box?

    /// Indirection so the recursive struct has finite size.
    final class Box: Decodable {
        let node: LayoutNodeWire<Leaf>
        init(from decoder: any Decoder) throws { node = try LayoutNodeWire(from: decoder) }
    }
}

public extension LayoutNode {
    /// Leaves in visual order (first before second).
    var leaves: [Leaf] {
        switch self {
        case .leaf(let l): return [l]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ leaf: Leaf) -> Bool {
        switch self {
        case .leaf(let l): return l == leaf
        case .split(_, _, let a, let b): return a.contains(leaf) || b.contains(leaf)
        }
    }

    /// `ratio` is the share given to the first child of the new split. nil: target missing or `new` already present.
    func inserting(_ new: Leaf, beside target: Leaf, side: PaneSide, ratio: Double = 0.5) -> LayoutNode? {
        guard contains(target), !contains(new) else { return nil }
        let axis: SplitAxis = (side == .left || side == .right) ? .horizontal : .vertical
        let newFirst = side == .left || side == .top
        let clamped = Swift.min(Swift.max(ratio, Self.ratioClamp.lowerBound), Self.ratioClamp.upperBound)
        return replacing(target) { t in
            .split(
                axis: axis, ratio: clamped,
                first: .leaf(newFirst ? new : t), second: .leaf(newFirst ? t : new))
        }
    }

    private func replacing(_ target: Leaf, with make: (Leaf) -> LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let l):
            return l == target ? make(l) : self
        case .split(let axis, let ratio, let a, let b):
            return .split(
                axis: axis, ratio: ratio,
                first: a.replacing(target, with: make), second: b.replacing(target, with: make))
        }
    }

    /// The sibling subtree takes the parent's place. nil if `leaf` was the only leaf. Unchanged if absent.
    func removing(_ leaf: Leaf) -> LayoutNode? {
        switch self {
        case .leaf(let l):
            return l == leaf ? nil : self
        case .split(let axis, let ratio, let a, let b):
            let na = a.removing(leaf)
            let nb = b.removing(leaf)
            guard let na else { return nb }
            guard let nb else { return na }
            return .split(axis: axis, ratio: ratio, first: na, second: nb)
        }
    }

    /// First leaf of the sibling subtree of the leaf's parent split (Orca `findSiblingGroupId`).
    func sibling(of leaf: Leaf) -> Leaf? {
        guard case .split(_, _, let a, let b) = self else { return nil }
        if case .leaf(let l) = a, l == leaf { return b.leaves.first }
        if case .leaf(let l) = b, l == leaf { return a.leaves.first }
        return a.sibling(of: leaf) ?? b.sibling(of: leaf)
    }

    func moving(_ leaf: Leaf, beside target: Leaf, side: PaneSide) -> LayoutNode? {
        guard leaf != target, contains(leaf), contains(target), let rest = removing(leaf) else { return nil }
        return rest.inserting(leaf, beside: target, side: side)
    }

    func settingRatio(_ ratio: Double, at path: [SplitBranch]) -> LayoutNode {
        guard case .split(let axis, let current, let a, let b) = self else { return self }
        guard let head = path.first else {
            let c = Swift.min(Swift.max(ratio, Self.ratioClamp.lowerBound), Self.ratioClamp.upperBound)
            return .split(axis: axis, ratio: ratio.isFinite ? c : current, first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        switch head {
        case .first: return .split(axis: axis, ratio: current, first: a.settingRatio(ratio, at: rest), second: b)
        case .second: return .split(axis: axis, ratio: current, first: a, second: b.settingRatio(ratio, at: rest))
        }
    }

    /// Same-axis runs get equal shares per leaf (Orca `equalizeLayout`); ratios rounded to 1/1000, near 0.5 stored as 0.5.
    func equalized() -> LayoutNode {
        guard case .split(let axis, _, let a, let b) = self else { return self }
        let wa = a.equalWeight(axis)
        let wb = b.equalWeight(axis)
        var ratio = wa / (wa + wb)
        ratio = abs(ratio - 0.5) > Self.ratioTolerance ? (ratio * 1000).rounded() / 1000 : 0.5
        return .split(axis: axis, ratio: ratio, first: a.equalized(), second: b.equalized())
    }

    private func equalWeight(_ axis: SplitAxis) -> Double {
        if case .split(let ax, _, let a, let b) = self, ax == axis {
            return a.equalWeight(axis) + b.equalWeight(axis)
        }
        return 1
    }

    /// Cyclic neighbour in visual order. A single leaf is its own neighbour; nil if absent.
    func leaf(after leaf: Leaf) -> Leaf? {
        let all = leaves
        guard let i = all.firstIndex(of: leaf) else { return nil }
        return all[(i + 1) % all.count]
    }

    func leaf(before leaf: Leaf) -> Leaf? {
        let all = leaves
        guard let i = all.firstIndex(of: leaf) else { return nil }
        return all[(i + all.count - 1) % all.count]
    }

    /// Leaf rects tile `rect` together with the divider strips: no gaps, no overlap.
    func frames(in rect: CGRect, divider: CGFloat) -> [Leaf: CGRect] {
        var out: [Leaf: CGRect] = [:]
        layout(rect, divider) { out[$0] = $1 } onDivider: { _, _, _ in }
        return out
    }

    func dividers(in rect: CGRect, divider: CGFloat) -> [(path: [SplitBranch], axis: SplitAxis, frame: CGRect)] {
        var out: [(path: [SplitBranch], axis: SplitAxis, frame: CGRect)] = []
        layout(rect, divider) { _, _ in } onDivider: { out.append(($0, $1, $2)) }
        return out
    }

    /// Ratio for a divider dragged to `dragLocation`, keeping both sides at least `minimum` along the split axis.
    func ratio(
        forDividerAt path: [SplitBranch], dragLocation: CGPoint, in rect: CGRect,
        divider: CGFloat, minimum: CGSize
    ) -> Double {
        var node = self
        var area = rect
        for branch in path {
            guard case .split(let axis, let ratio, let a, let b) = node else { return 0.5 }
            let (fa, fb) = Self.childRects(axis, ratio, area, divider)
            if branch == .first { node = a; area = fa } else { node = b; area = fb }
        }
        guard case .split(let axis, _, _, _) = node else { return 0.5 }
        let horizontal = axis == .horizontal
        let total = horizontal ? area.width : area.height
        let available = total - divider
        let minimumSize = horizontal ? minimum.width : minimum.height
        guard available > 0, available >= 2 * minimumSize else { return 0.5 }
        let origin = horizontal ? area.minX : area.minY
        let location = horizontal ? dragLocation.x : dragLocation.y
        let firstSize = Swift.min(Swift.max(location - origin - divider / 2, minimumSize), available - minimumSize)
        return Double(firstSize / available)
    }

    private static func childRects(_ axis: SplitAxis, _ ratio: Double, _ r: CGRect, _ d: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let avail = Swift.max(r.width - d, 0)
            let w = avail * CGFloat(ratio)
            return (
                CGRect(x: r.minX, y: r.minY, width: w, height: r.height),
                CGRect(x: r.minX + w + d, y: r.minY, width: avail - w, height: r.height)
            )
        case .vertical:
            let avail = Swift.max(r.height - d, 0)
            let h = avail * CGFloat(ratio)
            return (
                CGRect(x: r.minX, y: r.minY, width: r.width, height: h),
                CGRect(x: r.minX, y: r.minY + h + d, width: r.width, height: avail - h)
            )
        }
    }

    private func layout(
        _ rect: CGRect, _ d: CGFloat, path: [SplitBranch] = [],
        onLeaf: (Leaf, CGRect) -> Void,
        onDivider: ([SplitBranch], SplitAxis, CGRect) -> Void
    ) {
        switch self {
        case .leaf(let l):
            onLeaf(l, rect)
        case .split(let axis, let ratio, let a, let b):
            let (fa, fb) = Self.childRects(axis, ratio, rect, d)
            let strip: CGRect = axis == .horizontal
                ? CGRect(x: fa.maxX, y: rect.minY, width: d, height: rect.height)
                : CGRect(x: rect.minX, y: fa.maxY, width: rect.width, height: d)
            onDivider(path, axis, strip)
            a.layout(fa, d, path: path + [.first], onLeaf: onLeaf, onDivider: onDivider)
            b.layout(fb, d, path: path + [.second], onLeaf: onLeaf, onDivider: onDivider)
        }
    }
}
