import AppKit
import SwiftUI

/// Retains pane hosting views across split-tree restructuring for one mounted UI.
@MainActor
final class PaneHostingCoordinator {
    private struct Entry {
        let controller: NonDraggableHostingController<AnyView>
        var contentRevision: AnyHashable
        var showSplitButtons: Bool
        var tabBarVisibility: TabBarVisibility
        var contentViewLifecycle: ContentViewLifecycle
    }

    private struct Attachment {
        let id: UInt64
        weak var slot: PaneHostingSlotView?
    }

    private var entries: [PaneID: Entry] = [:]
    private var attachments: [ObjectIdentifier: Attachment] = [:]
    private var parkedHiddenStates: [ObjectIdentifier: Bool] = [:]
    private var nextAttachmentID: UInt64 = 0
    private weak var parkingView: NSView?

#if DEBUG
    // Instance-scoped, opt-in counters keep regression checks out of normal rendering.
    var debugTracksOperations = false
    private(set) var debugOperationCounts = (
        hostRequests: 0, contentAssignments: 0, attachments: 0, installedFrames: 0
    )
#endif

    func registerParkingView(_ view: NSView) {
        parkingView = view
    }

    func host(
        for paneId: PaneID,
        contentRevision: AnyHashable,
        showSplitButtons: Bool = true,
        tabBarVisibility: TabBarVisibility = .always,
        contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch,
        content: () -> AnyView
    ) -> NonDraggableHostingController<AnyView> {
#if DEBUG
        if debugTracksOperations { debugOperationCounts.hostRequests += 1 }
#endif
        if var entry = entries[paneId] {
            if entry.contentRevision != contentRevision ||
                entry.showSplitButtons != showSplitButtons ||
                entry.tabBarVisibility != tabBarVisibility ||
                entry.contentViewLifecycle != contentViewLifecycle {
#if DEBUG
                if debugTracksOperations { debugOperationCounts.contentAssignments += 1 }
#endif
                entry.controller.rootView = content()
                entry.contentRevision = contentRevision
                entry.showSplitButtons = showSplitButtons
                entry.tabBarVisibility = tabBarVisibility
                entry.contentViewLifecycle = contentViewLifecycle
                entries[paneId] = entry
            }
            return entry.controller
        }

#if DEBUG
        if debugTracksOperations { debugOperationCounts.contentAssignments += 1 }
#endif
        let controller = NonDraggableHostingController(rootView: content())
        controller.sizingOptions = []
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        let relaxed = NSLayoutConstraint.Priority(1)
        view.setContentHuggingPriority(relaxed, for: .horizontal)
        view.setContentCompressionResistancePriority(relaxed, for: .horizontal)
        view.setContentHuggingPriority(relaxed, for: .vertical)
        view.setContentCompressionResistancePriority(relaxed, for: .vertical)
        entries[paneId] = Entry(
            controller: controller,
            contentRevision: contentRevision,
            showSplitButtons: showSplitButtons,
            tabBarVisibility: tabBarVisibility,
            contentViewLifecycle: contentViewLifecycle
        )
        return controller
    }

    func attach(_ host: NonDraggableHostingController<AnyView>, to container: NSView) {
#if DEBUG
        if debugTracksOperations { debugOperationCounts.attachments += 1 }
#endif
        let view = host.view
        // Only leaf hosts belong to this cache. Branch hosts are owned by their
        // current split slot and must follow that slot's normal teardown.
        guard entries.values.contains(where: { $0.controller === host }) else {
            install(view, in: container, retainingPane: false)
            return
        }
        let viewID = ObjectIdentifier(view)
        attachments[viewID]?.slot?.cancelAttachment(of: view)
        nextAttachmentID &+= 1
        let requestID = nextAttachmentID
        attachments[viewID] = Attachment(id: requestID, slot: nil)

        if let slot = container as? PaneHostingSlotView,
           container.window == nil,
           let window = view.window,
           let parkingView,
           parkingView.window === window {
            parkBeforeSlotRemoval(view)
            attachments[viewID] = Attachment(id: requestID, slot: slot)
            slot.deferAttachment(of: view, requestID: requestID, owner: self)
            return
        }

        install(view, in: container, retainingPane: true)
    }

    func completeAttachment(of view: NSView, requestID: UInt64, to slot: PaneHostingSlotView) {
        let viewID = ObjectIdentifier(view)
        guard let current = attachments[viewID],
              current.id == requestID,
              current.slot === slot else { return }
        attachments[viewID] = Attachment(id: requestID, slot: nil)
        install(view, in: slot, retainingPane: true)
    }

    func parkBeforeSlotRemoval(_ view: NSView) {
        guard entries.values.contains(where: { $0.controller.view === view }),
              let parkingView,
              let window = view.window,
              parkingView.window === window,
              view.superview !== parkingView else { return }
        let preservedFrame = parkingView.convert(view.bounds, from: view)
        // Moving out of an off-path monocle ancestor must not reveal its pane
        // during handoff. Restore only the host's own state after reattachment;
        // the new ancestry then decides whether the pane is actually visible.
        parkedHiddenStates[ObjectIdentifier(view)] = view.isHidden
        let wasEffectivelyHidden = view.isHiddenOrHasHiddenAncestor
        view.isHidden = wasEffectivelyHidden
        parkingView.addSubview(view)
        view.frame = preservedFrame
    }

    func parkHostedPanes(in subtree: NSView) {
        for entry in entries.values {
            let view = entry.controller.view
            if view.isDescendant(of: subtree) {
                parkBeforeSlotRemoval(view)
            }
        }
    }

    private func install(_ view: NSView, in container: NSView, retainingPane: Bool) {
        (container as? PaneHostingSlotView)?.prepareToInstall(view, owner: retainingPane ? self : nil)
        if view.superview !== container {
            // Move the incoming view before discarding the old subtree. It may
            // currently live inside that subtree and must survive its teardown.
            container.addSubview(view)
        }
        for obsolete in container.subviews where obsolete !== view {
            obsolete.removeFromSuperview()
        }
#if DEBUG
        if debugTracksOperations { debugOperationCounts.installedFrames += 1 }
#endif
        view.frame = container.bounds
        if let wasHidden = parkedHiddenStates.removeValue(forKey: ObjectIdentifier(view)) {
            view.isHidden = wasHidden
        }
    }

    func retainPanes(_ paneIds: [PaneID]) {
        let live = Set(paneIds)
        for (paneId, entry) in entries where !live.contains(paneId) {
            let view = entry.controller.view
            attachments.removeValue(forKey: ObjectIdentifier(view))?.slot?.cancelAttachment(of: view)
            parkedHiddenStates.removeValue(forKey: ObjectIdentifier(view))
            if view.superview === parkingView { view.removeFromSuperview() }
        }
        entries = entries.filter { live.contains($0.key) }
    }
}
