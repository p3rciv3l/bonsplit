import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         }
///     }
/// }
/// ```
public struct BonsplitView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID, TabContentContext) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    private let contentRevision: AnyHashable

    /// Initialize with a controller, content builder, and empty pane builder
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - contentRevision: Changes when external values captured by content builders change.
    ///     The default refreshes content on every initialization. A stable value lets
    ///     callers avoid refreshing pane content for geometry-only updates.
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    public init(
        controller: BonsplitController,
        contentRevision: AnyHashable = UUID(),
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentRevision = contentRevision
        self.contentBuilder = { tab, paneId, _ in content(tab, paneId) }
        self.emptyPaneBuilder = emptyPane
    }

    /// Initializes tab content with a pane-local selection and focus snapshot.
    ///
    /// The context avoids a global controller lookup from the content builder.
    ///
    /// - Parameters:
    ///   - controller: The controller managing the tab state.
    ///   - contentRevision: Changes when external content-builder inputs change.
    ///   - content: Builds content from the tab, pane ID, and current tab context.
    ///   - emptyPane: Builds content for an empty pane.
    public init(
        controller: BonsplitController,
        contentRevision: AnyHashable = UUID(),
        @ViewBuilder content: @escaping (Tab, PaneID, TabContentContext) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentRevision = contentRevision
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    public var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId, context in
                contentBuilder(Tab(from: tabItem), PaneID(id: paneId.id), context)
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            appearance: controller.configuration.appearance,
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            tabBarVisibility: controller.configuration.tabBarVisibility,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            },
            enableAnimations: controller.configuration.appearance.enableAnimations,
            animationDuration: controller.configuration.appearance.animationDuration,
            contentRevision: contentRevision
        )
        .environment(controller)
        .environment(controller.internalController)
    }
}

// MARK: - Convenience initializer with default empty view

extension BonsplitView where EmptyContent == DefaultEmptyPaneView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - contentRevision: Changes when external content-builder inputs change;
    ///     the default preserves refresh-on-initialization behavior.
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    public init(
        controller: BonsplitController,
        contentRevision: AnyHashable = UUID(),
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentRevision = contentRevision
        self.contentBuilder = { tab, paneId, _ in content(tab, paneId) }
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
    }

    /// Initializes contextual tab content with the default empty pane view.
    ///
    /// - Parameters:
    ///   - controller: The controller managing the tab state.
    ///   - contentRevision: Changes when external content-builder inputs change.
    ///   - content: Builds content from the tab, pane ID, and current tab context.
    public init(
        controller: BonsplitController,
        contentRevision: AnyHashable = UUID(),
        @ViewBuilder content: @escaping (Tab, PaneID, TabContentContext) -> Content
    ) {
        self.controller = controller
        self.contentRevision = contentRevision
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
    }
}

/// Default view shown when a pane has no tabs
public struct DefaultEmptyPaneView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
