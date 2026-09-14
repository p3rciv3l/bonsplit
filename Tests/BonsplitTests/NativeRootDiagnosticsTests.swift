@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct NativeRootDiagnosticsTests {
#if DEBUG
    @Test(arguments: [8, 16])
    func nativeRootRetainsFramesAndIdentityThroughLayoutAndFitting(paneCount: Int) throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: paneCount)
        let host = NSHostingView(rootView: BonsplitView(controller: controller, contentRevision: 1) { _, _ in Color.clear })
        let window = makeWindow(contentView: host)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let root = try #require(descendants(of: host).compactMap { $0 as? NativeSplitTreeContainer }.first)
        let originalTree = try #require(root.treeView)
        let originalPaneIDs = controller.allPaneIds
        let frameBeforeFitting = root.frame
        let fittingSize = root.fittingSize
        #expect(fittingSize.width.isFinite && fittingSize.height.isFinite)
        #expect(root.frame == frameBeforeFitting)
        root.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(root.treeView === originalTree)
        #expect(root.window === window)
        #expect(root.treeView?.frame == root.bounds)
        #expect(controller.allPaneIds == originalPaneIDs)
    }

    @Test
    func nativeRepresentableKeepsDefaultSizingAcrossProposalShapes() throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: 2)
        let cache = PaneHostingCoordinator()
        let model = controller.internalController
        let native = NativeSplitTreeView(
            rootNode: model.rootNode, layout: PaneTilingTree(model.rootNode),
            controller: model, isInteractive: true, isTilingEnabled: true,
            contentBuilder: { _, _, _ in Color.clear }, emptyPaneBuilder: { _ in EmptyView() },
            appearance: controller.configuration.appearance, showSplitButtons: false,
            tabBarVisibility: .always, contentViewLifecycle: .keepAllAlive,
            onGeometryChange: nil, zoomedPaneId: nil, paneHosting: cache, contentRevision: 1
        )
        let host = NSHostingView(rootView: ProposalProbeLayout { native }.environment(controller).environment(model))
        let window = makeWindow(contentView: host)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let root = try #require(descendants(of: host).compactMap { $0 as? NativeSplitTreeContainer }.first)
        #expect(root.frame.size == host.bounds.size)
        #expect(root.treeView?.frame == root.bounds)
    }

    private func makeController(paneCount: Int) throws -> BonsplitController {
        var configuration = BonsplitConfiguration(contentViewLifecycle: .keepAllAlive)
        configuration.appearance.enableAnimations = false
        let controller = BonsplitController(configuration: configuration)
        for index in 1..<paneCount {
            _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
        }
        #expect(controller.performTilingAction(.tile))
        return controller
    }

    private func makeWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private struct ProposalProbeLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            for child in subviews {
                _ = child.sizeThatFits(.unspecified)
                _ = child.sizeThatFits(.zero)
                _ = child.sizeThatFits(.infinity)
                _ = child.sizeThatFits(ProposedViewSize(width: 1200, height: 900))
            }
            return CGSize(width: 1200, height: 900)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for child in subviews {
                child.place(at: bounds.origin, anchor: .topLeading,
                            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            }
        }
    }
#endif
}
