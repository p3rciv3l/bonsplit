@testable import Bonsplit
import AppKit
import SwiftUI
import Testing

@Suite
@MainActor
struct LazyTabContextMenuTests {
    @Test
    func menuOpeningResolvesCurrentStateWithoutRenderingAgain() throws {
        let controller = BonsplitController()
        let paneId = try #require(controller.allPaneIds.first)
        let left = try #require(controller.createTab(title: "Left", kind: "terminal", inPane: paneId))
        let tabId = try #require(controller.createTab(title: "Target", kind: "terminal", inPane: paneId))
        let right = try #require(controller.createTab(title: "Right", kind: "terminal", inPane: paneId))
        var availabilityCalls = 0
        var defaultCalls = 0
        var moveCalls = 0
        var canFork = false
        var defaultAction = TabContextAction.forkConversationRight
        var destination = "first"
        controller.tabContextForkConversationAvailabilityProvider = { tab, pane in
            #expect(tab == tabId && pane == paneId)
            availabilityCalls += 1
            return canFork
        }
        controller.tabContextForkConversationDefaultActionProvider = { _, _ in
            defaultCalls += 1
            return defaultAction
        }
        controller.tabContextMoveDestinationsProvider = { _, _ in
            moveCalls += 1
            return [TabContextMoveDestination(id: destination, title: destination)]
        }
        let provider = TabBarView.contextMenuSnapshotProvider(for: tabId.id, in: paneId, controller: controller)
        var states: [TabContextMenuState] = []
        let presenter = TabContextMenuPresenter(snapshotProvider: {
            let snapshot = provider()
            if let snapshot { states.append(snapshot.state) }
            return snapshot
        }, onContextAction: { _ in }, onMoveDestination: { _ in })
        let coordinator = presenter.makeCoordinator()
        #expect(availabilityCalls == 0 && defaultCalls == 0 && moveCalls == 0)
        let firstMenu = try #require(coordinator.makeMenu())
        #expect(availabilityCalls == 1 && defaultCalls == 1 && moveCalls == 1)
        let first = try #require(states.last)
        #expect(first.canCloseToLeft && first.canCloseToRight && first.canCloseOthers)
        #expect(!first.isPinned && !first.isUnread && first.isTerminal && !first.hasSplits)
        #expect(Self.item(.forkConversation, in: firstMenu) == nil)

        // No SwiftUI host or body refresh occurs between constructing the provider and opening again.
        let neighbor = try #require(controller.splitPane(paneId, orientation: .horizontal, withTab: Tab(title: "Neighbor")))
        #expect(controller.reorderTab(tabId, toIndex: 0))
        controller.updateTab(tabId, kind: .some("browser"), hasCustomTitle: true, showsNotificationBadge: true, isAudioMuted: true, isPinned: true)
        controller.configuration.allowCloseTabs = false
        controller.selectTab(right)
        #expect(controller.togglePaneZoom(inPane: paneId))
        canFork = true
        defaultAction = .forkConversationLeft
        destination = "current"
        let selectedBefore = controller.selectedTab(inPane: paneId)?.id
        let focusedBefore = controller.focusedPaneId
        let currentMenu = try #require(coordinator.makeMenu())
        #expect(availabilityCalls == 2 && defaultCalls == 2 && moveCalls == 2)
        let current = try #require(states.last)
        #expect(current.isPinned && current.isUnread && current.isBrowser && current.isAudioMuted && current.hasCustomTitle)
        #expect(!current.canCloseToLeft && !current.canCloseToRight && !current.canCloseOthers)
        #expect(current.canMoveToRightPane && !current.canMoveToLeftPane && current.hasSplits && current.isZoomed)
        #expect(current.canForkConversation && current.forkConversationDefaultAction == .forkConversationLeft)
        #expect(Self.item(.forkConversationLeft, in: currentMenu)?.state == .on)
        #expect(Self.item(.markAsRead, in: currentMenu) != nil)
        #expect(Self.item(.markAsUnread, in: currentMenu) == nil)
        #expect(Self.items(in: currentMenu).contains { $0.representedObject as? String == "current" })
        #expect(!Self.items(in: currentMenu).contains { $0.representedObject as? String == "first" })
        #expect(controller.selectedTab(inPane: paneId)?.id == selectedBefore)
        #expect(controller.focusedPaneId == focusedBefore)

        controller.configuration.allowCloseTabs = true
        controller.updateTab(tabId, kind: .some("terminal"), isPinned: false)
        #expect(controller.reorderTab(tabId, toIndex: 0))
        #expect(controller.closePane(neighbor))
        let refreshed = try #require(provider())
        #expect(!refreshed.state.canCloseToLeft && refreshed.state.canCloseToRight)
        #expect(!refreshed.state.hasSplits && !refreshed.state.canMoveToRightPane)
        #expect(controller.tab(left) != nil)
    }

