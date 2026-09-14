import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller
    @State private var paneHosting = PaneHostingCoordinator()

    let contentBuilder: (TabItem, PaneID, TabContentContext) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    var showSplitButtons: Bool = true
    var tabBarVisibility: TabBarVisibility = .always
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15
    let contentRevision: AnyHashable

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TabBarColors.paneBackground(for: appearance))
                .focusable()
                .focusEffectDisabled()
                .onChange(of: geometry.size) { _, newSize in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
                .onChange(of: controller.rootNode.allPaneIds) { _, paneIds in
                    paneHosting.retainPanes(paneIds)
                }
        }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        // Get frame in global coordinate space
        let frame = geometry.frame(in: .global)
        controller.containerFrame = frame
        onGeometryChange?(false)  // Container resize is not a drag
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        if !enableAnimations {
            NativeSplitTreeView(
                rootNode: controller.rootNode,
                layout: PaneTilingTree(controller.rootNode),
                controller: controller,
                isInteractive: controller.isInteractive,
                isTilingEnabled: controller.paneTiling.layout != .manual,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                appearance: appearance,
                showSplitButtons: showSplitButtons,
                tabBarVisibility: tabBarVisibility,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                zoomedPaneId: controller.zoomedPaneId,
                paneHosting: paneHosting,
                contentRevision: contentRevision
            )
        } else {
        SplitNodeView(
            node: controller.rootNode,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            appearance: appearance,
            showSplitButtons: showSplitButtons,
            tabBarVisibility: tabBarVisibility,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            enableAnimations: enableAnimations,
            animationDuration: animationDuration,
            zoomedPaneId: controller.zoomedPaneId,
            paneHosting: paneHosting,
            contentRevision: contentRevision
        )
        .overlay {
            PaneHostingParkingView(paneHosting: paneHosting)
                .allowsHitTesting(false)
        }
        }
    }
}
