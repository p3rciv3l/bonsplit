import Foundation

/// An immutable split plan that references panes without retaining mutable geometry.
indirect enum PaneTilingTree {
    case pane(PaneID)
    case split(id: UUID, orientation: SplitOrientation, ratio: CGFloat, first: PaneTilingTree, second: PaneTilingTree)

    init(_ node: SplitNode) {
        switch node {
        case .pane(let pane):
            self = .pane(pane.id)
        case .split(let split):
            self = .split(
                id: split.id,
                orientation: split.orientation,
                ratio: split.dividerPosition,
                first: Self(split.first),
                second: Self(split.second)
            )
        }
    }

    func keeping(_ paneIds: Set<PaneID>) -> Self? {
        switch self {
        case .pane(let paneId):
            return paneIds.contains(paneId) ? self : nil
        case .split(let id, let orientation, let ratio, let first, let second):
            switch (first.keeping(paneIds), second.keeping(paneIds)) {
            case (.some(let first), .some(let second)):
                return .split(id: id, orientation: orientation, ratio: ratio, first: first, second: second)
            case (.some(let surviving), .none), (.none, .some(let surviving)):
                return surviving
            case (.none, .none):
                return nil
            }
        }
    }

    var paneIds: [PaneID] {
        switch self {
        case .pane(let paneId):
            return [paneId]
        case .split(_, _, _, let first, let second):
            return first.paneIds + second.paneIds
        }
    }

    /// Commits a complete plan while retaining every surviving pane object.
    func materialize(panes: [PaneID: PaneState], splits: [UUID: SplitState]) -> SplitNode? {
        switch self {
        case .pane(let paneId):
            return panes[paneId].map(SplitNode.pane)
        case .split(let id, let orientation, let ratio, let first, let second):
            guard let firstNode = first.materialize(panes: panes, splits: splits),
                  let secondNode = second.materialize(panes: panes, splits: splits) else { return nil }
            if let existing = splits[id] {
                existing.orientation = orientation
                if existing.first != firstNode { existing.first = firstNode }
                if existing.second != secondNode { existing.second = secondNode }
                existing.dividerPosition = ratio
                if existing.animationOrigin != nil { existing.animationOrigin = nil }
                return .split(existing)
            }
            return .split(SplitState(
                id: id,
                orientation: orientation,
                first: firstNode,
                second: secondNode,
                dividerPosition: ratio
            ))
        }
    }
}
