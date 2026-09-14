@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

#if DEBUG
@Suite(.serialized)
@MainActor
struct TabBarDiagnosticsTests {
    @Test
    func resolverBurstPreservesEveryExistingDeliveryWithoutCoalescing() async {
        let resolver = TabBarScrollViewResolver.ResolverView()
        let (deliveries, continuation) = AsyncStream<Int>.makeStream()
        var calls = 0
        resolver.onResolve = { scrollView in
            #expect(scrollView == nil)
            calls += 1
            continuation.yield(calls)
            if calls == 3 { continuation.finish() }
        }
        for _ in 0..<3 { resolver.resolveScrollView() }
        var observed: [Int] = []
        for await delivery in deliveries { observed.append(delivery) }
        withExtendedLifetime(resolver) {}
        #expect(observed == [1, 2, 3])
    }

    @Test
    func queuedResolverDoesNotRetainItsView() async {
        var resolver: TabBarScrollViewResolver.ResolverView? = .init()
        let readWeakResolver = { [weak resolver] in resolver }
        resolver?.resolveScrollView()
        resolver = nil
        #expect(readWeakResolver() == nil)
        await passExistingResolverQueue()
    }

    @Test
    func realEightPaneResizeKeepsResolversMounted() async throws {
        _ = NSApplication.shared
        var configuration = BonsplitConfiguration()
        configuration.appearance.enableAnimations = false
        let controller = BonsplitController(configuration: configuration)
        for index in 1..<8 {
            _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
        }
        #expect(controller.performTilingAction(.tile))
        let root = NSHostingView(rootView: BonsplitView(controller: controller, contentRevision: 1) { _, _ in Color.clear })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.orderOut(nil); window.contentView = nil }
        root.layoutSubtreeIfNeeded()
        await passExistingResolverQueue()
        root.layoutSubtreeIfNeeded()
        #expect(resolverCount(in: root) == 8)
        window.setContentSize(NSSize(width: 1450, height: 900))
        root.layoutSubtreeIfNeeded()
        await passExistingResolverQueue()
        root.layoutSubtreeIfNeeded()
        #expect(resolverCount(in: root) == 8)
        #expect(root.window === window)
    }

    /// Uses the production resolver's existing FIFO delivery as a completion signal.
    private func passExistingResolverQueue() async {
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

    private func resolverCount(in view: NSView) -> Int {
        (view is TabBarScrollViewResolver.ResolverView ? 1 : 0) + view.subviews.reduce(0) { $0 + resolverCount(in: $1) }
    }
}
#endif
