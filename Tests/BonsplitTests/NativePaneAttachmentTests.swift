@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct NativePaneAttachmentTests {
    @Test(arguments: [1, 4, 16])
    func unchangedNativeUpdatesRefreshContentLookupWithoutReattaching(paneCount: Int) throws {
        let fixture = try Fixture(paneCount: paneCount)
        defer { fixture.close() }
        let before = fixture.cache.debugOperationCounts
        let hosts = try fixture.controller.allPaneIds.map { try fixture.hostView(for: $0) }

        for _ in 0..<3 {
            // Interactivity changes invoke the native update without changing pane
            // geometry or the content revision; identical SwiftUI values are elided.
            fixture.isInteractive.toggle()
            fixture.update()
        }

        let after = fixture.cache.debugOperationCounts
        #expect(after.hostRequests - before.hostRequests == paneCount * 3)
        #expect(after.contentAssignments == before.contentAssignments)
        #expect(after.attachments == before.attachments)
        #expect(after.installedFrames == before.installedFrames)
        for (pane, host) in zip(fixture.controller.allPaneIds, hosts) {
            #expect(try fixture.hostView(for: pane) === host)
            #expect(host.window === fixture.window)
            #expect(host.frame == host.superview?.bounds)
        }
    }

    @Test
    func contentRevisionAndPresentationChangesStillUpdateRetainedNativeHosts() throws {
        let fixture = try Fixture(paneCount: 2)
        defer { fixture.close() }
        let pane = try #require(fixture.controller.focusedPaneId)
        let anchor = try fixture.anchor(for: pane)
        let host = try fixture.hostView(for: pane)
        var before = fixture.cache.debugOperationCounts

        fixture.contentRevision = 2
        fixture.payload = "updated"
        fixture.update()

        #expect(try fixture.anchor(for: pane) === anchor)
        #expect(anchor.payload == "updated")
        #expect(try fixture.hostView(for: pane) === host)
        #expect(fixture.cache.debugOperationCounts.contentAssignments - before.contentAssignments == 2)
        #expect(fixture.cache.debugOperationCounts.attachments == before.attachments)
        #expect(fixture.cache.debugOperationCounts.installedFrames == before.installedFrames)

        for change in 0..<3 {
            before = fixture.cache.debugOperationCounts
            switch change {
            case 0: fixture.showSplitButtons = false
            case 1: fixture.tabBarVisibility = .multipleTabs
            default: fixture.contentViewLifecycle = .recreateOnSwitch
            }
            fixture.update()
            #expect(fixture.cache.debugOperationCounts.contentAssignments - before.contentAssignments == 2)
            #expect(fixture.cache.debugOperationCounts.attachments == before.attachments)
            #expect(fixture.cache.debugOperationCounts.installedFrames == before.installedFrames)
            #expect(try fixture.hostView(for: pane) === host)
            #expect(try fixture.anchor(for: pane).payload == "updated")

            let unchanged = fixture.cache.debugOperationCounts
            fixture.update()
            #expect(fixture.cache.debugOperationCounts.contentAssignments == unchanged.contentAssignments)
            #expect(fixture.cache.debugOperationCounts.attachments == unchanged.attachments)
        }
    }

    @Test
    func nativeUpdateRepairsChangedHostFrameAndParent() throws {
        let fixture = try Fixture(paneCount: 1)
        defer { fixture.close() }
        let pane = try #require(fixture.controller.focusedPaneId)
        let host = try fixture.hostView(for: pane)
        let slot = try #require(host.superview)
        host.frame = NSRect(x: 2, y: 3, width: 100, height: 80)
        var before = fixture.cache.debugOperationCounts

        fixture.contentRevision += 1
        fixture.update()

        #expect(host.frame == slot.bounds)
        #expect(try fixture.hostView(for: pane) === host)
        // The final geometry batch repairs an attached host's frame directly;
        // only an actual parent change needs the attachment lifecycle below.
        #expect(fixture.cache.debugOperationCounts.attachments == before.attachments)
        #expect(fixture.cache.debugOperationCounts.installedFrames == before.installedFrames)

        let otherParent = NSView(frame: slot.bounds)
        fixture.root.addSubview(otherParent)
        otherParent.addSubview(host)
        before = fixture.cache.debugOperationCounts
        fixture.contentRevision += 1
        fixture.update()

        #expect(host.superview === slot)
        #expect(host.frame == slot.bounds)
        #expect(otherParent.subviews.isEmpty)
        #expect(fixture.cache.debugOperationCounts.attachments == before.attachments + 1)
        #expect(fixture.cache.debugOperationCounts.installedFrames == before.installedFrames + 1)
    }

    @Test
    func legacyHostingSlotAttachmentStillRunsItsLifecycleOnRepeatedRequests() {
        let cache = PaneHostingCoordinator()
        cache.debugTracksOperations = true
        let host = cache.host(for: PaneID(), contentRevision: 1) { AnyView(EmptyView()) }
        let slot = PaneHostingSlotView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        cache.attach(host, to: slot)
        cache.attach(host, to: slot)
        #expect(cache.debugOperationCounts.attachments == 2)
        #expect(cache.debugOperationCounts.installedFrames == 2)
        #expect(host.view.superview === slot)
        #expect(host.view.frame == slot.bounds)
    }

    @MainActor
    private final class Fixture {
        typealias TreeView = NativeSplitTreeView<AttachmentAnchor, EmptyView>
        let controller: BonsplitController
        let cache = PaneHostingCoordinator()
        let root: NSHostingView<AnyView>
        let window: NSWindow
        var contentRevision = 1
        var isInteractive = true
        var payload = "initial"
        var showSplitButtons = true
        var tabBarVisibility: TabBarVisibility = .always
        var contentViewLifecycle: ContentViewLifecycle = .keepAllAlive

        init(paneCount: Int) throws {
            _ = NSApplication.shared
            var configuration = BonsplitConfiguration(contentViewLifecycle: .keepAllAlive)
            configuration.appearance.enableAnimations = false
            controller = BonsplitController(configuration: configuration)
            for index in 1..<paneCount {
                let pane = try #require(controller.allPaneIds.last)
                _ = try #require(controller.splitPane(pane, orientation: .vertical, withTab: Tab(title: "Pane \(index)")))
            }
            #expect(controller.performTilingAction(.tile))
            root = NSHostingView(rootView: AnyView(EmptyView()))
            root.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
            window = NSWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            cache.debugTracksOperations = true
            update()
        }

        func update() {
            let currentPayload = payload
            let source = TreeView(
                rootNode: controller.internalController.rootNode,
                layout: PaneTilingTree(controller.internalController.rootNode),
                controller: controller.internalController,
                isInteractive: isInteractive,
                isTilingEnabled: controller.isTilingEnabled,
                contentBuilder: { _, pane, _ in AttachmentAnchor(pane: pane, payload: currentPayload) },
                emptyPaneBuilder: { _ in EmptyView() },
                appearance: controller.configuration.appearance,
                showSplitButtons: showSplitButtons,
                tabBarVisibility: tabBarVisibility,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: nil,
                zoomedPaneId: controller.zoomedPaneId,
                paneHosting: cache,
                contentRevision: contentRevision
            )
            root.rootView = AnyView(source
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(controller)
                .environment(controller.internalController))
            root.layoutSubtreeIfNeeded()
        }

        func anchor(for pane: PaneID) throws -> AttachmentAnchorView {
            try #require(findAnchor(for: pane, in: root))
        }

        func hostView(for pane: PaneID) throws -> NSView {
            let anchor = try anchor(for: pane)
            var candidate: NSView? = anchor
            while let view = candidate {
                if view.superview is PaneDragContainerView { return view }
                candidate = view.superview
            }
            throw MissingHost()
        }

        private func findAnchor(for pane: PaneID, in view: NSView) -> AttachmentAnchorView? {
            if let anchor = view as? AttachmentAnchorView, anchor.pane == pane { return anchor }
            for child in view.subviews {
                if let found = findAnchor(for: pane, in: child) { return found }
            }
            return nil
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        private struct MissingHost: Error {}
    }

    private struct AttachmentAnchor: NSViewRepresentable {
        let pane: PaneID
        let payload: String

        func makeNSView(context: Context) -> AttachmentAnchorView {
            AttachmentAnchorView(pane: pane)
        }

        func updateNSView(_ nsView: AttachmentAnchorView, context: Context) {
            nsView.payload = payload
        }
    }

    private final class AttachmentAnchorView: NSView {
        let pane: PaneID
        var payload = ""

        init(pane: PaneID) {
            self.pane = pane
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
