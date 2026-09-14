@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct HostingViewDiagnosticsTests {
#if DEBUG
    @Test
    func cachedHostingControllerRetainsGeometryAndIdentityThroughLayout() throws {
        _ = NSApplication.shared
        let cache = PaneHostingCoordinator()
        let controller = cache.host(for: PaneID(), contentRevision: 1) { AnyView(Color.clear) }
        let host = try #require(controller.view as? NSHostingView<AnyView>)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.addSubview(host)
        defer { window.orderOut(nil); window.contentView = nil }
        host.setFrameSize(NSSize(width: 320, height: 240))
        host.setFrameOrigin(NSPoint(x: 10, y: 20))
        root.layoutSubtreeIfNeeded()

        host.setFrameSize(NSSize(width: 400, height: 300))
        host.setFrameOrigin(NSPoint(x: 30, y: 40))
        host.needsUpdateConstraints = true
        host.needsLayout = true
        root.updateConstraintsForSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        #expect(host.frame == NSRect(x: 30, y: 40, width: 400, height: 300))
        #expect(host.window === window)
        #expect(controller.view === host)
    }

    @Test
    func realBonsplitPaneLayoutPreservesPaneCount() throws {
        _ = NSApplication.shared
        var configuration = BonsplitConfiguration()
        configuration.appearance.enableAnimations = false
        let controller = BonsplitController(configuration: configuration)
        for index in 1..<4 {
            _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
        }
        let root = NSHostingView(rootView: BonsplitView(controller: controller) { _, _ in Color.clear })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.orderOut(nil); window.contentView = nil }
        root.layoutSubtreeIfNeeded()
        #expect(controller.performTilingAction(.tile))
        root.layoutSubtreeIfNeeded()
        #expect(controller.allPaneIds.count == 4)
    }
#endif

    @Test(arguments: [false, true])
    func hostingControllerPropagatesDisabledSizingBeforeAndAfterLoad(configureBeforeLoad: Bool) throws {
        let controller = NonDraggableHostingController(rootView: AnyView(EmptyView()))
        if configureBeforeLoad { controller.sizingOptions = [] }
        let host = try #require(controller.view as? NSHostingView<AnyView>)
        if !configureBeforeLoad {
            // Positive control: an ordinary host retains the platform's default sizing.
            #expect(!host.sizingOptions.isEmpty)
        }
        if !configureBeforeLoad { controller.sizingOptions = [] }
        #expect(controller.sizingOptions.isEmpty)
        #expect(host.sizingOptions.isEmpty)
    }

    @Test
    func cachedPaneHostingViewUsesExplicitNativeSizing() throws {
        let cache = PaneHostingCoordinator()
        let pane = PaneID()
        let controller = cache.host(for: pane, contentRevision: 1) { AnyView(EmptyView()) }
        let host = try #require(controller.view as? NSHostingView<AnyView>)
        #expect(controller.sizingOptions.isEmpty)
        #expect(host.sizingOptions.isEmpty)
        let retained = cache.host(for: pane, contentRevision: 2) { AnyView(Color.clear) }
        #expect(retained === controller)
        #expect(retained.view === host)
        #expect(host.sizingOptions.isEmpty)
    }
}
