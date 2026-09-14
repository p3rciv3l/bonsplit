import Foundation
import Observation

/// Owns pane ordering and commits complete tiling plans at mutation boundaries.
@MainActor
@Observable
final class PaneTilingCoordinator {
    private(set) var layout: PaneTilingLayout = .manual
    private(set) var masterCount = 1
    private(set) var masterRatio = 0.55
    private var order: [PaneID] = []
    private var manualTree: PaneTilingTree?

    @discardableResult
    func restore(_ configuration: PaneTilingConfiguration, in controller: SplitViewController) -> Bool {
        guard configuration.masterCount >= 0,
              configuration.masterRatio.isFinite,
              (0.1...0.9).contains(configuration.masterRatio) else { return false }

        reconcileOrder(in: controller)
        masterCount = configuration.masterCount
        masterRatio = configuration.masterRatio
        if configuration.layout == .manual {
            if layout != .manual { restoreManual(in: controller) }
        } else {
            enable(configuration.layout, in: controller)
            retile(in: controller)
        }
        return true
    }

    @discardableResult
    func perform(_ action: PaneTilingAction, in controller: SplitViewController) -> Bool {
        reconcileOrder(in: controller)
        guard !order.isEmpty else { return false }

        switch action {
        case .focusNext, .focusPrevious:
            guard order.count > 1 else { return false }
            let current = controller.focusedPaneId.flatMap { order.firstIndex(of: $0) } ?? 0
            let offset = action == .focusNext ? 1 : -1
            controller.focusPane(order[(current + offset + order.count) % order.count])
            return true
        case .manual:
            guard layout != .manual else { return false }
            restoreManual(in: controller)
            return true
        case .tile:
            enable(.tile, in: controller)
        case .monocle:
            enable(.monocle, in: controller)
        case .toggleLayout:
            enable(layout == .tile ? .monocle : .tile, in: controller)
        case .moveNext, .movePrevious:
            guard order.count > 1,
                  let focused = controller.focusedPaneId,
                  let current = order.firstIndex(of: focused) else { return false }
            enableIfNeeded(in: controller)
            let offset = action == .moveNext ? 1 : -1
            order.swapAt(current, (current + offset + order.count) % order.count)
        case .promote:
            guard order.count > 1,
                  let focused = controller.focusedPaneId,
                  let current = order.firstIndex(of: focused) else { return false }
            enableIfNeeded(in: controller)
            let target = current == 0 ? 1 : current
            let promoted = order.remove(at: target)
            order.insert(promoted, at: 0)
            controller.focusPane(promoted)
        case .increaseMasterCount:
            guard masterCount < Int.max else { return false }
            enableIfNeeded(in: controller)
            masterCount += 1
        case .decreaseMasterCount:
            guard masterCount > 0 else { return false }
            enableIfNeeded(in: controller)
            masterCount -= 1
        case .increaseMasterRatio, .decreaseMasterRatio:
            let offset = action == .increaseMasterRatio ? 0.05 : -0.05
            var candidate = masterRatio + offset
            // Preserve restored fractional ratios; only normalize floating-point
            // drift at the two inclusive bounds after repeated five-point steps.
            if abs(candidate - 0.1) < 1e-12 { candidate = 0.1 }
            if abs(candidate - 0.9) < 1e-12 { candidate = 0.9 }
            guard (0.1...0.9).contains(candidate) else { return false }
            enableIfNeeded(in: controller)
            masterRatio = candidate
        }
        retile(in: controller)
        return true
    }

    /// Called after structural mutations, never from a view projection or layout callback.
    func panesDidChange(in controller: SplitViewController) {
        guard layout != .manual else { return }
        reconcileOrder(in: controller)
        retile(in: controller)
    }

    /// Explicit divider edits adopt their current geometry as a manual layout.
    func adoptManualLayout(in controller: SplitViewController) {
        guard layout != .manual else { return }
        layout = .manual
        manualTree = nil
        order = controller.rootNode.allPaneIds
        controller.zoomedPaneId = nil
    }

    private func enable(_ target: PaneTilingLayout, in controller: SplitViewController) {
        if layout == .manual {
            manualTree = PaneTilingTree(controller.rootNode)
            order = controller.rootNode.allPaneIds
        }
        layout = target
    }

