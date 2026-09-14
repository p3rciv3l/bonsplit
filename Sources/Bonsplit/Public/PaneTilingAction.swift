/// A pane operation in the master-and-stack tiling layout.
///
/// Actions rearrange existing panes without moving their tabs between panes or
/// asking the host to recreate their contents.
public enum PaneTilingAction: String, CaseIterable, Sendable {
    /// Arrange panes into a master column and a stack column.
    case tile
    /// Display the focused pane across the available split area.
    case monocle
    /// Switch between the master-and-stack and monocle layouts.
    case toggleLayout
    /// Focus the next pane, wrapping after the last pane.
    case focusNext
    /// Focus the previous pane, wrapping before the first pane.
    case focusPrevious
    /// Move the focused pane one place forward in the tiling order.
    case moveNext
    /// Move the focused pane one place backward in the tiling order.
    case movePrevious
    /// Promote the focused pane to master, or the next pane if master is focused.
    case promote
    /// Add one pane to the master column.
    case increaseMasterCount
    /// Remove one pane from the master column, down to zero.
    case decreaseMasterCount
    /// Increase the master column's width by five percentage points.
    case increaseMasterRatio
    /// Decrease the master column's width by five percentage points.
    case decreaseMasterRatio
    /// Return to the manual split layout saved before tiling was enabled.
    case manual

    /// Whether the action intentionally changes which pane receives keyboard input.
    public nonisolated var changesFocus: Bool {
        switch self {
        case .focusNext, .focusPrevious, .promote:
            return true
        default:
            return false
        }
    }
}
