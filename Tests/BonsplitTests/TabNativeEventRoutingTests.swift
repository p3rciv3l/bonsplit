@testable import Bonsplit
import AppKit
import Testing

@Suite
@MainActor
struct TabNativeEventRoutingTests {
    @Test(arguments: [false, true])
    func hiddenSelfOrAncestorDoesNotConsumeNativeTabEvents(hideAncestor: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let parent = NSView(frame: NSRect(x: 20, y: 20, width: 250, height: 100))
        let view = NSView(frame: NSRect(x: 10, y: 10, width: 100, height: 30))
        window.contentView = root
        root.addSubview(parent)
        parent.addSubview(view)
        defer { window.orderOut(nil); window.contentView = nil }

        let controller = BonsplitController()
        let pane = try #require(controller.allPaneIds.first)
        let tab = try #require(controller.createTab(title: "Menu", inPane: pane))
        let provider = TabBarView.contextMenuSnapshotProvider(for: tab.id, in: pane, controller: controller)
        var snapshots = 0
        var presentations = 0
        var closes = 0
        let menu = TabContextMenuPresenter.Coordinator(snapshotProvider: {
            snapshots += 1
            return provider()
        })
        menu.view = view
        let middle = MiddleClickMonitorView.Coordinator()
        middle.view = view
        middle.onMiddleClick = { closes += 1 }
        let right = try Self.event(.rightMouseDown, view: view)
        let controlLeft = try Self.event(.leftMouseDown, view: view, modifiers: .control)
        let middleUp = try Self.event(.otherMouseUp, view: view)
        #expect(middleUp.buttonNumber == 2)
        #expect(menu.handleEvent(right) { _, _, _ in presentations += 1 } == nil)
        #expect(menu.handleEvent(controlLeft) { _, _, _ in presentations += 1 } == nil)
        #expect(middle.handleEvent(middleUp) == nil)
        #expect(snapshots == 2 && presentations == 2 && closes == 1)

        (hideAncestor ? parent : view).isHidden = true
        #expect(view.isHiddenOrHasHiddenAncestor)
        #expect(menu.handleEvent(right) { _, _, _ in presentations += 1 } === right)
        #expect(menu.handleEvent(controlLeft) { _, _, _ in presentations += 1 } === controlLeft)
        #expect(middle.handleEvent(middleUp) === middleUp)
        #expect(snapshots == 2 && presentations == 2 && closes == 1)

        (hideAncestor ? parent : view).isHidden = false
        #expect(menu.handleEvent(right) { _, _, _ in presentations += 1 } == nil)
        #expect(middle.handleEvent(middleUp) == nil)
        #expect(snapshots == 3 && presentations == 3 && closes == 2)
    }

    @Test
    func wrongWindowBoundsButtonAndMissingTabPassThroughWithoutProviderWork() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let otherView = NSView(frame: view.frame)
        window.contentView = view
        otherWindow.contentView = otherView
        defer { window.contentView = nil; otherWindow.contentView = nil }
        var snapshots = 0
        var presentations = 0
        var closes = 0
        let menu = TabContextMenuPresenter.Coordinator(snapshotProvider: { snapshots += 1; return nil })
        menu.view = view
        let middle = MiddleClickMonitorView.Coordinator()
        middle.view = view
        middle.onMiddleClick = { closes += 1 }
        for event in [
            try Self.event(.rightMouseDown, view: otherView),
            try Self.event(.rightMouseDown, view: view, point: NSPoint(x: 250, y: 150)),
            try Self.event(.leftMouseDown, view: view),
            try Self.event(.rightMouseUp, view: view)
        ] {
            #expect(menu.handleEvent(event) { _, _, _ in presentations += 1 } === event)
            #expect(middle.handleEvent(event) === event)
        }
        for event in [
            try Self.event(.otherMouseUp, view: otherView),
            try Self.event(.otherMouseUp, view: view, point: NSPoint(x: 250, y: 150)),
            try Self.event(.otherMouseDown, view: view)
        ] {
            #expect(middle.handleEvent(event) === event)
        }
        #expect(snapshots == 0 && presentations == 0 && closes == 0)
        let validEvent = try Self.event(.rightMouseDown, view: view)
        #expect(menu.handleEvent(validEvent) { _, _, _ in presentations += 1 } === validEvent)
        #expect(snapshots == 1 && presentations == 0)
    }

    private static func event(_ type: NSEvent.EventType, view: NSView, point: NSPoint = NSPoint(x: 5, y: 5), modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try #require(view.window)
        let windowPoint = view.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        guard type == .otherMouseUp || type == .otherMouseDown else { return event }
        // AppKit's mouseEvent factory defaults other-button events to button zero.
        // A CGEvent copy sets the real button while retaining the native window association.
        let cgEvent = try #require(event.cgEvent)
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let converted = try #require(NSEvent(cgEvent: cgEvent))
        // Account for AppKit's screen/window coordinate conversion on the current OS.
        cgEvent.location = CGPoint(
            x: cgEvent.location.x + windowPoint.x - converted.locationInWindow.x,
            y: cgEvent.location.y - windowPoint.y + converted.locationInWindow.y
        )
        let middleEvent = try #require(NSEvent(cgEvent: cgEvent))
        #expect(middleEvent.window === window && middleEvent.buttonNumber == 2)
        #expect(middleEvent.locationInWindow == windowPoint)
        return middleEvent
    }
}
