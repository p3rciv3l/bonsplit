import AppKit

/// A pane slot that claims a parked host once it belongs to a native window.
class PaneHostingSlotView: NSView {
    private weak var installedOwner: PaneHostingCoordinator?
    private weak var installedHostedView: NSView?
    private weak var attachmentOwner: PaneHostingCoordinator?
    private var pendingHostedView: NSView?
    private var pendingAttachmentID: UInt64?

    func prepareToInstall(_ view: NSView, owner: PaneHostingCoordinator?) {
        if let previous = installedHostedView,
           previous !== view,
           previous.superview === self {
            installedOwner?.parkBeforeSlotRemoval(previous)
        }
        installedHostedView = owner == nil ? nil : view
        installedOwner = owner
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil,
           let view = installedHostedView,
           view.superview === self {
            installedOwner?.parkBeforeSlotRemoval(view)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        // AppKit can clear the old parent before the window callback. Park
        // while coordinate conversion still includes that parent's origin.
        if newSuperview == nil,
           let view = installedHostedView,
           view.superview === self {
            installedOwner?.parkBeforeSlotRemoval(view)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    func deferAttachment(of view: NSView, requestID: UInt64, owner: PaneHostingCoordinator) {
        attachmentOwner = owner
        pendingHostedView = view
        pendingAttachmentID = requestID
    }

    func cancelAttachment(of view: NSView) {
        guard pendingHostedView === view else { return }
        pendingHostedView = nil
        pendingAttachmentID = nil
        attachmentOwner = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil,
              let view = pendingHostedView,
              let requestID = pendingAttachmentID,
              let owner = attachmentOwner else { return }
        pendingHostedView = nil
        pendingAttachmentID = nil
        attachmentOwner = nil
        owner.completeAttachment(of: view, requestID: requestID, to: self)
    }
}
