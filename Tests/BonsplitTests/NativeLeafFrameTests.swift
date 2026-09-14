@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct NativeLeafFrameTests {
    @Test(arguments: [2, 8, 16], [PaneTilingAction.tile, .manual, .increaseMasterRatio, .moveNext])
    func retainedNativeHostsReceiveOnlyTheirFinalSize(paneCount: Int, action: PaneTilingAction) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        if action != .tile {
            #expect(fixture.controller.performTilingAction(.tile))
            fixture.render()
        }
        let tabs = fixture.controller.allTabIds
        let histories = try Dictionary(uniqueKeysWithValues: tabs.map {
            ($0, FrameHistory(view: try fixture.host(for: $0)))
        })
        defer { histories.values.forEach { $0.stop() } }

        #expect(fixture.controller.performTilingAction(action))
        fixture.render()

        for tab in tabs {
            let history = try #require(histories[tab])
            let host = try fixture.host(for: tab)
            #expect(host === history.view)
            #expect(host.window === fixture.window)
            #expect(host.frame == host.superview?.bounds)
            let finalSize = host.frame.size
            let requiredEvents = history.initialSize == finalSize ? 0 : 1
            if requiredEvents > 0 {
                #expect(history.sizes.last == finalSize, "Actual native frame observation must include the final resize")
            }
            #expect(history.sizes.count <= requiredEvents,
                    "\(action.rawValue), \(paneCount) panes: retained host must not resize through intermediate slot geometry; initial=\(history.initialSize), final=\(finalSize), observed=\(history.sizes)")
        }
    }

    @Test
    func actualHostingViewFrameNotificationsCaptureSynchronousSizeChanges() throws {
        let fixture = try Fixture(paneCount: 1)
        defer { fixture.close() }
        let tab = try #require(fixture.controller.allTabIds.first)
        let host = try fixture.host(for: tab)
        let history = FrameHistory(view: host)
        defer { history.stop() }
        let original = host.frame
        let first = NSSize(width: original.width + 17, height: original.height + 11)
        let second = NSSize(width: original.width + 31, height: original.height + 23)
        host.setFrameSize(first)
        host.setFrameSize(second)
        host.frame = original
        #expect(history.sizes == [first, second, original.size])
    }

    @Test(arguments: [2, 8, 16])
    func unchangedNativeTreeDoesNotResizeRetainedHosts(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.render()
        let histories = try fixture.controller.allTabIds.map { FrameHistory(view: try fixture.host(for: $0)) }
        defer { histories.forEach { $0.stop() } }
        fixture.render()
        for history in histories { #expect(history.sizes.isEmpty) }
    }

    @Test(arguments: [8, 16])
    func hiddenMonocleHostsRetainTheirSizeThroughRepeatedUpdatesUntilReveal(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.controller.focusPane(try #require(fixture.controller.allPaneIds.first))
        let focusedPane = try #require(fixture.controller.focusedPaneId)
        #expect(fixture.controller.performTilingAction(.monocle))
        fixture.render()
        let hiddenTabs = try fixture.controller.allPaneIds.filter { $0 != focusedPane }.map {
            try #require(fixture.controller.selectedTab(inPane: $0)).id
        }
        let histories = try Dictionary(uniqueKeysWithValues: hiddenTabs.map {
            ($0, FrameHistory(view: try fixture.host(for: $0)))
        })
        defer { histories.values.forEach { $0.stop() } }

        for action in [PaneTilingAction.increaseMasterRatio, .increaseMasterCount, .moveNext,
                       .promote, .decreaseMasterCount, .decreaseMasterRatio] {
            #expect(fixture.controller.performTilingAction(action))
            fixture.render()
            fixture.render()
            for history in histories.values {
                #expect(history.view.isHiddenOrHasHiddenAncestor)
                #expect(history.sizes.isEmpty,
                        "\(action.rawValue): prepare must not repair an intentionally retained hidden host size")
                #expect(history.view.superview?.autoresizesSubviews == true)
            }
        }

        for pane in fixture.controller.allPaneIds {
            fixture.controller.focusPane(pane)
            fixture.render()
            let tab = try #require(fixture.controller.selectedTab(inPane: pane))
            let host = try fixture.host(for: tab.id)
            #expect(!host.isHiddenOrHasHiddenAncestor)
            #expect(host.frame == host.superview?.bounds)
            #expect(host.frame.size == fixture.hostingView.bounds.size)
            if let history = histories[tab.id] { #expect(host === history.view) }
        }
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.render()
        for tab in fixture.controller.allTabIds {
            let host = try fixture.host(for: tab)
            #expect(!host.isHiddenOrHasHiddenAncestor)
            #expect(host.frame == host.superview?.bounds)
        }
    }

    @Test
    func newPaneAndNativeDividerResizeKeepNormalAutoresizingAfterTheBatch() throws {
        let fixture = try Fixture(paneCount: 1)
        defer { fixture.close() }
        let originalPane = try #require(fixture.controller.focusedPaneId)
        let originalTab = try #require(fixture.controller.selectedTab(inPane: originalPane))
        let originalHost = try fixture.host(for: originalTab.id)
        #expect(fixture.controller.performTilingAction(.tile))
        fixture.render()
        let addedPane = try #require(fixture.controller.splitPane(
            originalPane, orientation: .horizontal, withTab: Tab(title: "New pane")
        ))
        fixture.render()
        let addedTab = try #require(fixture.controller.selectedTab(inPane: addedPane))
        let addedHost = try fixture.host(for: addedTab.id)
        for host in [originalHost, addedHost] {
            #expect(host.frame.width > 0 && host.frame.height > 0)
            #expect(host.frame == host.superview?.bounds)
            #expect(host.superview?.autoresizesSubviews == true)
        }
        let split = try #require(fixture.nativeSplits.first)
        let coordinator = try #require(split.delegate as? Fixture.SplitCoordinator)
        let oldSizes = [originalHost.frame.size, addedHost.frame.size]
        let available = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        // Exercise AppKit's native divider resize outside the tree coordinator's
        // batch. No synthetic UI event or extra SwiftUI layout is needed.
        coordinator.setPositionSafely(available * 0.67, in: split, layout: false)
        #expect([originalHost.frame.size, addedHost.frame.size] != oldSizes)
        for host in [originalHost, addedHost] {
            #expect(host.frame == host.superview?.bounds)
            #expect(host.superview?.autoresizesSubviews == true)
        }

        #expect(fixture.controller.closePane(addedPane))
        fixture.render()
        #expect(try fixture.host(for: originalTab.id) === originalHost)
        #expect(originalHost.frame.size == fixture.hostingView.bounds.size)
        #expect(originalHost.superview?.autoresizesSubviews == true)
        fixture.window.setContentSize(NSSize(width: 947, height: 713))
        fixture.render()
        #expect(originalHost.frame == originalHost.superview?.bounds)
        #expect(originalHost.frame.size == fixture.hostingView.bounds.size)
    }

    /// Captures each synchronous AppKit notification before another resize can replace its value.
    @MainActor
    private final class FrameHistory {
        let view: NSView
        let initialSize: NSSize
        private(set) var sizes: [NSSize] = []
        private var lastSize: NSSize
        private let previouslyPostedFrameChanges: Bool
        private var observer: NSObjectProtocol?

        init(view: NSView) {
            self.view = view
            initialSize = view.frame.size
            lastSize = view.frame.size
            previouslyPostedFrameChanges = view.postsFrameChangedNotifications
            view.postsFrameChangedNotifications = true
            // A synchronous adapter is necessary: an asynchronous notification consumer
            // would read the final NSView frame and lose earlier sizes from the same stack.
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordCurrentSize() }
            }
        }

        private func recordCurrentSize() {
            let size = view.frame.size
            guard size != lastSize else { return }
            sizes.append(size)
            lastSize = size
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            view.postsFrameChangedNotifications = previouslyPostedFrameChanges
        }
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
            hostingView.layoutSubtreeIfNeeded()
        }

        private static func view(for controller: BonsplitController) -> RenderedView {
            BonsplitView(controller: controller, contentRevision: 1) { tab, _ in
                AnchorProbe(tab: tab.id)
            } emptyPane: { _ in EmptyView() }
        }

        var nativeSplits: [NSSplitView] {
            descendants(of: hostingView).compactMap { $0 as? NSSplitView }
        }

        func host(for tab: TabID) throws -> NSView {
            let anchor = try #require(descendants(of: hostingView).first {
                $0.identifier?.rawValue == tab.id.uuidString
            })
            var candidate = anchor.superview
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
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        }
    }
}
