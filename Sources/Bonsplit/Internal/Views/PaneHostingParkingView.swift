import AppKit
import SwiftUI

/// Keeps moving pane hosts in their window while SwiftUI replaces split ancestors.
struct PaneHostingParkingView: NSViewRepresentable {
    let paneHosting: PaneHostingCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = ParkingContainerView()
        paneHosting.registerParkingView(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        paneHosting.registerParkingView(nsView)
    }

    private final class ParkingContainerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
