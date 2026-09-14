/// The current arrangement policy for a controller's panes.
public enum PaneTilingLayout: String, CaseIterable, Codable, Sendable {
    /// Preserve user-created split orientations and divider positions.
    case manual
    /// Arrange panes in a master column beside a stack column.
    case tile
    /// Show only the focused pane while retaining every pane and tab.
    case monocle
}
