@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct PaneContentContextTests {
    @Test(arguments: [ContentViewLifecycle.keepAllAlive, .recreateOnSwitch])
    func renderedContextFollowsSelectionFocusAndMoves(lifecycle: ContentViewLifecycle) throws {
        let fixture = try Fixture(paneCount: 2, lifecycle: lifecycle)
        defer { fixture.close() }
        let panes = fixture.controller.allPaneIds
        let original = try #require(fixture.controller.selectedTab(inPane: panes[0]))
        let other = try #require(fixture.controller.selectedTab(inPane: panes[1]))
        let secondary = try #require(fixture.controller.createTab(title: "Secondary", inPane: panes[0]))
        fixture.controller.selectTab(original.id)
        fixture.refresh()

        #expect(try fixture.anchor(original.id, in: panes[0]).snapshot == Snapshot(selected: true, focused: true))
        #expect(try fixture.anchor(other.id, in: panes[1]).snapshot == Snapshot(selected: true, focused: false))
        if lifecycle == .keepAllAlive {
            #expect(try fixture.anchor(secondary, in: panes[0]).snapshot == Snapshot(selected: false, focused: false))
        } else {
            #expect(fixture.findAnchor(secondary, in: panes[0]) == nil)
        }

        fixture.controller.focusPane(panes[1])
        fixture.refresh()
        #expect(try fixture.anchor(original.id, in: panes[0]).snapshot == Snapshot(selected: true, focused: false))
        #expect(try fixture.anchor(other.id, in: panes[1]).snapshot == Snapshot(selected: true, focused: true))

        fixture.controller.selectTab(secondary)
        fixture.refresh()
        #expect(try fixture.anchor(secondary, in: panes[0]).snapshot == Snapshot(selected: true, focused: true))
        if lifecycle == .keepAllAlive {
            #expect(try fixture.anchor(original.id, in: panes[0]).snapshot == Snapshot(selected: false, focused: false))
        }

        #expect(fixture.controller.moveTab(secondary, toPane: panes[1]))
        fixture.refresh()
        #expect(fixture.findAnchor(secondary, in: panes[0]) == nil)
        #expect(try fixture.anchor(secondary, in: panes[1]).snapshot == Snapshot(selected: true, focused: true))
        #expect(try fixture.anchor(original.id, in: panes[0]).snapshot == Snapshot(selected: true, focused: false))
        if lifecycle == .keepAllAlive {
            #expect(try fixture.anchor(other.id, in: panes[1]).snapshot == Snapshot(selected: false, focused: false))
        }
    }

    @Test(arguments: [ContentViewLifecycle.keepAllAlive, .recreateOnSwitch])
    func missingAndInvalidSelectionDoNotMarkRenderedFallbackFocused(lifecycle: ContentViewLifecycle) throws {
        let fixture = try Fixture(paneCount: 1, lifecycle: lifecycle)
        defer { fixture.close() }
        let paneID = try #require(fixture.controller.focusedPaneId)
        let pane = try #require(fixture.controller.internalController.rootNode.findPane(paneID))
        let original = try #require(fixture.controller.selectedTab(inPane: paneID))
        let secondary = try #require(fixture.controller.createTab(title: "Secondary", inPane: paneID))

        for missingSelection in [nil, UUID()] as [UUID?] {
            pane.selectedTabId = missingSelection
            fixture.refresh()
            #expect(fixture.controller.selectedTab(inPane: paneID) == nil)
            #expect(try fixture.anchor(original.id, in: paneID).snapshot == Snapshot(selected: false, focused: false))
            if lifecycle == .keepAllAlive {
                #expect(try fixture.anchor(secondary, in: paneID).snapshot == Snapshot(selected: false, focused: false))
            }
        }

        fixture.controller.selectTab(secondary)
        fixture.refresh()
        #expect(try fixture.anchor(secondary, in: paneID).snapshot == Snapshot(selected: true, focused: true))
    }

    @Test
    func focusingAnotherPaneDoesNotRebuildUnrelatedContentWithStableRevision() throws {
        let fixture = try Fixture(paneCount: 8, lifecycle: .keepAllAlive)
        defer { fixture.close() }
        let panes = fixture.controller.allPaneIds
        fixture.controller.focusPane(panes[0])
        fixture.refresh()
        let before = fixture.recorder.builds

        fixture.controller.focusPane(panes[1])
        fixture.refresh()

        for pane in panes {
            let selected = try #require(fixture.controller.selectedTab(inPane: pane))
            #expect(try fixture.anchor(selected.id, in: pane).snapshot == Snapshot(selected: true, focused: pane == panes[1]))
            if pane == panes[0] || pane == panes[1] {
                #expect(fixture.recorder.builds[pane, default: 0] > before[pane, default: 0])
            } else {
                #expect(fixture.recorder.builds[pane, default: 0] == before[pane, default: 0])
            }
        }
    }

    @Test
    func legacyAndContextInitializersRenderWithExplicitAndShorthandArguments() throws {
        _ = NSApplication.shared
        let controller = BonsplitController()
        let pane = try #require(controller.focusedPaneId)
        let tab = try #require(controller.selectedTab(inPane: pane))
        let legacySnapshot = TabContentContext(isSelected: false, isPaneFocused: false)
        let builder: (Bonsplit.Tab, PaneID) -> ContextProbe = { tab, pane in
            ContextProbe(tab: tab.id, pane: pane, context: legacySnapshot)
        }
        let views = [
            AnyView(BonsplitView(controller: controller, content: builder)),
            AnyView(BonsplitView(controller: controller) {
                ContextProbe(tab: $0.id, pane: $1, context: legacySnapshot)
            }),
            AnyView(BonsplitView(controller: controller, content: builder, emptyPane: { _ in EmptyView() })),
            AnyView(BonsplitView(controller: controller) { tab, pane, context in
                ContextProbe(tab: tab.id, pane: pane, context: context)
            }),
            AnyView(BonsplitView(controller: controller) {
                ContextProbe(tab: $0.id, pane: $1, context: $2)
            } emptyPane: { _ in EmptyView() })
        ]

        for (index, view) in views.enumerated() {
            let hosting = NSHostingView(rootView: view)
            let window = Fixture.window(hosting: hosting)
            defer { window.orderOut(nil); window.contentView = nil }
            hosting.layoutSubtreeIfNeeded()
            let anchor = try #require(Fixture.findAnchor(tab.id, pane: pane, in: hosting))
            #expect(anchor.snapshot == Snapshot(selected: index >= 3, focused: index >= 3))
        }
    }

    private struct Snapshot: Equatable {
        let selected: Bool
        let focused: Bool
    }

    @MainActor
    private final class BuildRecorder {
        var builds: [PaneID: Int] = [:]

        func record(_ pane: PaneID) {
            builds[pane, default: 0] += 1
        }
    }

    @MainActor
    private final class ContextAnchor: NSView {
        var tab: TabID?
        var pane: PaneID?
        var snapshot = Snapshot(selected: false, focused: false)
    }

    private struct ContextProbe: NSViewRepresentable {
        let tab: TabID
        let pane: PaneID
        let context: TabContentContext

        func makeNSView(context: Context) -> ContextAnchor {
            let view = ContextAnchor()
            updateNSView(view, context: context)
            return view
        }

        func updateNSView(_ view: ContextAnchor, context: Context) {
            view.tab = tab
            view.pane = pane
            view.snapshot = Snapshot(selected: self.context.isSelected, focused: self.context.isFocused)
        }
    }

    @MainActor
    private final class Fixture {
        let controller: BonsplitController
        let recorder = BuildRecorder()
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window: NSWindow

        init(paneCount: Int, lifecycle: ContentViewLifecycle) throws {
            _ = NSApplication.shared
            var configuration = BonsplitConfiguration(contentViewLifecycle: lifecycle)
            configuration.appearance.enableAnimations = false
            controller = BonsplitController(configuration: configuration)
            for index in 1..<paneCount {
                _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)")))
            }
            window = Self.window(hosting: hosting)
            refresh()
        }

        func refresh() {
            let recorder = recorder
            hosting.rootView = AnyView(BonsplitView(controller: controller, contentRevision: "context-fixture") { tab, pane, context in
                // Nonobservable instrumentation records executed content builders.
                let _ = recorder.record(pane)
                ContextProbe(tab: tab.id, pane: pane, context: context)
            } emptyPane: { _ in EmptyView() })
            hosting.layoutSubtreeIfNeeded()
        }

        func anchor(_ tab: TabID, in pane: PaneID) throws -> ContextAnchor {
            try #require(findAnchor(tab, in: pane))
        }

        func findAnchor(_ tab: TabID, in pane: PaneID) -> ContextAnchor? {
            Self.findAnchor(tab, pane: pane, in: hosting)
        }

        static func findAnchor(_ tab: TabID, pane: PaneID, in view: NSView) -> ContextAnchor? {
            if let anchor = view as? ContextAnchor, anchor.tab == tab, anchor.pane == pane {
                return anchor
            }
            for child in view.subviews {
                if let anchor = findAnchor(tab, pane: pane, in: child) { return anchor }
            }
            return nil
        }

        static func window(hosting: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            return window
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
