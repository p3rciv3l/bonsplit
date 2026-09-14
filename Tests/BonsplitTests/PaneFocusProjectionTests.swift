@testable import Bonsplit
import Foundation
import Observation
import Testing

@Suite(.serialized)
@MainActor
struct PaneFocusProjectionTests {
    @Test
    func focusChangeInvalidatesOnlyTheOldAndNewPanes() throws {
        let controller = try makeController(paneCount: 16)
        let panes = controller.internalController.rootNode.allPanes
        let old = try #require(panes.first)
        let next = panes[1]
        controller.focusPane(old.id)
        let changes = observeFocus(in: panes)

        controller.focusPane(next.id)

        #expect(changes.paneIDs.count == 2)
        #expect(Set(changes.paneIDs) == Set([old.id, next.id]))
        expectProjection(in: controller.internalController)
    }

    @Test
    func repeatedAndInvalidFocusDoNotInvalidatePaneFocus() throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.internalController.rootNode.allPanes
        let focused = try #require(controller.focusedPaneId)
        let changes = observeFocus(in: panes)

        controller.focusPane(focused)
        controller.focusPane(PaneID())

        #expect(changes.paneIDs.isEmpty)
        #expect(controller.focusedPaneId == focused)
        expectProjection(in: controller.internalController)
    }

    @Test
    func nestedFocusChangeConvergesBeforeTheOuterMutationReturns() throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.internalController.rootNode.allPanes
        let old = panes[0]
        let intermediate = panes[1]
        let finalID = panes[2].id
        controller.focusPane(old.id)
        withObservationTracking {
            _ = old.isFocused
        } onChange: {
            MainActor.assumeIsolated { controller.focusPane(finalID) }
        }

        controller.focusPane(intermediate.id)

        #expect(controller.focusedPaneId == finalID)
        #expect(!old.isFocused)
        #expect(!intermediate.isFocused)
        expectProjection(in: controller.internalController)
    }

    @Test
    func samePaneTabSelectionDoesNotInvalidatePaneFocus() throws {
        let controller = try makeController(paneCount: 4)
        let focused = try #require(controller.focusedPaneId)
        let alternate = try #require(controller.createTab(title: "Alternate", inPane: focused))
        let original = try #require(controller.tabs(inPane: focused).first)
        controller.selectTab(original.id)
        let changes = observeFocus(in: controller.internalController.rootNode.allPanes)

        controller.selectTab(alternate)
        controller.reorderTab(alternate, toIndex: 0)

        #expect(changes.paneIDs.isEmpty)
        #expect(controller.selectedTab(inPane: focused)?.id == alternate)
        expectProjection(in: controller.internalController)
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func splittingResolvesFocusAssignedBeforeTheNewPaneEntersTheTree(insertFirst: Bool?) throws {
        let controller = try makeController(paneCount: 4)
        let internalController = controller.internalController
        let old = try #require(internalController.focusedPane)
        let inserted: PaneID?
        if let insertFirst {
            inserted = controller.splitPane(old.id, orientation: .horizontal, withTab: Tab(title: "Inserted"), insertFirst: insertFirst)
        } else {
            inserted = controller.splitPane(old.id, orientation: .vertical, withTab: Tab(title: "Inserted"))
        }

        let insertedID = try #require(inserted)
        #expect(controller.focusedPaneId == insertedID)
        #expect(try #require(internalController.rootNode.findPane(insertedID)).isFocused)
        #expect(!old.isFocused)
        expectProjection(in: internalController)
    }

    @Test
    func closeAndMoveClearDetachedPanesAndPreserveAuthoritativeFocus() throws {
        let controller = try makeController(paneCount: 4)
        let internalController = controller.internalController
        let closed = try #require(internalController.focusedPane)
        #expect(controller.closePane(closed.id))
        #expect(!closed.isFocused)
        expectProjection(in: internalController)

        let source = try #require(internalController.rootNode.allPanes.first)
        let destination = try #require(internalController.rootNode.allPanes.last)
        let moved = try #require(controller.tabs(inPane: source.id).first)
        #expect(controller.moveTab(moved.id, toPane: destination.id))
        #expect(internalController.rootNode.findPane(source.id) == nil)
        #expect(!source.isFocused)
        expectProjection(in: internalController)

        while controller.allPaneIds.count > 1 {
            #expect(controller.closePane(try #require(controller.allPaneIds.last)))
            expectProjection(in: internalController)
        }
        let finalPane = try #require(internalController.rootNode.allPanes.first)
        #expect(!controller.closePane(finalPane.id))
        #expect(finalPane.isFocused)
    }

    @Test
    func pendingAndSameIDReplacementFocusUseLiveObjectIdentity() throws {
        let first = PaneState(tabs: [TabItem(title: "First")])
        let controller = SplitViewController(rootNode: .pane(first))
        #expect(!first.isFocused)
        let pending = PaneState(tabs: [TabItem(title: "Pending")])
        controller.focusedPaneId = pending.id
        #expect(!first.isFocused)
        controller.rootNode = .pane(pending)
        #expect(pending.isFocused)

        let replacement = PaneState(id: pending.id, tabs: [TabItem(title: "Replacement")])
        controller.rootNode = .pane(replacement)
        #expect(!pending.isFocused)
        #expect(replacement.isFocused)
        controller.focusedPaneId = nil
        #expect(!replacement.isFocused)
        expectProjection(in: controller)
    }

    @Test(arguments: PaneTilingAction.allCases)
    func everyTilingActionKeepsTheFocusProjectionAuthoritative(action: PaneTilingAction) throws {
        let controller = try makeController(paneCount: 4)
        #expect(controller.performTilingAction(.tile))
        #expect(controller.performTilingAction(action))
        expectProjection(in: controller.internalController)
        controller.navigateFocus(direction: .left)
        expectProjection(in: controller.internalController)
        #expect(controller.togglePaneZoom(inPane: try #require(controller.allPaneIds.first)))
        expectProjection(in: controller.internalController)
    }

    @Test
    func retainedRootMaterializationReconcilesReplacedFocusedLeaf() throws {
        let controller = try makeController(paneCount: 2)
        let internalController = controller.internalController
        let root: SplitState = try #require({
            if case .split(let split) = internalController.rootNode { return split }
            return nil
        }())
        let original: PaneState = try #require({
            if case .pane(let pane) = root.first { return pane }
            return nil
        }())
        controller.focusPane(original.id)
        let replacement = PaneState(id: original.id, tabs: original.tabs, selectedTabId: original.selectedTabId)
        // This models an already-mutated retained subtree. Tiling's materialize
        // reuses the root identity, so its rootNode assignment is skipped.
        root.first = .pane(replacement)
        #expect(controller.restoreTilingConfiguration(PaneTilingConfiguration(layout: .tile)))

        let retainedRoot: SplitState = try #require({
            if case .split(let split) = internalController.rootNode { return split }
            return nil
        }())
        #expect(retainedRoot === root)
        #expect(!original.isFocused)
        #expect(replacement.isFocused)
        expectProjection(in: internalController)
        #expect(controller.restoreTilingConfiguration(PaneTilingConfiguration(layout: .manual)))
        expectProjection(in: internalController)
    }

    @Test
    func geometryAndPaneOrderingDoNotInvalidateFocusProjections() throws {
        let controller = try makeController(paneCount: 8)
        #expect(controller.performTilingAction(.tile))
        let changes = observeFocus(in: controller.internalController.rootNode.allPanes)

        #expect(controller.performTilingAction(.moveNext))
        #expect(controller.performTilingAction(.increaseMasterRatio))
        #expect(controller.performTilingAction(.increaseMasterCount))

        #expect(changes.paneIDs.isEmpty)
        expectProjection(in: controller.internalController)
    }

    private func makeController(paneCount: Int) throws -> BonsplitController {
        let controller = BonsplitController()
        var target = try #require(controller.focusedPaneId)
        for index in 1..<paneCount {
            target = try #require(controller.splitPane(
                target,
                orientation: .horizontal,
                withTab: Tab(title: "Pane \(index)")
            ))
        }
        return controller
    }

    private func expectProjection(in controller: SplitViewController) {
        for pane in controller.rootNode.allPanes {
            #expect(pane.isFocused == (pane.id == controller.focusedPaneId))
        }
    }

    private func observeFocus(in panes: [PaneState]) -> FocusInvalidations {
        let changes = FocusInvalidations()
        for pane in panes {
            let paneID = pane.id
            withObservationTracking {
                _ = pane.isFocused
            } onChange: {
                // All model mutations in these synchronous tests are MainActor-isolated.
                MainActor.assumeIsolated { changes.paneIDs.append(paneID) }
            }
        }
        return changes
    }

    @MainActor
    private final class FocusInvalidations {
        var paneIDs: [PaneID] = []
    }
}