    @Test
    func staleOwnerClosedPaneAndReleasedControllerDoNotProduceMenus() throws {
        var controller: BonsplitController? = BonsplitController()
        weak var weakController = controller
        let source = try #require(controller?.allPaneIds.first)
        _ = try #require(controller?.createTab(title: "Keep source", inPane: source))
        let tab = try #require(controller?.createTab(title: "Moving", inPane: source))
        let destination = try #require(controller?.splitPane(source, orientation: .horizontal, withTab: Tab(title: "Destination")))
        let originalProvider = TabBarView.contextMenuSnapshotProvider(for: tab.id, in: source, controller: try #require(controller))
        let destinationProvider = TabBarView.contextMenuSnapshotProvider(for: tab.id, in: destination, controller: try #require(controller))
        #expect(originalProvider() != nil)
        #expect(controller?.moveTab(tab, toPane: destination) == true)
        #expect(originalProvider() == nil)
        #expect(destinationProvider() != nil)
        #expect(controller?.closeTab(tab) == true)
        #expect(destinationProvider() == nil)
        let remainingTab = try #require(controller?.tabs(inPane: destination).first)
        let removedPaneProvider = TabBarView.contextMenuSnapshotProvider(for: remainingTab.id.id, in: destination, controller: try #require(controller))
        #expect(controller?.closePane(destination) == true)
        #expect(removedPaneProvider() == nil)
        let coordinator = TabContextMenuPresenter.Coordinator(snapshotProvider: originalProvider)
        controller = nil
        #expect(weakController == nil)
        #expect(coordinator.makeMenu() == nil)
    }

    @Test
    func nativePresenterMountAndUpdateNeverEvaluateProvider() {
        _ = NSApplication.shared
        var oldCalls = 0
        var newCalls = 0
        let root = NSHostingView(rootView: TabContextMenuPresenter(snapshotProvider: {
            oldCalls += 1
            return nil
        }, onContextAction: { _ in }, onMoveDestination: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.orderOut(nil); window.contentView = nil }
        root.layoutSubtreeIfNeeded()
        root.rootView = TabContextMenuPresenter(snapshotProvider: {
            newCalls += 1
            return nil
        }, onContextAction: { _ in }, onMoveDestination: { _ in })
        root.layoutSubtreeIfNeeded()
        #expect(oldCalls == 0 && newCalls == 0)
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }

    private static func item(_ action: TabContextAction, in menu: NSMenu) -> NSMenuItem? {
        items(in: menu).first { $0.representedObject as? String == action.rawValue }
    }

    @Test(arguments: [8, 16])
    func renderingResizingTilingAndFocusingDoNotQueryMenuAvailability(paneCount: Int) throws {
        _ = NSApplication.shared
        var configuration = BonsplitConfiguration()
        configuration.appearance.enableAnimations = false
        let controller = BonsplitController(configuration: configuration)
        for index in 1..<paneCount {
            _ = try #require(controller.splitPane(orientation: .horizontal, withTab: Tab(title: "Pane \(index)", kind: "terminal")))
        }
        #expect(controller.performTilingAction(.tile))
        var availabilityCalls = 0
        controller.tabContextForkConversationAvailabilityProvider = { _, _ in
            availabilityCalls += 1
            return true
        }
        let root = NSHostingView(rootView: BonsplitView(controller: controller, contentRevision: 1) { _, _ in Color.clear })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.orderOut(nil); window.contentView = nil }
        root.layoutSubtreeIfNeeded()
        print("lazy-menu panes=\(paneCount) stage=initial availabilityCalls=\(availabilityCalls)")
        #expect(availabilityCalls == 0)

        availabilityCalls = 0
        window.setContentSize(NSSize(width: 1450, height: 1050))
        root.layoutSubtreeIfNeeded()
        print("lazy-menu panes=\(paneCount) stage=resize availabilityCalls=\(availabilityCalls)")
        #expect(availabilityCalls == 0)

        availabilityCalls = 0
        #expect(controller.performTilingAction(.increaseMasterRatio))
        root.layoutSubtreeIfNeeded()
        print("lazy-menu panes=\(paneCount) stage=ratio availabilityCalls=\(availabilityCalls)")
        #expect(availabilityCalls == 0)

        availabilityCalls = 0
        #expect(controller.performTilingAction(.focusNext))
        root.layoutSubtreeIfNeeded()
        print("lazy-menu panes=\(paneCount) stage=focus availabilityCalls=\(availabilityCalls)")
        #expect(availabilityCalls == 0)
    }
}
