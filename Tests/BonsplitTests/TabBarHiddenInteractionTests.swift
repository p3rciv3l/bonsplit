@testable import Bonsplit
import AppKit
import Testing

@Suite(.serialized)
@MainActor
struct TabBarHiddenInteractionTests {
    @Test(arguments: [false, true])
    func hiddenOverlappingBarDoesNotReorderOrFocus(hideAncestor: Bool) throws {
        let fixture = try ManualFixture()
        defer { fixture.dispose() }
        let original = fixture.pane.tabs.map(\.id)
        let visibleOriginal = fixture.visiblePane.tabs.map(\.id)
        (hideAncestor ? fixture.native.parent : fixture.view).isHidden = true
        #expect(fixture.view.isHiddenOrHasHiddenAncestor)

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = try Self.event(type, view: fixture.view, x: type == .leftMouseDown ? 50 : 285)
            // These are the same handlers each local monitor invokes, in hidden-then-visible order.
            fixture.view.handle(event)
            #expect(fixture.pane.tabs.map(\.id) == original)
            #expect(fixture.controller.focusedPaneId == fixture.visiblePane.id)
            #expect(fixture.controller.internalController.dragSourcePaneId != fixture.pane.id)
            #expect(fixture.controller.internalController.activeDragSourcePaneId != fixture.pane.id)
            fixture.visibleView.handle(event)
        }

