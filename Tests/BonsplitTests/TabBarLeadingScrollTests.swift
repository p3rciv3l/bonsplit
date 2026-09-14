@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct TabBarLeadingScrollTests {
    @Test(arguments: [8, 16])
    func everyRenderedTabBarResolverFindsItsOwnNativeScrollView(paneCount: Int) async throws {
        _ = NSApplication.shared
        let controller = BonsplitController()
        for index in 1..<paneCount {
            _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
        }
        #expect(controller.performTilingAction(.tile))
        let root = NSHostingView(rootView: BonsplitView(controller: controller, contentRevision: 1) { _, _ in Color.clear })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        let resolvers = collectResolvers(in: root)
        try #require(resolvers.count == paneCount)
        let (deliveries, continuation) = AsyncStream<(Int, Bool)>.makeStream()
        for (index, resolver) in resolvers.enumerated() {
            let original = resolver.onResolve
            resolver.onResolve = { scrollView in
                original?(scrollView)
                continuation.yield((index, scrollView != nil))
            }
            resolver.resolveScrollView()
        }
        var resolved: [Int: Bool] = [:]
        for await (index, hasScrollView) in deliveries {
            resolved[index] = hasScrollView
            if resolved.count == resolvers.count { break }
        }
        continuation.finish()
        #expect(resolved.count == paneCount)
        #expect(resolved.values.allSatisfy { $0 })
        #expect(Set(resolvers.compactMap { $0.enclosingScrollView.map(ObjectIdentifier.init) }).count == paneCount)
    }

    @Test
    func leadingRequestIsSkippedOnlyWhileCurrentNativeAndFallbackGeometryFit() {
        let (scrollView, document, bridge) = makeBridge()
        var requests: [TabBarStyling.ScrollTarget] = []
        func request(contentWidth: CGFloat = 180, containerWidth: CGFloat = 349) {
            bridge.performScrollRequest(to: .leading, fallbackContentWidth: contentWidth, fallbackContainerWidth: containerWidth) {
                requests.append($0)
            }
        }

        request()
        #expect(requests.isEmpty)
        // Changes on the same bridge must never be hidden by a cached target.
        document.frame.size.width = 500
        request(contentWidth: 500)
        #expect(requests.count == 1)
        document.frame.size.width = 180
        request()
        #expect(requests.count == 1)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0.75, y: 0))
        #expect(abs(scrollView.contentView.bounds.origin.x) > 0.5)
        request()
        #expect(requests.count == 2)
        bridge.enforceLeadingEdgeIfContentFits(reason: "test.positiveOffset")
        #expect(abs(scrollView.contentView.bounds.origin.x) <= 0.5)
        request()
        #expect(requests.count == 2)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: -0.75, y: 0))
        #expect(scrollView.contentView.bounds.origin.x < -0.5)
        request()
        #expect(requests.count == 3)
        bridge.enforceLeadingEdgeIfContentFits(reason: "test.negativeOffset")
        #expect(abs(scrollView.contentView.bounds.origin.x) <= 0.5)
    }

    @Test(arguments: UnsafeMetrics.allCases)
    func incompleteOverflowingOrNonstandardMetricsKeepTheRequest(condition: UnsafeMetrics) {
        let (scrollView, document, bridge) = makeBridge()
        var fallbackContentWidth: CGFloat = 180
        var fallbackContainerWidth: CGFloat = 349
        switch condition {
        case .missingScrollView: bridge.attach(nil)
        case .missingDocument: scrollView.documentView = nil
        case .zeroViewport:
            scrollView.setFrameSize(NSSize(width: 0, height: scrollView.frame.height))
            scrollView.tile()
            #expect(scrollView.contentView.bounds.width == 0)
        case .nativeOverflow: document.frame.size.width = 500
        case .fallbackOverflow: fallbackContentWidth = 500
        case .unknownFallback: fallbackContentWidth = 0
        case .nonFiniteFallback: fallbackContainerWidth = .nan
        case .horizontalInset: scrollView.contentInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        case .rightToLeft: scrollView.userInterfaceLayoutDirection = .rightToLeft
        }
        var requested = false

        bridge.performScrollRequest(to: .leading, fallbackContentWidth: fallbackContentWidth, fallbackContainerWidth: fallbackContainerWidth) { _ in
            requested = true
        }

        #expect(requested)
    }

    @Test
    func selectedTargetsAlwaysReachTheRequestIncludingRepeatedSelectionAndResize() {
        let (scrollView, document, bridge) = makeBridge()
        let first = UUID()
        let second = UUID()
        var requests: [TabBarStyling.ScrollTarget] = []
        for target in [first, first, second, first] {
            bridge.performScrollRequest(to: .selectedTab(target), fallbackContentWidth: 180, fallbackContainerWidth: 349) {
                requests.append($0)
            }
            document.frame.size.width += 200
            scrollView.frame.size.width -= 20
        }
        #expect(requests == [.selectedTab(first), .selectedTab(first), .selectedTab(second), .selectedTab(first)])
    }

    @Test(arguments: NonstandardCoordinates.allCases, CorrectionEndpoint.allCases)
    func nativeCorrectionPreservesNonstandardLeadingCoordinates(coordinates: NonstandardCoordinates, endpoint: CorrectionEndpoint) {
        let (scrollView, _, bridge) = makeBridge()
        coordinates.apply(to: scrollView)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 32, y: 0))
        #expect(scrollView.contentView.bounds.origin.x == 32)
        switch endpoint {
        case .attach: bridge.attach(scrollView)
        case .enforce: bridge.enforceLeadingEdgeIfContentFits(reason: "test.nonstandard")
        case .reset: bridge.resetToLeadingEdgeIfNeeded(reason: "test.nonstandard")
        }
        #expect(scrollView.contentView.bounds.origin.x == 32)
    }

    @Test(arguments: NonstandardCoordinates.allCases)
    func deferredCorrectionRechecksCoordinatesBeforeChangingNativeOffset(coordinates: NonstandardCoordinates) async {
        let (scrollView, _, bridge) = makeBridge()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 32, y: 0))
        bridge.resetToLeadingEdgeIfNeeded(reason: "test.beforeCoordinateChange")
        #expect(scrollView.contentView.bounds.origin.x == 0)
        coordinates.apply(to: scrollView)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 32, y: 0))
        await Self.passExistingResolverQueue()
        #expect(scrollView.contentView.bounds.origin.x == 32)
    }

    @Test(arguments: [false, true])
    func deferredCorrectionUsesCurrentContentFitInsteadOfUndoingANewerOverflowSelection(contentBecomesOverflowing: Bool) async {
        let (scrollView, document, bridge) = makeBridge()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 32, y: 0))
        bridge.resetToLeadingEdgeIfNeeded(reason: "test.beforeContentChange")
        #expect(scrollView.contentView.bounds.origin.x == 0)
        if contentBecomesOverflowing { document.frame.size.width = 500 }
        bridge.performScrollRequest(to: .selectedTab(UUID()), fallbackContentWidth: document.frame.width, fallbackContainerWidth: 349) { _ in
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 32, y: 0))
        }
        await Self.passExistingResolverQueue()
        #expect(scrollView.contentView.bounds.origin.x == (contentBecomesOverflowing ? 32 : 0))
    }

    @Test
    func renderedTabBarSkipsFittingResizeRequestsButStillScrollsSelectionAndOverflow() async throws {
        let fixture = try RenderedFixture()
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)
        #expect(abs(scrollView.contentView.bounds.origin.x) <= 0.5)
        let beforeFitResize = fixture.bridge.debugProxyScrollRequests

        fixture.window.setContentSize(NSSize(width: 700, height: 40))
        await fixture.deliverLayoutAndQueuedScrollCallbacks()

        #expect(fixture.bridge.debugProxyScrollRequests == beforeFitResize)
        #expect(abs(scrollView.contentView.bounds.origin.x) <= 0.5)

        let beforeOverflow = fixture.bridge.debugProxyScrollRequests
        let tabs = (0..<10).map { TabItem(title: "Long terminal tab \($0)") }
        fixture.pane.tabs = tabs
        fixture.pane.selectedTabId = tabs.last?.id
        fixture.window.setContentSize(NSSize(width: 300, height: 40))
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(fixture.bridge.debugProxyScrollRequests > beforeOverflow)
        let trailingOffset = scrollView.contentView.bounds.origin.x
        #expect(trailingOffset > 0.5)

        let beforeSelection = fixture.bridge.debugProxyScrollRequests
        fixture.pane.selectedTabId = tabs.first?.id
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(fixture.bridge.debugProxyScrollRequests > beforeSelection)
        #expect(scrollView.contentView.bounds.origin.x < trailingOffset)

        // Keep the selected ID, move its tab to the trailing end, and resize.
        let beforeReorderResize = fixture.bridge.debugProxyScrollRequests
        fixture.pane.moveTab(from: 0, to: fixture.pane.tabs.count)
        fixture.window.setContentSize(NSSize(width: 260, height: 40))
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(fixture.bridge.debugProxyScrollRequests > beforeReorderResize)
        #expect(scrollView.contentView.bounds.origin.x > 0.5)
    }

    @Test(arguments: [CGFloat(0), CGFloat(54)], [0, 1])
    func resizeProjectsCurrentStripWidthWithoutAStaleGeometryPass(leadingInset: CGFloat, paneIndex: Int) async throws {
        let fixture = try RenderedFixture(leadingInset: leadingInset, paneIndex: paneIndex, paneCount: 2, showSplitButtons: true)
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)
        let originalScrollView = ObjectIdentifier(scrollView)
        fixture.bridge.debugTracksViewportProjections = true

        for width in [CGFloat(700), CGFloat(220), CGFloat(800)] {
            let firstProjection = fixture.bridge.debugViewportProjections.count
            fixture.window.setContentSize(NSSize(width: width, height: 40))
            await fixture.deliverLayoutAndQueuedScrollCallbacks()

            let projections = Array(fixture.bridge.debugViewportProjections.dropFirst(firstProjection))
            try #require(!projections.isEmpty)
            // The first deferred GeometryReader evaluation is part of the resize,
            // not just its eventual stable result. A stale projection forces a
            // second header/layout transaction for every pane whose width changes.
            #expect(projections.allSatisfy { abs($0.viewportWidth - $0.projectedWidth) <= 0.5 })
            let expectedStripWidth = width - (paneIndex == 0 ? leadingInset : 0)
            #expect(abs(scrollView.frame.width - expectedStripWidth) <= 0.5)
            #expect(fixture.bridge.scrollView.map(ObjectIdentifier.init) == originalScrollView)
        }
    }

    @Test(arguments: [CGFloat(0), CGFloat(54)], [0, 1])
    func narrowActionLaneKeepsSelectedOverflowTabVisibleAcrossResize(leadingInset: CGFloat, paneIndex: Int) async throws {
        let fixture = try RenderedFixture(leadingInset: leadingInset, paneIndex: paneIndex, paneCount: 2, showSplitButtons: true)
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)
        let originalScrollView = ObjectIdentifier(scrollView)
        let tabs = (0..<8).map { TabItem(title: "Long terminal tab \($0)") }
        fixture.pane.tabs = tabs
        fixture.pane.selectedTabId = tabs.last?.id

        for width in [CGFloat(320), CGFloat(220), CGFloat(700)] {
            fixture.window.setContentSize(NSSize(width: width, height: 40))
            await fixture.deliverLayoutAndQueuedScrollCallbacks()
            #expect(fixture.bridge.scrollView.map(ObjectIdentifier.init) == originalScrollView)
            #expect(scrollView.contentView.bounds.origin.x > 0.5)
            let document = try #require(scrollView.documentView)
            let lastTab = try #require(tabHitRegionViews(in: document).max {
                $0.convert($0.bounds, to: document).minX < $1.convert($1.bounds, to: document).minX
            })
            let selectedFrame = lastTab.convert(lastTab.bounds, to: scrollView.contentView)
            #expect(selectedFrame.intersects(scrollView.contentView.bounds))
            // The narrow cases need a scrolling action lane; at 700 points all
            // controls fit directly. Neither path may replace the tab strip.
            #expect(nativeScrollViews(in: fixture.hosting).count == (width == 700 ? 1 : 2))
        }

        fixture.pane.selectedTabId = tabs.first?.id
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(abs(scrollView.contentView.bounds.origin.x) <= 0.5)
    }

    @Test(arguments: [false, true])
    func zeroAndInsetConstrainedWidthsUseTheActualStripProposal(rightToLeft: Bool) async throws {
        let fixture = try RenderedFixture(
            leadingInset: 54,
            showSplitButtons: true,
            layoutDirection: rightToLeft ? .rightToLeft : .leftToRight
        )
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)
        fixture.bridge.debugTracksViewportProjections = true

        for width in [CGFloat(0), 20, 54, 55, 120, 800] {
            let firstProjection = fixture.bridge.debugViewportProjections.count
            fixture.window.setContentSize(NSSize(width: width, height: 40))
            await fixture.deliverLayoutAndQueuedScrollCallbacks()
            #expect(abs(fixture.hosting.bounds.width - width) <= 0.5)
            let projections = Array(fixture.bridge.debugViewportProjections.dropFirst(firstProjection))
            try #require(!projections.isEmpty)
            #expect(projections.allSatisfy { abs($0.viewportWidth - $0.projectedWidth) <= 0.5 })
            #expect(abs(scrollView.frame.width - max(0, width - 54)) <= 0.5)
            #expect(fixture.bridge.scrollView === scrollView)
        }
    }

    @Test
    func runtimeHeightAndInsetChangesRetainTheNativeTabStrip() async throws {
        let fixture = try RenderedFixture(leadingInset: 54, showSplitButtons: true)
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)

        for (inset, height) in [(CGFloat(80), CGFloat(48)), (0, 1), (32, 28)] {
            fixture.controller.configuration.appearance.tabBarLeadingInset = inset
            fixture.controller.configuration.appearance.tabBarHeight = height
            fixture.window.setContentSize(NSSize(width: 800, height: max(40, height)))
            await fixture.deliverLayoutAndQueuedScrollCallbacks()
            #expect(abs(scrollView.frame.width - (800 - inset)) <= 0.5)
            #expect(abs(scrollView.frame.height - max(1, height)) <= 0.5)
            #expect(fixture.bridge.scrollView === scrollView)
        }
    }

    @Test
    func reorderingFirstPaneTransfersItsLeadingInsetWithoutReplacingTheTabStrip() async throws {
        let fixture = try RenderedFixture(leadingInset: 54, paneCount: 2, showSplitButtons: true)
        defer { fixture.close() }
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        let scrollView = try #require(fixture.bridge.scrollView)
        #expect(abs(scrollView.frame.width - 746) <= 0.5)
        fixture.controller.focusPane(fixture.pane.id)
        #expect(fixture.controller.performTilingAction(.tile))
        #expect(fixture.controller.performTilingAction(.moveNext))
        #expect(fixture.controller.allPaneIds.first != fixture.pane.id)
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(abs(scrollView.frame.width - 800) <= 0.5)
        #expect(fixture.bridge.scrollView === scrollView)

        #expect(fixture.controller.performTilingAction(.movePrevious))
        #expect(fixture.controller.allPaneIds.first == fixture.pane.id)
        await fixture.deliverLayoutAndQueuedScrollCallbacks()
        #expect(abs(scrollView.frame.width - 746) <= 0.5)
        #expect(fixture.bridge.scrollView === scrollView)
    }

    enum UnsafeMetrics: CaseIterable {
        case missingScrollView, missingDocument, zeroViewport, nativeOverflow
        case fallbackOverflow, unknownFallback, nonFiniteFallback, horizontalInset, rightToLeft
    }

    enum CorrectionEndpoint: CaseIterable { case attach, enforce, reset }

    enum NonstandardCoordinates: CaseIterable {
        case rightToLeft, leftInset, rightInset

        @MainActor
        func apply(to scrollView: NSScrollView) {
            switch self {
            case .rightToLeft: scrollView.userInterfaceLayoutDirection = .rightToLeft
            case .leftInset: scrollView.contentInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
            case .rightInset: scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
            }
        }
    }

    private static func passExistingResolverQueue() async {
        let resolver = TabBarScrollViewResolver.ResolverView()
        let (deliveries, continuation) = AsyncStream<Void>.makeStream()
        resolver.onResolve = { _ in continuation.yield(()); continuation.finish() }
        resolver.resolveScrollView()
        for await _ in deliveries { break }
        withExtendedLifetime(resolver) {}
    }

    private func collectResolvers(in view: NSView) -> [TabBarScrollViewResolver.ResolverView] {
        (view as? TabBarScrollViewResolver.ResolverView).map { [$0] } ?? view.subviews.flatMap { collectResolvers(in: $0) }
    }

    private func tabHitRegionViews(in view: NSView) -> [NSView] {
        (view is any BonsplitTabItemHitRegionProviding ? [view] : []) + view.subviews.flatMap { tabHitRegionViews(in: $0) }
    }

    private func nativeScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews(in: $0) }
    }

    private func makeBridge() -> (NSScrollView, NSView, TabBarScrollViewBridge) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 349, height: 28))
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.userInterfaceLayoutDirection = .leftToRight
        scrollView.contentView = TransientOffsetClipView(frame: scrollView.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        document.userInterfaceLayoutDirection = .leftToRight
        scrollView.documentView = document
        let bridge = TabBarScrollViewBridge()
        bridge.attach(scrollView)
        return (scrollView, document, bridge)
    }

    private final class TransientOffsetClipView: NSClipView {
        // Preserve transient overscroll long enough to exercise the bridge's
        // correction contract through actual AppKit bounds, not mocked metrics.
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    @MainActor
    private final class RenderedFixture {
        let controller: BonsplitController
        let pane: PaneState
        let bridge = TabBarScrollViewBridge()
        let hosting: NSHostingView<AnyView>
        let window: NSWindow

        init(
            leadingInset: CGFloat = 0,
            paneIndex: Int = 0,
            paneCount: Int = 1,
            showSplitButtons: Bool = false,
            layoutDirection: LayoutDirection = .leftToRight
        ) throws {
            _ = NSApplication.shared
            var configuration = BonsplitConfiguration()
            configuration.appearance.enableAnimations = false
            configuration.appearance.tabBarLeadingInset = leadingInset
            controller = BonsplitController(configuration: configuration)
            for index in 1..<paneCount {
                _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
            }
            pane = try #require(controller.internalController.rootNode.allPanes.dropFirst(paneIndex).first)
            pane.tabs = [TabItem(title: "Terminal")]
            pane.selectedTabId = pane.tabs.first?.id
            bridge.debugTracksProxyRequests = true
            hosting = NSHostingView(rootView: AnyView(TabBarView(
                pane: pane,
                isFocused: true,
                showSplitButtons: showSplitButtons,
                scrollViewBridge: bridge
            ).environment(controller).environment(controller.internalController).environment(\.layoutDirection, layoutDirection)))
            hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
            window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
        }

        func deliverLayoutAndQueuedScrollCallbacks() async {
            // Resolver attachment and the existing stale-offset correction each
            // schedule a main-queue delivery. Drain those two explicit stages,
            // then read the layout they produced; no time-based settling.
            hosting.layoutSubtreeIfNeeded()
            await TabBarLeadingScrollTests.passExistingResolverQueue()
            hosting.layoutSubtreeIfNeeded()
            await TabBarLeadingScrollTests.passExistingResolverQueue()
            hosting.layoutSubtreeIfNeeded()
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

    }
}
