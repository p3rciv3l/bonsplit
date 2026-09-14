/// Persistable layout settings for a controller's existing panes.
///
/// Pane membership and ordering remain part of the host's split-tree snapshot.
/// Restore this configuration after restoring that tree and its focused pane.
public struct PaneTilingConfiguration: Codable, Equatable, Sendable {
    /// The arrangement policy to restore.
    public let layout: PaneTilingLayout

    /// The desired number of panes in the master column, including zero.
    public let masterCount: Int

    /// The master column's width fraction, from 0.1 through 0.9.
    public let masterRatio: Double

    /// Creates a configuration for later restoration.
    ///
    /// The controller validates values before applying them, including values
    /// decoded from a session file.
    ///
    /// - Parameters:
    ///   - layout: The pane arrangement policy.
    ///   - masterCount: The nonnegative desired master-pane count.
    ///   - masterRatio: A finite width fraction between 0.1 and 0.9 inclusive.
    public init(layout: PaneTilingLayout = .manual, masterCount: Int = 1, masterRatio: Double = 0.55) {
        self.layout = layout
        self.masterCount = masterCount
        self.masterRatio = masterRatio
    }
}
