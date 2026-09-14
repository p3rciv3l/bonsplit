/// A pane-local selection and focus snapshot for a tab's content builder.
///
/// Use this value instead of querying the controller while rendering content.
/// It contains no observable model references and follows tab selection even
/// when ``ContentViewLifecycle/keepAllAlive`` retains inactive tab content.
public struct TabContentContext: Equatable, Sendable {
    /// Whether this tab is the pane's selected tab.
    ///
    /// A temporary fallback rendered while selection is missing is not selected.
    public let isSelected: Bool

    /// Whether this tab is selected in the focused pane.
    ///
    /// This describes Bonsplit focus, not whether the containing app window or
    /// workspace currently accepts keyboard input. An unselected tab is never focused.
    /// During a move, retained content in the old pane does not inherit focus
    /// from the same tab's new pane.
    public let isFocused: Bool

    init(isSelected: Bool, isPaneFocused: Bool) {
        self.isSelected = isSelected
        self.isFocused = isSelected && isPaneFocused
    }
}