    private func enableIfNeeded(in controller: SplitViewController) {
        if layout == .manual { enable(.tile, in: controller) }
    }

    private func reconcileOrder(in controller: SplitViewController) {
        let live = controller.rootNode.allPaneIds
        if layout == .manual {
            order = live
            return
        }
        let liveSet = Set(live)
        order.removeAll { !liveSet.contains($0) }
        let known = Set(order)
        // dwm attaches new clients at the head, making a new pane the master.
        order.insert(contentsOf: live.filter { !known.contains($0) }, at: 0)
    }

    private func retile(in controller: SplitViewController) {
        guard !order.isEmpty else { return }
        controller.zoomedPaneId = layout == .monocle && order.count > 1 ? controller.focusedPaneId : nil
        let existing = PaneTilingTree(controller.rootNode)
        let count = min(masterCount, order.count)
        let plan: PaneTilingTree
        if count == 0 || count == order.count {
            plan = column(order[...], existing: existing)
        } else {
            let id: UUID
            let oldFirst: PaneTilingTree?
            let oldSecond: PaneTilingTree?
            if case .split(let splitId, _, _, let first, let second) = existing {
                id = splitId
                oldFirst = first
                oldSecond = second
            } else {
                id = UUID()
                oldFirst = nil
                oldSecond = nil
            }
            plan = .split(
                id: id,
                orientation: .horizontal,
                ratio: CGFloat(masterRatio),
                first: column(order.prefix(count), existing: oldFirst),
                second: column(order.dropFirst(count), existing: oldSecond)
            )
        }
        commit(plan, in: controller)
    }

    /// Balanced subdivisions avoid the divider's 10% clamp for large stacks.
    private func column(_ panes: ArraySlice<PaneID>, existing: PaneTilingTree?) -> PaneTilingTree {
        if panes.count == 1 { return .pane(panes[panes.startIndex]) }
        let firstCount = panes.count / 2
        let id: UUID
        let oldFirst: PaneTilingTree?
        let oldSecond: PaneTilingTree?
        if case .split(let splitId, _, _, let first, let second) = existing {
            id = splitId
            oldFirst = first
            oldSecond = second
        } else {
            id = UUID()
            oldFirst = nil
            oldSecond = nil
        }
        return .split(
            id: id,
            orientation: .vertical,
            ratio: CGFloat(firstCount) / CGFloat(panes.count),
            first: column(panes.prefix(firstCount), existing: oldFirst),
            second: column(panes.dropFirst(firstCount), existing: oldSecond)
        )
    }

    private func restoreManual(in controller: SplitViewController) {
        let live = controller.rootNode.allPaneIds
        let liveSet = Set(live)
        var restored = manualTree?.keeping(liveSet)
        let restoredIds = Set(restored?.paneIds ?? [])
        for paneId in live where !restoredIds.contains(paneId) {
            if let previous = restored {
                restored = .split(id: UUID(), orientation: .horizontal, ratio: 0.5, first: previous, second: .pane(paneId))
            } else {
                restored = .pane(paneId)
            }
        }
        layout = .manual
        controller.zoomedPaneId = nil
        if let restored { commit(restored, in: controller) }
        manualTree = nil
        order = controller.rootNode.allPaneIds
    }

    private func commit(_ plan: PaneTilingTree, in controller: SplitViewController) {
        var panes: [PaneID: PaneState] = [:]
        var splits: [UUID: SplitState] = [:]
        collect(controller.rootNode, panes: &panes, splits: &splits)
        guard let root = plan.materialize(panes: panes, splits: splits) else { return }
        if controller.rootNode != root { controller.rootNode = root }
        // Materialization can mutate retained split children without assigning rootNode.
        controller.synchronizePaneFocusProjection()
    }

    private func collect(_ node: SplitNode, panes: inout [PaneID: PaneState], splits: inout [UUID: SplitState]) {
        switch node {
        case .pane(let pane):
            panes[pane.id] = pane
        case .split(let split):
            splits[split.id] = split
            collect(split.first, panes: &panes, splits: &splits)
            collect(split.second, panes: &panes, splits: &splits)
        }
    }
}
