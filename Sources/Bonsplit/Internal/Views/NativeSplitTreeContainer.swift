import AppKit

/// Stable native owner for the tree and transient, same-window node handoffs.
final class NativeSplitTreeContainer: NSView {
    let parkingView = NativeSplitParkingView()
    private(set) var treeView: NSView?
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        parkingView.isHidden = true
        parkingView.autoresizingMask = [.width, .height]
        addSubview(parkingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    func park(_ view: NSView) {
        guard view.superview !== parkingView else { return }
        let frame = parkingView.convert(view.bounds, from: view)
        parkingView.addSubview(view)
        view.frame = frame
    }

    func installTree(_ view: NSView) {
        treeView = view
        if view.superview !== self { addSubview(view, positioned: .below, relativeTo: parkingView) }
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
    }

    override func layout() {
        super.layout()
        parkingView.frame = bounds
        onLayout?()
    }
}

final class NativeSplitParkingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
