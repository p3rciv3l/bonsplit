import Foundation

public extension BonsplitController {
    /// Whether pane insertions and removals automatically update a tiling layout.
    var isTilingEnabled: Bool { tilingLayout != .manual }

    /// The active pane arrangement policy.
    var tilingLayout: PaneTilingLayout { internalController.paneTiling.layout }

    /// The desired number of panes in the master column, including zero.
    var masterCount: Int { internalController.paneTiling.masterCount }

    /// The fraction of available width assigned to the master column.
    var masterRatio: Double { internalController.paneTiling.masterRatio }

    /// The tiling settings to persist alongside the host's split-tree snapshot.
    var tilingConfiguration: PaneTilingConfiguration {
        PaneTilingConfiguration(layout: tilingLayout, masterCount: masterCount, masterRatio: masterRatio)
    }

    /// Restores tiling settings over the current panes in one layout update.
    ///
    /// Call this after restoring the pane tree and focused pane. The current
    /// tree becomes the manual-layout baseline when tiling is first enabled.
    /// Invalid values leave the controller unchanged.
    ///
    /// - Parameter configuration: Settings decoded from the host's saved session.
    /// - Returns: Whether the settings contain a nonnegative master count and a
    ///   finite master ratio between 0.1 and 0.9 inclusive and were applied.
    @discardableResult
    func restoreTilingConfiguration(_ configuration: PaneTilingConfiguration) -> Bool {
        guard internalController.paneTiling.restore(configuration, in: internalController) else { return false }
        delegate?.splitTabBar(self, didChangeGeometry: layoutSnapshot())
        return true
    }

    /// Performs a pane action without recreating panes or changing their tab identities.
    ///
    /// Split and close operations automatically reapply an enabled tiling layout.
    /// Monocle follows focus changes. Returning to manual mode restores surviving
    /// panes' saved split geometry and retains any panes created while tiling.
    /// Explicit divider resizing and equalizing instead adopt the current geometry
    /// as a manual layout, so later pane operations preserve those adjustments.
    ///
    /// - Parameter action: The layout, focus, ordering, or sizing action to apply.
    /// - Returns: Whether the action was applicable and completed.
    @discardableResult
    func performTilingAction(_ action: PaneTilingAction) -> Bool {
        performTilingAction(action, focusingPane: nil)
    }

    /// Shares focus, layout, and delegate publication with existing pane zoom actions.
    @discardableResult
    internal func performTilingAction(_ action: PaneTilingAction, focusingPane paneId: PaneID?) -> Bool {
        let previousFocus = focusedPaneId
        let previousZoom = zoomedPaneId
        if let paneId { internalController.focusPane(paneId) }
        guard internalController.paneTiling.perform(action, in: internalController) else { return false }
        if let focusedPaneId, focusedPaneId != previousFocus {
            delegate?.splitTabBar(self, didFocusPane: focusedPaneId)
        }
        // Host reconciliation needs an authoritative result even if a previous
        // external divider update is currently suppressing drag notifications.
        let onlyFocusChanged = (action == .focusNext || action == .focusPrevious) && previousZoom == zoomedPaneId
        if !onlyFocusChanged {
            delegate?.splitTabBar(self, didChangeGeometry: layoutSnapshot())
        }
        return true
    }
}
