import AppKit
import SwiftUI

/// Keeps nonanimated layouts inside one SwiftUI hosting graph. Native split
/// ancestors may move, but pane hosting views never cross hosting-graph owners.
struct NativeSplitTreeView<Content: View, EmptyContent: View>: NSViewRepresentable {
    let rootNode: SplitNode
    // The immutable projection observes every nested split ratio and orientation.
    let layout: PaneTilingTree
    let controller: SplitViewController
    let isInteractive: Bool
    let isTilingEnabled: Bool
    let contentBuilder: (TabItem, PaneID, TabContentContext) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    let showSplitButtons: Bool
    let tabBarVisibility: TabBarVisibility
    let contentViewLifecycle: ContentViewLifecycle
    let onGeometryChange: ((_ isDragging: Bool) -> Void)?
    let zoomedPaneId: PaneID?
    let paneHosting: PaneHostingCoordinator
    let contentRevision: AnyHashable

    func makeCoordinator() -> Coordinator { Coordinator(paneHosting: paneHosting) }

    func makeNSView(context: Context) -> NativeSplitTreeContainer {
        let view = NativeSplitTreeContainer()
        context.coordinator.rootView = view
        paneHosting.registerParkingView(view.parkingView)
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutTree() }
        context.coordinator.update(self, in: view)
        return view
    }

    func updateNSView(_ nsView: NativeSplitTreeContainer, context: Context) {
        context.coordinator.update(self, in: nsView)
    }

    @MainActor
    final class Coordinator {
        typealias SplitBridge = SplitContainerView<Content, EmptyContent>
        private struct Branch {
            let view: NSSplitView
            let coordinator: SplitBridge.Coordinator
        }

        weak var rootView: NativeSplitTreeContainer?
        private let paneHosting: PaneHostingCoordinator
        private var branches: [UUID: Branch] = [:]
        private var paneSlots: [PaneID: PaneDragContainerView] = [:]
        private var rootNode: SplitNode?
        private var zoomedPaneId: PaneID?
        private var isApplying = false

        init(paneHosting: PaneHostingCoordinator) { self.paneHosting = paneHosting }

        func update(_ source: NativeSplitTreeView, in root: NativeSplitTreeContainer) {
            guard !isApplying else { return }
            isApplying = true
            defer { isApplying = false }
            withDeferredPaneHostResizing {
                SplitBridge.performProgrammaticLayout { updateTree(source, in: root) }
                applyTreeGeometry()
            }
        }

        private func updateTree(_ source: NativeSplitTreeView, in root: NativeSplitTreeContainer) {
            rootNode = source.rootNode
            zoomedPaneId = source.zoomedPaneId
            root.isHidden = !source.isInteractive
            paneHosting.registerParkingView(root.parkingView)

            var livePanes: Set<PaneID> = []
            var liveSplits: Set<UUID> = []
            prepare(source.rootNode, source: source, root: root, panes: &livePanes, splits: &liveSplits)

            // Place ancestors before descendants. Each destination parent's
            // ancestor chain is then final, so an acyclic model cannot move a
            // node underneath itself. Direct placement avoids bouncing retained
            // pane subtrees through parking and repeating their window lifecycle.
            root.installTree(view(for: source.rootNode))
            connect(source.rootNode)

            // Every live node now has its unique final parent. Outgoing children
            // left during the synchronous handoff can only be obsolete nodes.
            for (id, branch) in branches where !liveSplits.contains(id) {
                branch.view.removeFromSuperview()
            }
            branches = branches.filter { liveSplits.contains($0.key) }
            for (id, slot) in paneSlots where !livePanes.contains(id) { slot.removeFromSuperview() }
            paneSlots = paneSlots.filter { livePanes.contains($0.key) }
            paneHosting.retainPanes(Array(livePanes))
        }

        private func prepare(
            _ node: SplitNode,
            source: NativeSplitTreeView,
            root: NativeSplitTreeContainer,
            panes: inout Set<PaneID>,
            splits: inout Set<UUID>
        ) {
            switch node {
            case .pane(let pane):
                panes.insert(pane.id)
                let slot: PaneDragContainerView
                if let existing = paneSlots[pane.id] {
                    slot = existing
                } else {
                    slot = PaneDragContainerView()
                    configure(slot)
                    // This slot joins the current synchronous geometry batch.
                    // Its new host is sized once after the dividers are final.
                    slot.autoresizesSubviews = false
                    paneSlots[pane.id] = slot
                    root.park(slot)
                }
                let host = paneHosting.host(
                    for: pane.id,
                    contentRevision: source.contentRevision,
                    showSplitButtons: source.showSplitButtons,
                    tabBarVisibility: source.tabBarVisibility,
                    contentViewLifecycle: source.contentViewLifecycle
                ) {
                    AnyView(PaneContainerView(
                        pane: pane,
                        controller: source.controller,
                        contentBuilder: source.contentBuilder,
                        emptyPaneBuilder: source.emptyPaneBuilder,
                        showSplitButtons: source.showSplitButtons,
                        tabBarVisibility: source.tabBarVisibility,
                        contentViewLifecycle: source.contentViewLifecycle
                    ))
                }
                // Native pane slots retain their leaf host across tree changes.
                // An attached host may deliberately retain its previous size
                // until the batch finishes, or until a hidden pane is revealed.
                if host.view.superview !== slot {
                    paneHosting.attach(host, to: slot)
                }

            case .split(let state):
                splits.insert(state.id)
                let branch: Branch
                if let existing = branches[state.id] {
                    branch = existing
                } else {
                    let coordinator = SplitBridge.Coordinator(
                        splitState: state,
                        minimumPaneWidth: source.appearance.minimumPaneWidth,
                        minimumPaneHeight: source.appearance.minimumPaneHeight,
                        preservesPlannedDividerPosition: source.isTilingEnabled,
                        onGeometryChange: source.onGeometryChange
                    )
                    let view = SplitBridge.makeNativeSplitView(
                        splitState: state,
                        appearance: source.appearance,
                        coordinator: coordinator
                    )
                    for _ in 0..<2 {
                        let slot = SplitArrangedContainerView()
                        configure(slot)
                        view.addArrangedSubview(slot)
                    }
                    coordinator.splitView = view
                    branch = Branch(view: view, coordinator: coordinator)
                    branches[state.id] = branch
                    root.park(view)
                }
                branch.coordinator.update(
                    splitState: state,
                    minimumPaneWidth: source.appearance.minimumPaneWidth,
                    minimumPaneHeight: source.appearance.minimumPaneHeight,
                    preservesPlannedDividerPosition: source.isTilingEnabled,
                    onGeometryChange: source.onGeometryChange
                )
                SplitBridge.updateNativeAppearance(branch.view, appearance: source.appearance)
                branch.view.isVertical = state.orientation == .horizontal
                prepare(state.first, source: source, root: root, panes: &panes, splits: &splits)
                prepare(state.second, source: source, root: root, panes: &panes, splits: &splits)
            }
        }

        private func connect(_ node: SplitNode) {
            guard case .split(let state) = node, let branch = branches[state.id] else { return }
            for (slot, child) in zip(branch.view.arrangedSubviews, [state.first, state.second]) {
                let childView = view(for: child)
                if childView.superview !== slot { slot.addSubview(childView) }
                childView.autoresizingMask = [.width, .height]
                childView.frame = slot.bounds
                connect(child)
            }
        }

        private func view(for node: SplitNode) -> NSView {
            switch node {
            case .pane(let pane): return paneSlots[pane.id]!
            case .split(let state): return branches[state.id]!.view
            }
        }

        func layoutTree() {
            guard !isApplying, rootView != nil, rootNode != nil else { return }
            isApplying = true
            defer { isApplying = false }
            withDeferredPaneHostResizing { applyTreeGeometry() }
        }

        private func withDeferredPaneHostResizing(_ update: () -> Void) {
            let originalSlots = paneSlots.mapValues { (view: $0, autoresizes: $0.autoresizesSubviews) }
            for slot in paneSlots.values { slot.autoresizesSubviews = false }
            defer {
                for original in originalSlots.values {
                    original.view.autoresizesSubviews = original.autoresizes
                }
                // Newly created pane slots use normal AppKit autoresizing
                // outside this coordinator's synchronous layout transaction.
                for (id, slot) in paneSlots where originalSlots[id] == nil {
                    slot.autoresizesSubviews = true
                }
            }
            update()
        }

        private func applyTreeGeometry() {
            guard let rootView, let rootNode else { return }
            SplitBridge.performProgrammaticLayout { rootView.treeView?.frame = rootView.bounds }
            applyGeometry(rootNode)
            // Native branches can resize repeatedly while their final parent,
            // orientation and divider positions are installed. Keep those
            // intermediate sizes out of each leaf's SwiftUI hosting graph.
            // Hidden monocle hosts keep their last size until they are revealed.
            for slot in paneSlots.values where !slot.isHiddenOrHasHiddenAncestor {
                for host in slot.subviews where host.frame != slot.bounds {
                    host.frame = slot.bounds
                }
            }
        }

        private func applyGeometry(_ node: SplitNode) {
            guard case .split(let state) = node, let branch = branches[state.id] else { return }
            branch.coordinator.applyZoomedPane(zoomedPaneId, in: branch.view)
            // Set all native divider frames before normal AppKit content layout.
            // Flushing every split here repeatedly lays out the same descendants.
            branch.coordinator.syncPosition(state.dividerPosition, in: branch.view, layout: false)
            // An ancestor's native resize can suppress descendant delegate sync.
            // Apply descendants after the ancestor's transaction has completed.
            // Hidden branches retain their last geometry until revealed. Unzooming
            // them here would resize hosted content that cannot be displayed.
            if let zoomedPaneId {
                if state.first.findPane(zoomedPaneId) != nil {
                    applyGeometry(state.first)
                    return
                }
                if state.second.findPane(zoomedPaneId) != nil {
                    applyGeometry(state.second)
                    return
                }
            }
            // No valid zoom target: restore the complete tree top-down.
            applyGeometry(state.first)
            applyGeometry(state.second)
        }

        private func configure(_ view: NSView) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
            view.layer?.masksToBounds = true
            view.autoresizingMask = [.width, .height]
        }
    }
}
