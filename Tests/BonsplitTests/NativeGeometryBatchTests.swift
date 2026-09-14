@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct NativeGeometryBatchTests {
    @Test(arguments: [2, 8, 16])
    func nativeTopologyHandoffsDoNotBounceRetainedLeavesThroughParking(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        let tabs = fixture.controller.allTabIds
        let anchors = try Dictionary(uniqueKeysWithValues: tabs.map {
            ($0, try #require(fixture.anchor(for: $0) as? WindowLifecycleAnchorView))
        })
        func validateHandoff(_ label: String, perform: () throws -> Void) throws {
            let before = anchors.mapValues { anchor in
                (moves: anchor.windowMoveCount, parked: anchor.parkingWindowMoveCount,
                 detached: anchor.detachedWindowMoveCount, ancestry: fixture.structuralAncestry(of: anchor))
            }
            try perform()
            fixture.render()
            try fixture.expectGeometry()
            try fixture.expectExactNativeChildren()
            for tab in tabs {
                let anchor = try #require(anchors[tab])
                let previous = try #require(before[tab])
                let necessaryHandoffs = previous.ancestry.filter { view, parent in view.superview !== parent }.count
                #expect(anchor.windowMoveCount - previous.moves <= necessaryHandoffs,
                        "\(label): one final placement per changed native ancestor is sufficient")
                #expect(anchor.parkingWindowMoveCount == previous.parked,
                        "\(label): retained leaves must not visit temporary parking during a native topology handoff")
                #expect(anchor.detachedWindowMoveCount == previous.detached)
                #expect(try fixture.anchor(for: tab) === anchor)
                #expect(anchor.window === fixture.window)
            }
        }

        let actions: [PaneTilingAction] = [
            .tile, .manual, .tile, .moveNext, .movePrevious, .promote,
            .monocle, .focusNext, .increaseMasterCount, .moveNext, .focusPrevious, .tile, .manual
        ]
        for action in actions {
            try validateHandoff(action.rawValue) { #expect(fixture.controller.performTilingAction(action)) }
        }
        var addedPane: PaneID?
        try validateHandoff("split") {
            let target = try #require(fixture.controller.focusedPaneId)
            addedPane = try #require(fixture.controller.splitPane(target, orientation: .vertical, withTab: Tab(title: "Added")))
        }
        try validateHandoff("close") {
            let closingPane = try #require(addedPane)
            #expect(fixture.controller.closePane(closingPane))
        }
    }

    @Test(arguments: [2, 8, 16])
    func nativeRatioUpdatesDoNotFlushEveryDescendantSubtree(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.render()
        let previous = try fixture.flushCounts()

        #expect(fixture.controller.performTilingAction(.increaseMasterRatio))
        fixture.render()

        try fixture.expectNoNewFlushes(since: previous)
        try fixture.expectGeometry()
    }

    @Test(arguments: [8, 16], [PaneTilingAction.tile, .manual])
    func monocleFocusRetainsHiddenBranchLayoutUntilItIsRevealed(paneCount: Int, exit: PaneTilingAction) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        #expect(fixture.controller.performTilingAction(.tile))
        let master = try #require(fixture.controller.allPaneIds.first)
        let lastStackPane = try #require(fixture.controller.allPaneIds.last)
        fixture.controller.focusPane(lastStackPane)
        #expect(fixture.controller.performTilingAction(.monocle))
        fixture.render()
        try fixture.expectGeometry()

        let tabs = fixture.controller.allTabIds
        let anchors = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.anchor(for: $0)) })
        let hosts = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.host(for: $0)) })
        let stackSplits = try fixture.nativeSplits.filter { split in
            let coordinator = try #require(split.delegate as? Fixture.SplitCoordinator)
            return coordinator.splitState.first.findPane(master) == nil &&
                coordinator.splitState.second.findPane(master) == nil
        }
        #expect(stackSplits.count == paneCount - 2)
        let dividerThicknesses = stackSplits.map(\.dividerThickness)
        #expect(dividerThicknesses.contains(0))
        let hiddenStates = stackSplits.map { $0.arrangedSubviews.map(\.isHidden) }
        let frames = stackSplits.map { $0.arrangedSubviews.map(\.frame) }

        #expect(fixture.controller.performTilingAction(.focusNext))
        #expect(fixture.controller.focusedPaneId == master)
        fixture.render()
        try fixture.expectGeometry()
        for (index, split) in stackSplits.enumerated() {
            #expect(split.isHiddenOrHasHiddenAncestor)
            #expect(split.dividerThickness == dividerThicknesses[index], "A newly hidden stack should retain its native zoom geometry")
            #expect(split.arrangedSubviews.map(\.isHidden) == hiddenStates[index])
            #expect(split.arrangedSubviews.map(\.frame) == frames[index])
        }

        fixture.window.setContentSize(NSSize(width: 1237, height: 947))
        fixture.render()
        try fixture.expectGeometry()
        #expect(fixture.controller.performTilingAction(.focusPrevious))
        #expect(fixture.controller.focusedPaneId == lastStackPane)
        fixture.render()
        try fixture.expectGeometry()
        #expect(fixture.controller.performTilingAction(exit))
        fixture.render()
        try fixture.expectGeometry()
        for tab in tabs {
            #expect(try fixture.anchor(for: tab) === anchors[tab])
            #expect(try fixture.host(for: tab) === hosts[tab])
            #expect(hosts[tab]?.window === fixture.window)
        }
    }

    @Test(arguments: [8, 16])
    func monocleRepairsHiddenTopologyChangesBeforeRevealAndExit(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.controller.focusPane(try #require(fixture.controller.allPaneIds.last))
        #expect(fixture.controller.performTilingAction(.monocle))
        fixture.render()
        let tabs = fixture.controller.allTabIds
        let anchors = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.anchor(for: $0)) })
        let hosts = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.host(for: $0)) })
        #expect(fixture.controller.performTilingAction(.focusNext))
        fixture.render()

        for action in [PaneTilingAction.increaseMasterRatio, .increaseMasterCount,
                       .moveNext, .promote, .decreaseMasterCount, .decreaseMasterRatio] {
            #expect(fixture.controller.performTilingAction(action))
            #expect(fixture.controller.tilingLayout == .monocle)
            fixture.render()
            try fixture.expectGeometry()
        }
        for exit in [PaneTilingAction.tile, .monocle, .manual] {
            #expect(fixture.controller.performTilingAction(exit))
            fixture.render()
            try fixture.expectGeometry()
        }
        for tab in tabs {
            #expect(try fixture.anchor(for: tab) === anchors[tab])
            #expect(try fixture.host(for: tab) === hosts[tab])
            #expect(hosts[tab]?.window === fixture.window)
        }
    }

    @Test(arguments: [8, 16])
    func nativeBatchPreservesEveryActionGeometryAndLeafIdentity(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        let panes = fixture.controller.allPaneIds
        let tabs = fixture.controller.allTabIds
        let anchors = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.anchor(for: $0)) })
        let hosts = try Dictionary(uniqueKeysWithValues: tabs.map { ($0, try fixture.host(for: $0)) })
        let actions: [PaneTilingAction] = [
            .tile, .monocle, .focusNext, .focusPrevious, .toggleLayout,
            .moveNext, .movePrevious, .promote, .increaseMasterCount,
            .decreaseMasterCount, .increaseMasterRatio, .decreaseMasterRatio, .manual
        ]

        for action in actions {
            let previous = try fixture.flushCounts()
            #expect(fixture.controller.performTilingAction(action))
            fixture.render()
            #expect(Set(fixture.controller.allPaneIds) == Set(panes))
            #expect(Set(fixture.controller.allTabIds) == Set(tabs))
            try fixture.expectNoNewFlushes(since: previous)
            try fixture.expectGeometry()
            for tab in tabs {
                #expect(try fixture.anchor(for: tab) === anchors[tab], "Anchor changed during \(action.rawValue)")
                #expect(try fixture.host(for: tab) === hosts[tab], "Host changed during \(action.rawValue)")
                #expect(hosts[tab]?.window === fixture.window)
            }
        }
    }

    @Test
    func nativeBatchKeepsOriginalHostAcrossSinglePaneSplitAndClose() throws {
        let fixture = try Fixture(paneCount: 1)
        defer { fixture.close() }
        let firstPane = try #require(fixture.controller.focusedPaneId)
        let firstTab = try #require(fixture.controller.selectedTab(inPane: firstPane))
        let originalAnchor = try fixture.anchor(for: firstTab.id)
        let originalHost = try fixture.host(for: firstTab.id)
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.render()
        let secondPane = try #require(fixture.controller.splitPane(firstPane, orientation: .horizontal, withTab: Tab(title: "Second")))
        fixture.render()
        let secondTab = try #require(fixture.controller.selectedTab(inPane: secondPane))
        let secondHost = try fixture.host(for: secondTab.id)

        try fixture.expectNoNewFlushes(since: [:])
        try fixture.expectGeometry()
        #expect(try fixture.anchor(for: firstTab.id) === originalAnchor)
        #expect(try fixture.host(for: firstTab.id) === originalHost)
        #expect(fixture.controller.closePane(secondPane))
        fixture.render()
        #expect(try fixture.anchor(for: firstTab.id) === originalAnchor)
        #expect(try fixture.host(for: firstTab.id) === originalHost)
        #expect(originalHost.window === fixture.window)
        #expect(secondHost.window == nil)
        #expect(fixture.nativeSplits.isEmpty)
    }

    @Test(arguments: [true, false])
    func sharedDividerSynchronizationPreservesDefaultFlushAndExplicitOptOut(flushLayout: Bool) throws {
        _ = NSApplication.shared
        let state = SplitState(orientation: .horizontal, first: .pane(PaneState()), second: .pane(PaneState()))
        let coordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: state, minimumPaneWidth: 1, minimumPaneHeight: 1, onGeometryChange: nil
        )
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        split.isVertical = true
        for _ in 0..<2 { split.addArrangedSubview(NSView(frame: split.bounds)) }
        split.adjustSubviews()
        coordinator.splitView = split
        coordinator.setPositionSafely((split.bounds.width - split.dividerThickness) * 0.5, in: split, layout: false)
        state.dividerPosition = 0.65

        if flushLayout {
            coordinator.syncPosition(0.65, in: split)
        } else {
            coordinator.syncPosition(0.65, in: split, layout: false)
        }

        let first = try #require(split.arrangedSubviews.first)
        #expect(abs(first.frame.width - (split.bounds.width - split.dividerThickness) * 0.65) <= 1)
        #expect(coordinator.debugSubtreeLayoutFlushCount == (flushLayout ? 1 : 0))
    }

    @MainActor
    private final class Fixture {
        typealias RenderedView = BonsplitView<AnchorProbe, EmptyView>
        typealias SplitCoordinator = SplitContainerView<AnchorProbe, EmptyView>.Coordinator

        let controller: BonsplitController
        let hostingView: NSHostingView<RenderedView>
        let window: NSWindow

        init(paneCount: Int) throws {
            _ = NSApplication.shared
            var configuration = BonsplitConfiguration(contentViewLifecycle: .keepAllAlive)
            configuration.appearance.enableAnimations = false
            configuration.appearance.minimumPaneWidth = 1
            configuration.appearance.minimumPaneHeight = 1
            controller = BonsplitController(configuration: configuration)
            var queue = [try #require(controller.focusedPaneId)]
            for index in 1..<paneCount {
                let target = queue[index - 1]
                let added = try #require(controller.splitPane(
                    target,
                    orientation: index.isMultiple(of: 2) ? .vertical : .horizontal,
                    withTab: Tab(title: "Pane \(index)"),
                    initialDividerPosition: 0.35
                ))
                queue.append(target)
                queue.append(added)
            }
            hostingView = NSHostingView(rootView: Self.view(for: controller))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1153, height: 902),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            render()
        }

        func render() {
            hostingView.rootView = Self.view(for: controller)
            // A normal host layout boundary renders the new tree. The regression
            // counts only explicit per-split subtree flushes inside that work.
            hostingView.layoutSubtreeIfNeeded()
        }

        private static func view(for controller: BonsplitController) -> RenderedView {
            BonsplitView(controller: controller, contentRevision: 1) { tab, _ in
                AnchorProbe(tab: tab.id)
            } emptyPane: { _ in EmptyView() }
        }

        var nativeSplits: [NSSplitView] { descendants(of: hostingView).compactMap { $0 as? NSSplitView } }

        func structuralAncestry(of anchor: NSView) -> [(NSView, NSView?)] {
            var result: [(NSView, NSView?)] = []
            var candidate = anchor.superview
            while let view = candidate {
                if view is NSSplitView || view is PaneDragContainerView {
                    result.append((view, view.superview))
                }
                candidate = view.superview
            }
            return result
        }

        func expectExactNativeChildren() throws {
            let root = try #require(descendants(of: hostingView).first { $0 is NativeSplitTreeContainer } as? NativeSplitTreeContainer)
            let tree = try #require(root.treeView)
            #expect(root.subviews.filter { $0 !== root.parkingView }.count == 1)
            #expect(tree.superview === root)
            #expect(root.parkingView.subviews.isEmpty)
            for split in nativeSplits {
                #expect(split.arrangedSubviews.count == 2)
                for child in split.arrangedSubviews { #expect(child.subviews.count == 1) }
            }
        }

        func flushCounts() throws -> [ObjectIdentifier: UInt64] {
            try Dictionary(uniqueKeysWithValues: nativeSplits.map { split in
                let coordinator = try #require(split.delegate as? SplitCoordinator)
                return (ObjectIdentifier(coordinator), coordinator.debugSubtreeLayoutFlushCount)
            })
        }

        func expectNoNewFlushes(since previous: [ObjectIdentifier: UInt64]) throws {
            for (identity, count) in try flushCounts() {
                #expect(count == previous[identity, default: 0], "Native geometry flushed a descendant subtree")
            }
        }

        func expectGeometry() throws {
            for split in nativeSplits where !split.isHiddenOrHasHiddenAncestor {
                let coordinator = try #require(split.delegate as? SplitCoordinator)
                let first = try #require(split.arrangedSubviews.first)
                if controller.tilingLayout == .monocle {
                    #expect(split.dividerThickness == 0)
                    let visible = try #require(split.arrangedSubviews.first { !$0.isHidden })
                    #expect(visible.frame == split.bounds)
                    let drawn = NSRect(x: 100, y: 100, width: 1, height: 100)
                    #expect(coordinator.splitView(split, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0) == .zero)
                    #expect(coordinator.splitView(split, additionalEffectiveRectOfDividerAt: 0) == .zero)
                } else {
                    let available = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
                    let actual = split.isVertical ? first.frame.width : first.frame.height
                    #expect(abs(actual - available * coordinator.splitState.dividerPosition) <= 1)
                }
            }
            for pane in controller.allPaneIds {
                let tab = try #require(controller.selectedTab(inPane: pane))
                let host = try host(for: tab.id)
                if controller.tilingLayout == .monocle {
                    #expect(host.isHiddenOrHasHiddenAncestor == (pane != controller.focusedPaneId))
                    if pane == controller.focusedPaneId {
                        let actual = host.convert(host.bounds, to: hostingView)
                        #expect(abs(actual.width - hostingView.bounds.width) <= 1)
                        #expect(abs(actual.height - hostingView.bounds.height) <= 1)
                    }
                } else {
                    #expect(!host.isHiddenOrHasHiddenAncestor)
                }
            }
        }

        func anchor(for tab: TabID) throws -> NSView {
            try #require(descendants(of: hostingView).first { $0.identifier?.rawValue == tab.id.uuidString })
        }

        func host(for tab: TabID) throws -> NSView {
            var candidate = try anchor(for: tab).superview
            while let view = candidate {
                if view is NSHostingView<AnyView> { return view }
                candidate = view.superview
            }
            throw MissingHost()
        }

        private func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        private struct MissingHost: Error {}
    }

    private struct AnchorProbe: NSViewRepresentable {
        let tab: TabID

        func makeNSView(context: Context) -> NSView { WindowLifecycleAnchorView() }
        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        }
    }

    private final class WindowLifecycleAnchorView: NSView {
        private(set) var windowMoveCount = 0
        private(set) var parkingWindowMoveCount = 0
        private(set) var detachedWindowMoveCount = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowMoveCount += 1
            if window == nil { detachedWindowMoveCount += 1 }
            var ancestor = superview
            while let view = ancestor {
                if view is NativeSplitParkingView { parkingWindowMoveCount += 1; break }
                ancestor = view.superview
            }
        }
    }
}
