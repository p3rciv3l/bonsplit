@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct TabBarActionLaneTests {
    @Test
    func fittingActionLaneKeepsOnlyTheTabStripScrollViewAcrossResizes() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        await deliverLayout(fixture)
        let strip = try #require(fixture.bridge.scrollView)
        let initialLaneWidth = try reservedActionLaneWidth(in: fixture.hosting)
        #expect(nativeScrollViews(in: fixture.hosting).count == 1)

        for width in [CGFloat(840), 760, 820] {
            fixture.window.setContentSize(NSSize(width: width, height: 40))
            await deliverLayout(fixture)
            #expect(fixture.bridge.scrollView === strip)
            #expect(nativeScrollViews(in: fixture.hosting).count == 1)
            let resizedLaneWidth = try reservedActionLaneWidth(in: fixture.hosting)
            #expect(abs(resizedLaneWidth - initialLaneWidth) <= 1)
        }
    }

    @Test
    func overflowingActionLaneRemainsScrollableAndReturnsToDirectRowWhenWidened() async throws {
        let buttons = (0..<12).map { index in
            BonsplitConfiguration.SplitActionButton(
                id: "action-\(index)",
                systemImage: "star",
                tooltip: "Action \(index)",
                action: .custom("action-\(index)")
            )
        }
        let fixture = try makeFixture(buttons: buttons, width: 180)
        defer { close(fixture) }
        await deliverLayout(fixture)
        let strip = try #require(fixture.bridge.scrollView)
        let scrollViews = nativeScrollViews(in: fixture.hosting)
        #expect(scrollViews.count == 2)
        let lane = try #require(scrollViews.first { $0 !== strip })
        let document = try #require(lane.documentView)
        let maximumOffset = document.bounds.width - lane.contentView.bounds.width
        try #require(maximumOffset > 1)

        lane.contentView.scroll(to: NSPoint(x: maximumOffset, y: lane.contentView.bounds.minY))
        lane.reflectScrolledClipView(lane.contentView)
        await deliverLayout(fixture)
        #expect(lane.contentView.bounds.minX > 1)
        #expect(abs(lane.contentView.bounds.minX - maximumOffset) <= 1)

        fixture.window.setContentSize(NSSize(width: 1200, height: 40))
        await deliverLayout(fixture)
        #expect(fixture.bridge.scrollView === strip)
        #expect(nativeScrollViews(in: fixture.hosting).count == 1)
        #expect(lane.superview == nil || !lane.isDescendant(of: fixture.hosting))
    }

    @Test(arguments: [false, true])
    func shrinkingIntrinsicActionWidthRestoresTheReservedLaneAfterGrowth(changeFont: Bool) async throws {
        let fixture = try makeFixture(width: 1200)
        defer { close(fixture) }
        await deliverLayout(fixture)
        let baseline = try reservedActionLaneWidth(in: fixture.hosting)
        let originalFontSize = fixture.controller.configuration.appearance.tabTitleFontSize
        let strip = try #require(fixture.bridge.scrollView)

        if changeFont {
            fixture.controller.configuration.appearance.tabTitleFontSize = 72
        } else {
            fixture.controller.configuration.appearance.splitButtons = BonsplitConfiguration.SplitActionButton.defaults.map { button in
                var enlarged = button
                enlarged.icon = .emoji("WWWW", scale: 3)
                return enlarged
            }
        }
        await deliverLayout(fixture)
        let enlargedWidth = try reservedActionLaneWidth(in: fixture.hosting)
        try #require(enlargedWidth > baseline + 20)

        fixture.controller.configuration.appearance.tabTitleFontSize = originalFontSize
        fixture.controller.configuration.appearance.splitButtons = BonsplitConfiguration.SplitActionButton.defaults
        await deliverLayout(fixture)
        let restoredWidth = try reservedActionLaneWidth(in: fixture.hosting)
        #expect(abs(restoredWidth - baseline) <= 1)
        #expect(fixture.bridge.scrollView === strip)
        #expect(nativeScrollViews(in: fixture.hosting).count == 1)
    }

    private typealias Fixture = (
        controller: BonsplitController,
        bridge: TabBarScrollViewBridge,
        hosting: NSHostingView<AnyView>,
        window: NSWindow,
        defaults: UserDefaults,
        defaultsName: String
    )

    private func makeFixture(
        buttons: [BonsplitConfiguration.SplitActionButton] = BonsplitConfiguration.SplitActionButton.defaults,
        width: CGFloat = 800
    ) throws -> Fixture {
        _ = NSApplication.shared
        let defaultsName = "BonsplitTests.TabBarActionLane.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set("standard", forKey: "workspacePresentationMode")
        var configuration = BonsplitConfiguration()
        configuration.appearance.enableAnimations = false
        configuration.appearance.splitButtons = buttons
        let controller = BonsplitController(configuration: configuration)
        let pane = try #require(controller.internalController.rootNode.allPanes.first)
        pane.tabs = [TabItem(title: "Terminal")]
        pane.selectedTabId = pane.tabs.first?.id
        let bridge = TabBarScrollViewBridge()
        let hosting = NSHostingView(rootView: AnyView(
            TabBarView(pane: pane, isFocused: true, showSplitButtons: true, scrollViewBridge: bridge)
                .environment(controller)
                .environment(controller.internalController)
                .defaultAppStorage(defaults)
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        return (controller, bridge, hosting, window, defaults, defaultsName)
    }

    private func close(_ fixture: Fixture) {
        fixture.window.orderOut(nil)
        fixture.window.contentView = nil
        fixture.window.close()
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsName)
    }

    private func deliverLayout(_ fixture: Fixture) async {
        // Drain the production resolver's two existing delivery stages so native
        // attachment and geometry-driven preferences reach their next layout.
        fixture.hosting.layoutSubtreeIfNeeded()
        await passResolverQueue()
        fixture.hosting.layoutSubtreeIfNeeded()
        await passResolverQueue()
        fixture.hosting.layoutSubtreeIfNeeded()
    }

    private func passResolverQueue() async {
        let resolver = TabBarScrollViewResolver.ResolverView()
        let (deliveries, continuation) = AsyncStream<Void>.makeStream()
        resolver.onResolve = { _ in
            continuation.yield(())
            continuation.finish()
        }
        resolver.resolveScrollView()
        for await _ in deliveries { break }
        withExtendedLifetime(resolver) {}
    }

    private func nativeScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews(in: $0) }
    }

    private func reservedActionLaneWidth(in view: NSView) throws -> CGFloat {
        if let drag = view as? TabBarDragZoneView.DragNSView,
           case .trailingEmptyChrome(_, let width) = drag.hitRegion {
            return width
        }
        for child in view.subviews {
            if let width = try? reservedActionLaneWidth(in: child) { return width }
        }
        throw MissingActionLane()
    }

    private struct MissingActionLane: Error {}
}