        #expect(fixture.visiblePane.tabs.map(\.id) == Array(visibleOriginal.dropFirst()) + [visibleOriginal[0]])
        #expect(fixture.controller.internalController.draggingTab == nil)
        #expect(fixture.controller.internalController.activeDragTab == nil)
    }

    @Test
    func visibleManualDragReordersAndFocusesItsPane() throws {
        let fixture = try ManualFixture()
        defer { fixture.dispose() }
        let original = fixture.pane.tabs.map(\.id)
        var targets: [Int?] = []
        fixture.view.onDropStateChanged = { target, _ in targets.append(target) }
        fixture.view.handle(try Self.event(.leftMouseDown, view: fixture.view, x: 50))
        fixture.view.handle(try Self.event(.leftMouseDragged, view: fixture.view, x: 285))
        #expect(fixture.controller.internalController.draggingTab?.id == original[0])
        #expect(fixture.controller.internalController.activeDragSourcePaneId == fixture.pane.id)
        #expect(targets.last == 3)
        fixture.view.handle(try Self.event(.leftMouseUp, view: fixture.view, x: 285))
        #expect(fixture.pane.tabs.map(\.id) == Array(original.dropFirst()) + [original[0]])
        #expect(fixture.controller.focusedPaneId == fixture.pane.id)
        #expect(fixture.controller.internalController.draggingTab == nil)
        #expect(fixture.controller.internalController.activeDragTab == nil)
        #expect(targets.count == 2)
        #expect(targets[1] == nil)
    }

    @Test(arguments: [false, true])
    func hidingDuringManualDragCancelsOwnedStateAndDoesNotResume(hideAncestor: Bool) throws {
        let fixture = try ManualFixture()
        defer { fixture.dispose() }
        let original = fixture.pane.tabs.map(\.id)
        var target: Int?
        var lifecycle = TabDropLifecycle.idle
        fixture.view.onDropStateChanged = { target = $0; lifecycle = $1 }
        fixture.view.handle(try Self.event(.leftMouseDown, view: fixture.view, x: 50))
        fixture.view.handle(try Self.event(.leftMouseDragged, view: fixture.view, x: 285))
        #expect(target == 3 && lifecycle == .hovering)
        #expect(fixture.controller.internalController.activeDragTab?.id == original[0])

        let hiddenView = hideAncestor ? fixture.native.parent : fixture.view
        hiddenView.isHidden = true
        #expect(fixture.view.isHiddenOrHasHiddenAncestor)
        #expect(fixture.controller.internalController.draggingTab == nil)
        #expect(fixture.controller.internalController.activeDragTab == nil)
        #expect(fixture.controller.internalController.dragSourcePaneId == nil)
        #expect(fixture.controller.internalController.activeDragSourcePaneId == nil)
        #expect(target == nil && lifecycle == .idle)
        fixture.view.handle(try Self.event(.leftMouseDragged, view: fixture.view, x: 285))
        hiddenView.isHidden = false
        fixture.view.handle(try Self.event(.leftMouseUp, view: fixture.view, x: 285))
        #expect(fixture.pane.tabs.map(\.id) == original)
        #expect(fixture.controller.focusedPaneId == fixture.visiblePane.id)
    }

    @Test
    func hiddenDragCancellationPreservesAnotherPanesDragOwnership() throws {
        let fixture = try ManualFixture()
        defer { fixture.dispose() }
        let original = fixture.pane.tabs.map(\.id)
        fixture.view.handle(try Self.event(.leftMouseDown, view: fixture.view, x: 50))
        fixture.view.handle(try Self.event(.leftMouseDragged, view: fixture.view, x: 285))
        let otherTab = try #require(fixture.visiblePane.tabs.first)
        let state = fixture.controller.internalController
        state.draggingTab = otherTab
        state.activeDragTab = otherTab
        state.dragSourcePaneId = fixture.visiblePane.id
        state.activeDragSourcePaneId = fixture.visiblePane.id

        fixture.native.parent.isHidden = true
        fixture.view.handle(try Self.event(.leftMouseUp, view: fixture.view, x: 285))
        #expect(state.draggingTab?.id == otherTab.id)
        #expect(state.activeDragTab?.id == otherTab.id)
        #expect(state.dragSourcePaneId == fixture.visiblePane.id)
        #expect(state.activeDragSourcePaneId == fixture.visiblePane.id)
        #expect(fixture.pane.tabs.map(\.id) == original)
        #expect(fixture.controller.focusedPaneId == fixture.visiblePane.id)
    }

    @Test(arguments: [false, true], [false, true])
    func hiddenHoverClearsOnceAndVisibleHoverCanResume(background: Bool, hideAncestor: Bool) throws {
        let view: NSView = background
            ? TabBarDragAndHoverView.TabBarBackgroundNSView()
            : TabBarHoverTrackingView.HoverNSView()
        let fixture = NativeFixture(view: view)
        defer { fixture.dispose() }
        var changes: [Bool] = []
        if let hover = view as? TabBarHoverTrackingView.HoverNSView {
            hover.onHoverChanged = { changes.append($0) }
        } else if let hover = view as? TabBarDragAndHoverView.TabBarBackgroundNSView {
            hover.onHoverChanged = { changes.append($0) }
        }
        view.mouseMoved(with: try Self.event(.mouseMoved, view: view, x: 500))
        changes.removeAll()
        let inside = try Self.event(.mouseMoved, view: view, x: 50)
        view.mouseMoved(with: inside)
        #expect(changes == [true])
        let hiddenView = hideAncestor ? fixture.parent : view
        hiddenView.isHidden = true
        #expect(changes == [true, false])
        view.mouseMoved(with: inside)
        view.mouseMoved(with: inside)
        view.mouseEntered(with: inside)
        #expect(changes == [true, false])
        hiddenView.isHidden = false
        view.mouseMoved(with: inside)
        #expect(changes == [true, false, true])
    }

    private static func event(_ type: NSEvent.EventType, view: NSView, x: CGFloat) throws -> NSEvent {
        let window = try #require(view.window)
        return try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(NSPoint(x: x, y: 15), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @MainActor
    private final class NativeFixture {
        let window: NSWindow
        let parent: NSView

        init(view: NSView) {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: 400, height: 120)
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: frame)
            parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
            window.contentView?.addSubview(parent)
            view.frame = parent.bounds
            parent.addSubview(view)
        }

        func dispose() {
            window.contentView = nil
            window.orderOut(nil)
        }
    }

    @MainActor
    private final class ManualFixture {
        let controller = BonsplitController()
        let view = TabBarManualReorderTrackingView.ManualReorderNSView()
        let visibleView = TabBarManualReorderTrackingView.ManualReorderNSView()
        let native: NativeFixture
        let pane: PaneState
        let visiblePane: PaneState

        init() throws {
            native = NativeFixture(view: view)
            let paneID = try #require(controller.focusedPaneId)
            for index in 1...2 {
                _ = try #require(controller.createTab(title: "Source \(index)", inPane: paneID))
            }
            let visiblePaneID = try #require(controller.splitPane(paneID, orientation: .vertical, withTab: Tab(title: "Visible")))
            for index in 1...2 {
                _ = try #require(controller.createTab(title: "Visible \(index)", inPane: visiblePaneID))
            }
            pane = try #require(controller.internalController.rootNode.findPane(paneID))
            visiblePane = try #require(controller.internalController.rootNode.findPane(visiblePaneID))
            visibleView.frame = native.parent.frame
            native.window.contentView?.addSubview(visibleView)
            for (nativeView, model) in [(view, pane), (visibleView, visiblePane)] {
                nativeView.pane = model
                nativeView.bonsplitController = controller
                nativeView.splitViewController = controller.internalController
                nativeView.tabFrames = Dictionary(uniqueKeysWithValues: model.tabs.enumerated().map {
                    ($0.element.id, NSRect(x: CGFloat($0.offset) * 100, y: 0, width: 100, height: 30))
                })
            }
            controller.focusPane(visiblePaneID)
        }

        func dispose() {
            native.dispose()
        }
    }
}
