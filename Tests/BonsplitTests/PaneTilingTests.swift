@testable import Bonsplit
import AppKit
import Foundation
import SwiftUI
import Testing

@Suite
@MainActor
struct PaneTilingTests {
    @Test
    func defaultsPreserveManualLayoutUntilRequested() throws {
        let controller = try makeController(paneCount: 4)
        let original = controller.treeSnapshot()

        #expect(controller.tilingLayout == .manual)
        #expect(!controller.isTilingEnabled)
        #expect(controller.masterCount == 1)
        #expect(controller.masterRatio == 0.55)
        #expect(controller.performTilingAction(.focusNext))
        #expect(controller.treeSnapshot() == original)
        #expect(controller.tilingLayout == .manual)

        #expect(controller.performTilingAction(.tile))
        #expect(controller.isTilingEnabled)
        #expect(controller.tilingLayout == .tile)
        #expect(controller.zoomedPaneId == nil)
    }

    @Test(arguments: [0, 1, 2, 4, 6])
    func masterCountProducesExpectedColumns(masterCount: Int) throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))
        if masterCount == 0 {
            #expect(controller.performTilingAction(.decreaseMasterCount))
        } else {
            for _ in 1..<masterCount {
                #expect(controller.performTilingAction(.increaseMasterCount))
            }
        }

        #expect(controller.masterCount == masterCount)
        #expect(controller.allPaneIds == panes)
        let geometries = controller.layoutSnapshot().panes
        #expect(geometries.count == 4)

        if masterCount == 0 || masterCount >= 4 {
            for (index, pane) in panes.enumerated() {
                try expectFrame(pane, in: controller, x: 0, y: Double(index) * 200, width: 1000, height: 200)
            }
        } else {
            let stackCount = 4 - masterCount
            for (index, pane) in panes.enumerated() {
                if index < masterCount {
                    let height = 800.0 / Double(masterCount)
                    try expectFrame(pane, in: controller, x: 0, y: Double(index) * height, width: 550, height: height)
                } else {
                    let height = 800.0 / Double(stackCount)
                    try expectFrame(pane, in: controller, x: 550, y: Double(index - masterCount) * height, width: 450, height: height)
                }
            }
        }
    }

    @Test
    func onePaneOccupiesEntireContainerInBothLayouts() throws {
        let controller = try makeController(paneCount: 1)
        let pane = try #require(controller.focusedPaneId)
        for action in [PaneTilingAction.tile, .monocle] {
            #expect(controller.performTilingAction(action))
            try expectFrame(pane, in: controller, x: 0, y: 0, width: 1000, height: 800)
            #expect(controller.focusedPaneId == pane)
            #expect(!controller.performTilingAction(.focusNext))
            #expect(!controller.performTilingAction(.movePrevious))
            #expect(!controller.performTilingAction(.promote))
        }
    }

    @Test(arguments: [PaneTilingAction.tile, .monocle])
    func focusCyclesInBothDirectionsWithoutReordering(layout: PaneTilingAction) throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(layout))
        controller.focusPane(panes[0])

        for expected in Array(panes.dropFirst()) + [panes[0]] {
            #expect(controller.performTilingAction(.focusNext))
            #expect(controller.focusedPaneId == expected)
            if layout == .monocle {
                #expect(controller.zoomedPaneId == expected)
            }
        }
        for expected in Array(panes.dropFirst().reversed()) + [panes[0]] {
            #expect(controller.performTilingAction(.focusPrevious))
            #expect(controller.focusedPaneId == expected)
            if layout == .monocle {
                #expect(controller.zoomedPaneId == expected)
            }
        }
        #expect(controller.allPaneIds == panes)
    }

    @Test
    func monocleTracksDirectAndTabDrivenFocusThenReturnsToTiles() throws {
        let controller = try makeController(paneCount: 3)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))
        let tiledFrames = Dictionary(uniqueKeysWithValues: controller.layoutSnapshot().panes.map { ($0.paneId, $0.frame) })

        #expect(controller.performTilingAction(.toggleLayout))
        #expect(controller.tilingLayout == .monocle)
        controller.focusPane(panes[0])
        #expect(controller.zoomedPaneId == panes[0])

        let targetTab = try #require(controller.tabs(inPane: panes[1]).first)
        controller.selectTab(targetTab.id)
        #expect(controller.focusedPaneId == panes[1])
        #expect(controller.zoomedPaneId == panes[1])

        #expect(controller.performTilingAction(.toggleLayout))
        #expect(controller.tilingLayout == .tile)
        #expect(controller.zoomedPaneId == nil)
        #expect(Dictionary(uniqueKeysWithValues: controller.layoutSnapshot().panes.map { ($0.paneId, $0.frame) }) == tiledFrames)
        #expect(controller.selectedTab(inPane: panes[1])?.id == targetTab.id)
    }

    @Test
    func movesSwapWithWrappingAndPreservePaneContentsAndSelection() throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.allPaneIds
        let contents = Dictionary(uniqueKeysWithValues: panes.map { ($0, controller.tabs(inPane: $0)) })
        let selections = Dictionary(uniqueKeysWithValues: panes.map { ($0, controller.selectedTab(inPane: $0)?.id) })
        #expect(controller.performTilingAction(.tile))
        controller.focusPane(panes[3])

        #expect(controller.performTilingAction(.moveNext))
        #expect(controller.allPaneIds == [panes[3], panes[1], panes[2], panes[0]])
        #expect(controller.focusedPaneId == panes[3])
        #expect(controller.performTilingAction(.movePrevious))
        #expect(controller.allPaneIds == panes)
        #expect(controller.focusedPaneId == panes[3])

        controller.focusPane(panes[1])
        #expect(controller.performTilingAction(.moveNext))
        #expect(controller.allPaneIds == [panes[0], panes[2], panes[1], panes[3]])
        #expect(controller.focusedPaneId == panes[1])
        for pane in panes {
            #expect(controller.tabs(inPane: pane) == contents[pane])
            #expect(controller.selectedTab(inPane: pane)?.id == selections[pane]!)
        }
    }

    @Test
    func promoteInsertsAtHeadAndPromotingMasterSelectsSecondPane() throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))
        controller.focusPane(panes[3])

        #expect(controller.performTilingAction(.promote))
        #expect(controller.allPaneIds == [panes[3], panes[0], panes[1], panes[2]])
        #expect(controller.focusedPaneId == panes[3])

        #expect(controller.performTilingAction(.promote))
        #expect(controller.allPaneIds == [panes[0], panes[3], panes[1], panes[2]])
        #expect(controller.focusedPaneId == panes[0])
    }

    @Test
    func masterRatioIncludesEndpointsAndRejectsOutOfRangeChanges() throws {
        let controller = try makeController(paneCount: 2)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))

        for _ in 0..<7 {
            #expect(controller.performTilingAction(.increaseMasterRatio))
        }
        #expect(abs(controller.masterRatio - 0.9) < 0.000_001)
        try expectFrame(panes[0], in: controller, x: 0, y: 0, width: 900, height: 800)
        let widest = controller.layoutSnapshot().panes
        #expect(!controller.performTilingAction(.increaseMasterRatio))
        #expect(controller.layoutSnapshot().panes == widest)

        for _ in 0..<16 {
            #expect(controller.performTilingAction(.decreaseMasterRatio))
        }
        #expect(abs(controller.masterRatio - 0.1) < 0.000_001)
        try expectFrame(panes[0], in: controller, x: 0, y: 0, width: 100, height: 800)
        let narrowest = controller.layoutSnapshot().panes
        #expect(!controller.performTilingAction(.decreaseMasterRatio))
        #expect(controller.layoutSnapshot().panes == narrowest)
    }

    @Test
    func masterCountSaturatesAtZeroAndRetainsValuesAbovePaneCount() throws {
        let controller = try makeController(paneCount: 2)
        #expect(controller.performTilingAction(.decreaseMasterCount))
        #expect(controller.isTilingEnabled)
        #expect(controller.masterCount == 0)
        #expect(!controller.performTilingAction(.decreaseMasterCount))
        #expect(controller.masterCount == 0)

        for _ in 0..<5 {
            #expect(controller.performTilingAction(.increaseMasterCount))
        }
        #expect(controller.masterCount == 5)
        #expect(controller.allPaneIds.count == 2)
    }

    @Test(arguments: [PaneTilingAction.tile, .monocle])
    func splitAndCloseAutomaticallyRetileExistingPanes(layout: PaneTilingAction) throws {
        let controller = try makeController(paneCount: 3)
        let panes = controller.allPaneIds
        let retainedTabs = Set(controller.allTabIds)
        #expect(controller.performTilingAction(layout))
        let newTab = Tab(title: "Inserted", kind: "terminal")
        let inserted = try #require(controller.splitPane(panes[1], orientation: .vertical, withTab: newTab))

        #expect(controller.allPaneIds == [inserted] + panes)
        #expect(controller.focusedPaneId == inserted)
        #expect(controller.tabs(inPane: inserted).map(\.id) == [newTab.id])
        #expect(Set(controller.allTabIds) == retainedTabs.union([newTab.id]))
        if layout == .monocle {
            #expect(controller.zoomedPaneId == inserted)
        } else {
            try expectFrame(inserted, in: controller, x: 0, y: 0, width: 550, height: 800)
            try expectFrame(panes[2], in: controller, x: 550, y: 1600.0 / 3, width: 450, height: 800.0 / 3)
        }

        #expect(controller.closePane(inserted))
        #expect(controller.allPaneIds == panes)
        #expect(Set(controller.allTabIds) == retainedTabs)
        if layout == .monocle {
            #expect(controller.zoomedPaneId == controller.focusedPaneId)
        } else {
            try expectFrame(panes[0], in: controller, x: 0, y: 0, width: 550, height: 800)
            try expectFrame(panes[2], in: controller, x: 550, y: 400, width: 450, height: 400)
        }
    }

    @Test
    func manualRestoresOriginalGeometryAfterReorderingAndParameterChanges() throws {
        let controller = try makeController(paneCount: 4)
        let original = controller.layoutSnapshot().panes
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))
        controller.focusPane(panes[3])
        #expect(controller.performTilingAction(.promote))
        #expect(controller.performTilingAction(.increaseMasterCount))
        #expect(controller.performTilingAction(.decreaseMasterRatio))
        #expect(controller.performTilingAction(.monocle))

        #expect(controller.performTilingAction(.manual))
        #expect(controller.tilingLayout == .manual)
        #expect(!controller.isTilingEnabled)
        #expect(controller.zoomedPaneId == nil)
        #expect(controller.layoutSnapshot().panes == original)
        #expect(controller.focusedPaneId == panes[3])
        #expect(!controller.performTilingAction(.manual))
    }

    @Test
    func manualAfterPaneLifecycleChangesRetainsOnlyCurrentPanesAndTabs() throws {
        let controller = try makeController(paneCount: 3)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))
        let inserted = try #require(controller.splitPane(panes[0], orientation: .horizontal, withTab: Tab(title: "New")))
        #expect(controller.closePane(panes[1]))
        let currentTabs = Set(controller.allTabIds)

        #expect(controller.performTilingAction(.manual))
        #expect(Set(controller.allPaneIds) == Set([panes[0], panes[2], inserted]))
        #expect(Set(controller.allTabIds) == currentTabs)
        #expect(controller.layoutSnapshot().panes.count == 3)
        #expect(controller.tabs(inPane: panes[1]).isEmpty)
        #expect(controller.allPaneIds.contains(try #require(controller.focusedPaneId)))
    }

    @Test(arguments: [PaneTilingLayout.manual, .tile, .monocle])
    func tilingConfigurationRoundTripsThroughSessionJSON(layout: PaneTilingLayout) throws {
        let configuration = PaneTilingConfiguration(layout: layout, masterCount: 3, masterRatio: 0.635)
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(PaneTilingConfiguration.self, from: encoded) == configuration)
        #expect(PaneTilingConfiguration() == PaneTilingConfiguration(layout: .manual, masterCount: 1, masterRatio: 0.55))
    }

    @Test
    func restoringSettingsAppliesGeometryAndRetainsFocusAndManualBaseline() throws {
        let controller = try makeController(paneCount: 4)
        let original = controller.layoutSnapshot().panes
        let panes = controller.allPaneIds
        controller.focusPane(panes[2])
        let tiled = PaneTilingConfiguration(layout: .tile, masterCount: 2, masterRatio: 0.63)

        #expect(controller.restoreTilingConfiguration(tiled))
        #expect(controller.tilingConfiguration == tiled)
        #expect(controller.allPaneIds == panes)
        #expect(controller.focusedPaneId == panes[2])
        try expectFrame(panes[0], in: controller, x: 0, y: 0, width: 630, height: 400)
        try expectFrame(panes[3], in: controller, x: 630, y: 400, width: 370, height: 400)

        let monocle = PaneTilingConfiguration(layout: .monocle, masterCount: 0, masterRatio: 0.1)
        #expect(controller.restoreTilingConfiguration(monocle))
        #expect(controller.tilingConfiguration == monocle)
        #expect(controller.zoomedPaneId == panes[2])
        #expect(controller.allPaneIds == panes)

        let manual = PaneTilingConfiguration(layout: .manual, masterCount: 7, masterRatio: 0.9)
        #expect(controller.restoreTilingConfiguration(manual))
        #expect(controller.tilingConfiguration == manual)
        #expect(controller.layoutSnapshot().panes == original)
        #expect(controller.focusedPaneId == panes[2])
        #expect(controller.zoomedPaneId == nil)
    }

    @Test(arguments: [
        PaneTilingConfiguration(layout: .tile, masterCount: -1),
        PaneTilingConfiguration(layout: .manual, masterRatio: 0.099),
        PaneTilingConfiguration(layout: .tile, masterRatio: 0.901),
        PaneTilingConfiguration(layout: .tile, masterRatio: .nan),
        PaneTilingConfiguration(layout: .tile, masterRatio: .infinity),
        PaneTilingConfiguration(layout: .tile, masterRatio: -.infinity),
    ])
    func corruptSettingsLeaveCompleteCurrentStateUntouched(configuration: PaneTilingConfiguration) throws {
        let controller = try makeController(paneCount: 4)
        let existing = PaneTilingConfiguration(layout: .monocle, masterCount: 2, masterRatio: 0.63)
        #expect(controller.restoreTilingConfiguration(existing))
        let originalTree = controller.treeSnapshot()
        let originalFocus = controller.focusedPaneId
        let originalZoom = controller.zoomedPaneId

        #expect(!controller.restoreTilingConfiguration(configuration))
        #expect(controller.tilingConfiguration == existing)
        #expect(controller.treeSnapshot() == originalTree)
        #expect(controller.focusedPaneId == originalFocus)
        #expect(controller.zoomedPaneId == originalZoom)
    }

    @Test
    func everyActionRetainsTheActualPaneInstances() throws {
        let controller = try makeController(paneCount: 4)
        let originals = controller.internalController.rootNode.allPanes

        for action in PaneTilingAction.allCases {
            #expect(controller.performTilingAction(action))
            for original in originals {
                let current = try #require(controller.internalController.rootNode.findPane(original.id))
                #expect(current === original)
            }
        }
    }

    @Test
    func ratioActionsPreservePrecisionOfRestoredSettings() throws {
        let controller = try makeController(paneCount: 2)
        #expect(controller.restoreTilingConfiguration(PaneTilingConfiguration(layout: .tile, masterRatio: 0.635)))
        #expect(controller.performTilingAction(.increaseMasterRatio))
        #expect(abs(controller.masterRatio - 0.685) < 0.000_001)
        #expect(controller.performTilingAction(.decreaseMasterRatio))
        #expect(abs(controller.masterRatio - 0.635) < 0.000_001)
    }

    @Test
    func existingZoomControlsKeepTilingPolicyConsistentWithVisibility() throws {
        let controller = try makeController(paneCount: 3)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(.tile))

        #expect(controller.togglePaneZoom(inPane: panes[1]))
        #expect(controller.tilingLayout == .monocle)
        #expect(controller.focusedPaneId == panes[1])
        #expect(controller.zoomedPaneId == panes[1])
        #expect(controller.togglePaneZoom(inPane: panes[2]))
        #expect(controller.tilingLayout == .monocle)
        #expect(controller.focusedPaneId == panes[2])
        #expect(controller.zoomedPaneId == panes[2])

        #expect(controller.togglePaneZoom(inPane: panes[2]))
        #expect(controller.tilingLayout == .tile)
        #expect(controller.zoomedPaneId == nil)
        controller.focusPane(panes[0])
        #expect(controller.zoomedPaneId == nil)

        #expect(controller.performTilingAction(.monocle))
        #expect(controller.clearPaneZoom())
        #expect(controller.tilingLayout == .tile)
        #expect(controller.zoomedPaneId == nil)
        controller.focusPane(panes[1])
        #expect(controller.zoomedPaneId == nil)
    }

    @Test(arguments: [PaneTilingAction.tile, .monocle])
    func explicitDividerResizeAdoptsCurrentGeometryAsManualLayout(layout: PaneTilingAction) throws {
        let controller = try makeController(paneCount: 4)
        let panes = controller.allPaneIds
        #expect(controller.performTilingAction(layout))
        guard case .split(let split) = controller.treeSnapshot() else {
            Issue.record("Expected a root divider for four panes")
            return
        }
        let splitId = try #require(UUID(uuidString: split.id))
        #expect(controller.setDividerPosition(0.72, forSplit: splitId))
        #expect(controller.tilingLayout == .manual)
        #expect(controller.zoomedPaneId == nil)
        try expectFrame(panes[0], in: controller, x: 0, y: 0, width: 720, height: 800)
        let resized = controller.layoutSnapshot().panes

        controller.focusPane(panes[0])
        #expect(controller.layoutSnapshot().panes == resized)
        #expect(controller.performTilingAction(.tile))
        #expect(controller.performTilingAction(.manual))
        #expect(controller.layoutSnapshot().panes == resized)
    }

    @Test(arguments: [SplitOrientation.horizontal, .vertical])
    func denseTilingHonorsPlannedDividerBelowManualMinimum(orientation: SplitOrientation) {
        let state = SplitState(
            orientation: orientation,
            first: .pane(PaneState()),
            second: .pane(PaneState()),
            dividerPosition: 1.0 / 3
        )
        let coordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: state,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            preservesPlannedDividerPosition: true,
            onGeometryChange: nil
        )
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 201, height: 201))
        split.isVertical = orientation == .horizontal
        split.dividerStyle = .thin
        split.addArrangedSubview(NSView(frame: split.bounds))
        split.addArrangedSubview(NSView(frame: split.bounds))
        split.adjustSubviews()
        let available = 201 - split.dividerThickness
        let planned = available / 3

        #expect(abs(coordinator.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0) - planned) < 0.000_001)
        coordinator.setPositionSafely(planned, in: split)
        let tiledSize = split.isVertical ? split.arrangedSubviews[0].frame.width : split.arrangedSubviews[0].frame.height
        #expect(abs(tiledSize - planned) <= 1)

        coordinator.update(
            splitState: state,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            preservesPlannedDividerPosition: false,
            onGeometryChange: nil
        )
        let manualMinimum = min(100, available / 2)
        #expect(abs(coordinator.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0) - manualMinimum) < 0.000_001)
        coordinator.setPositionSafely(planned, in: split)
        let manualSize = split.isVertical ? split.arrangedSubviews[0].frame.width : split.arrangedSubviews[0].frame.height
        #expect(abs(manualSize - manualMinimum) <= 1)
    }

    @Test(arguments: [SplitOrientation.horizontal, .vertical])
    func nativeDividerRepairsSmallPointDriftWithoutRelayingOutPixelRoundedGeometry(orientation: SplitOrientation) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)

        // The first fixture is the foreground sixteen-pane manual-restore repro:
        // 526.5 points of available space must put its half split at 263.25.
        let positions: [(CGFloat, CGFloat)] = [(527.5, 263.25), (1500.5, 749.75)]
        for (extent, expectedPosition) in positions {
            let state = SplitState(
                orientation: orientation,
                first: .pane(PaneState()),
                second: .pane(PaneState()),
                dividerPosition: 0.5
            )
            let coordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
                splitState: state,
                minimumPaneWidth: 100,
                minimumPaneHeight: 100,
                onGeometryChange: nil
            )
            let split = DividerPositionTrackingSplitView(frame: NSRect(
                x: 0, y: 0,
                width: orientation == .horizontal ? extent : 600,
                height: orientation == .vertical ? extent : 600
            ))
            split.isVertical = orientation == .horizontal
            split.dividerStyle = .thin
            split.addArrangedSubview(NSView(frame: split.bounds))
            split.addArrangedSubview(NSView(frame: split.bounds))
            root.addSubview(split)
            split.delegate = coordinator
            coordinator.setPositionSafely(expectedPosition, in: split)
            let backingScale = try #require(split.window).backingScaleFactor
            let first = try #require(split.arrangedSubviews.first)
            let baseline = split.isVertical ? first.frame.width : first.frame.height
            #expect(abs(baseline - expectedPosition) * backingScale <= 1)
            split.positionAssignmentCount = 0
            coordinator.syncPosition(0.5, in: split)
            #expect(split.positionAssignmentCount == 0)

            for drift in [CGFloat(2.25), 5.0] {
                // Native structural layout can change the frame without changing
                // the model or last-applied ratio. Model-driven sync must repair it.
                coordinator.setPositionSafely(expectedPosition + drift, in: split)
                split.positionAssignmentCount = 0
                coordinator.syncPosition(0.5, in: split)
                let actual = split.isVertical ? first.frame.width : first.frame.height
                #expect(abs(actual - expectedPosition) * backingScale <= 1,
                        "Divider stayed at \(actual), expected \(expectedPosition), backing scale \(backingScale)")
                #expect(split.positionAssignmentCount > 0)
                #expect(state.dividerPosition == 0.5)

                split.positionAssignmentCount = 0
                coordinator.syncPosition(0.5, in: split)
                #expect(split.positionAssignmentCount == 0)
            }
            split.removeFromSuperview()
        }
    }

    @MainActor
    private final class DividerPositionTrackingSplitView: NSSplitView {
        var positionAssignmentCount = 0
        override var dividerThickness: CGFloat { 1 }

        override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
            positionAssignmentCount += 1
            super.setPosition(position, ofDividerAt: dividerIndex)
        }
    }

    @Test(arguments: [SplitOrientation.horizontal, .vertical])
    func nativeZoomRetainsMountedViewsAndRestoresDividerGeometry(orientation: SplitOrientation) {
        let firstPane = PaneState()
        let secondPane = PaneState()
        let state = SplitState(
            orientation: orientation,
            first: .pane(firstPane),
            second: .pane(secondPane),
            dividerPosition: 0.37
        )
        let coordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: state,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            onGeometryChange: nil
        )
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        split.isVertical = orientation == .horizontal
        split.dividerStyle = .thin
        let firstView = NSView(frame: split.bounds)
        let secondView = NSView(frame: split.bounds)
        split.addArrangedSubview(firstView)
        split.addArrangedSubview(secondView)
        split.adjustSubviews()

        coordinator.applyZoomedPane(firstPane.id, in: split)
        #expect(!firstView.isHidden)
        #expect(secondView.isHidden)
        expectVisibleFrame(firstView, filling: split)
        #expect(state.dividerPosition == 0.37)
        let drawnDivider = NSRect(x: 100, y: 100, width: 1, height: 100)
        #expect(coordinator.splitView(split, effectiveRect: drawnDivider, forDrawnRect: drawnDivider, ofDividerAt: 0) == .zero)
        #expect(coordinator.splitView(split, additionalEffectiveRectOfDividerAt: 0) == .zero)
        #expect(coordinator.splitView(split, shouldHideDividerAt: 0))

        split.setFrameSize(NSSize(width: 920, height: 640))
        coordinator.applyZoomedPane(firstPane.id, in: split)
        expectVisibleFrame(firstView, filling: split)

        coordinator.applyZoomedPane(secondPane.id, in: split)
        #expect(firstView.isHidden)
        #expect(!secondView.isHidden)
        expectVisibleFrame(secondView, filling: split)
        #expect(state.dividerPosition == 0.37)

        coordinator.applyZoomedPane(nil, in: split)
        #expect(!firstView.isHidden)
        #expect(!secondView.isHidden)
        #expect(split.arrangedSubviews.count == 2)
        #expect(split.arrangedSubviews[0] === firstView)
        #expect(split.arrangedSubviews[1] === secondView)
        #expect(firstView.superview === split)
        #expect(secondView.superview === split)
        let available = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        let firstSize = split.isVertical ? firstView.frame.width : firstView.frame.height
        #expect(abs(firstSize - available * 0.37) <= 1)
        #expect(state.dividerPosition == 0.37)
        #expect(state.first.findPane(firstPane.id) === firstPane)
        #expect(state.second.findPane(secondPane.id) === secondPane)
        #expect(!coordinator.splitView(split, effectiveRect: drawnDivider, forDrawnRect: drawnDivider, ofDividerAt: 0).isEmpty)
        #expect(!coordinator.splitView(split, additionalEffectiveRectOfDividerAt: 0).isEmpty)
        #expect(!coordinator.splitView(split, shouldHideDividerAt: 0))
    }

    @Test
    func nativeZoomFollowsNestedPanePathWithoutReplacingAncestors() {
        let firstPane = PaneState()
        let secondPane = PaneState()
        let thirdPane = PaneState()
        let innerState = SplitState(
            orientation: .vertical,
            first: .pane(secondPane),
            second: .pane(thirdPane),
            dividerPosition: 0.4
        )
        let rootState = SplitState(
            orientation: .horizontal,
            first: .pane(firstPane),
            second: .split(innerState),
            dividerPosition: 0.6
        )
        let rootCoordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: rootState,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            onGeometryChange: nil
        )
        let innerCoordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: innerState,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            onGeometryChange: nil
        )
        let root = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.isVertical = true
        root.dividerStyle = .thin
        let firstView = NSView(frame: root.bounds)
        let inner = NSSplitView(frame: root.bounds)
        inner.isVertical = false
        inner.dividerStyle = .thin
        let secondView = NSView(frame: inner.bounds)
        let thirdView = NSView(frame: inner.bounds)
        inner.addArrangedSubview(secondView)
        inner.addArrangedSubview(thirdView)
        root.addArrangedSubview(firstView)
        root.addArrangedSubview(inner)
        root.adjustSubviews()
        inner.adjustSubviews()

        rootCoordinator.applyZoomedPane(thirdPane.id, in: root)
        innerCoordinator.applyZoomedPane(thirdPane.id, in: inner)
        #expect(firstView.isHidden)
        #expect(!inner.isHidden)
        #expect(secondView.isHidden)
        #expect(!thirdView.isHidden)
        expectVisibleFrame(inner, filling: root)
        expectVisibleFrame(thirdView, filling: inner)

        rootCoordinator.applyZoomedPane(firstPane.id, in: root)
        innerCoordinator.applyZoomedPane(firstPane.id, in: inner)
        #expect(!firstView.isHidden)
        #expect(inner.isHidden)
        expectVisibleFrame(firstView, filling: root)

        rootCoordinator.applyZoomedPane(nil, in: root)
        innerCoordinator.applyZoomedPane(nil, in: inner)
        #expect(!firstView.isHidden)
        #expect(!inner.isHidden)
        #expect(!secondView.isHidden)
        #expect(!thirdView.isHidden)
        #expect(root.arrangedSubviews[0] === firstView)
        #expect(root.arrangedSubviews[1] === inner)
        #expect(inner.arrangedSubviews[0] === secondView)
        #expect(inner.arrangedSubviews[1] === thirdView)
        #expect(abs(firstView.frame.width - (root.bounds.width - root.dividerThickness) * 0.6) <= 1)
        #expect(abs(secondView.frame.height - (inner.bounds.height - inner.dividerThickness) * 0.4) <= 1)
        #expect(rootState.dividerPosition == 0.6)
        #expect(innerState.dividerPosition == 0.4)
        #expect(SplitNode.split(rootState).findPane(firstPane.id) === firstPane)
        #expect(SplitNode.split(rootState).findPane(secondPane.id) === secondPane)
        #expect(SplitNode.split(rootState).findPane(thirdPane.id) === thirdPane)
    }

    @Test
    func focusOnlyPublishesGeometryWhenMonocleVisibilityChanges() throws {
        let controller = try makeController(paneCount: 3)
        #expect(controller.performTilingAction(.tile))
        let recorder = TilingDelegateRecorder()
        controller.delegate = recorder

        #expect(controller.performTilingAction(.focusNext))
        #expect(controller.performTilingAction(.focusPrevious))
        #expect(recorder.focusedPanes.count == 2)
        #expect(recorder.focusedPanes.last == controller.focusedPaneId)
        #expect(recorder.geometrySnapshots.isEmpty)

        #expect(controller.performTilingAction(.monocle))
        #expect(recorder.geometrySnapshots.count == 1)
        #expect(controller.performTilingAction(.focusNext))
        #expect(controller.performTilingAction(.focusPrevious))
        #expect(recorder.focusedPanes.count == 4)
        #expect(recorder.geometrySnapshots.count == 3)
        #expect(recorder.geometrySnapshots.last?.focusedPaneId == controller.focusedPaneId?.id.uuidString)
        #expect(controller.zoomedPaneId == controller.focusedPaneId)
    }

    @MainActor
    private final class TilingDelegateRecorder: BonsplitDelegate {
        var focusedPanes: [PaneID] = []
        var geometrySnapshots: [LayoutSnapshot] = []

        func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
            focusedPanes.append(pane)
        }

        func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
            geometrySnapshots.append(snapshot)
        }
    }

    @Test(arguments: [ContentViewLifecycle.keepAllAlive, .recreateOnSwitch])
    func nonanimatedRendererUpdatesTabSelectionAndMovesThroughSharedController(lifecycle: ContentViewLifecycle) throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: 2)
        controller.configuration.appearance.enableAnimations = false
        controller.configuration.contentViewLifecycle = lifecycle
        let panes = controller.allPaneIds
        let originalTab = try #require(controller.selectedTab(inPane: panes[0]))
        let secondaryTab = try #require(controller.tabs(inPane: panes[0]).first { $0.id != originalTab.id })
        let hostingView = NSHostingView(rootView: anchorTestView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let original = try #require(findNativeAnchor(originalTab.id, in: hostingView))
        let host = try #require(findNativeAnchorHost(for: original))
        let secondaryBefore = findNativeAnchor(secondaryTab.id, in: hostingView)

        controller.selectTab(secondaryTab.id)
        hostingView.rootView = anchorTestView(controller: controller)
        hostingView.layoutSubtreeIfNeeded()
        let selected = try #require(findNativeAnchor(secondaryTab.id, in: hostingView))
        #expect(findNativeAnchorHost(for: selected) === host)
        #expect(controller.selectedTab(inPane: panes[0])?.id == secondaryTab.id)
        if lifecycle == .keepAllAlive {
            #expect(findNativeAnchor(originalTab.id, in: hostingView) === original)
            #expect(selected === secondaryBefore)
        } else {
            #expect(findNativeAnchor(originalTab.id, in: hostingView) == nil)
        }

        #expect(controller.moveTab(secondaryTab.id, toPane: panes[1], atIndex: 0))
        hostingView.rootView = anchorTestView(controller: controller)
        hostingView.layoutSubtreeIfNeeded()
        #expect(controller.tabs(inPane: panes[0]).map(\.id) == [originalTab.id])
        #expect(controller.tabs(inPane: panes[1]).contains { $0.id == secondaryTab.id })
        #expect(controller.selectedTab(inPane: panes[1])?.id == secondaryTab.id)
        let moved = try #require(findNativeAnchor(secondaryTab.id, in: hostingView))
        #expect(findNativeAnchorHost(for: moved) !== host)
        #expect(moved.window === window)
        #expect(host.window === window)
        let slot = try #require(host.superview)
        #expect(!slot.mouseDownCanMoveWindow)
    }

    @Test(arguments: [false, true])
    func nonanimatedRendererReappliesDividerThicknessWithoutChangingRatio(changeWhileZoomed: Bool) throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: 2)
        controller.configuration.appearance.enableAnimations = false
        controller.configuration.appearance.dividerThickness = 1
        #expect(controller.performTilingAction(.tile))
        let hostingView = NSHostingView(rootView: anchorTestView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let split = try #require(nativeSplits(in: hostingView).first)
        #expect(split.dividerThickness == 1)

        if changeWhileZoomed {
            #expect(controller.performTilingAction(.monocle))
            hostingView.rootView = anchorTestView(controller: controller)
            hostingView.layoutSubtreeIfNeeded()
            #expect(split.dividerThickness == 0)
        }
        controller.configuration.appearance.dividerThickness = 8
        hostingView.rootView = anchorTestView(controller: controller)
        hostingView.layoutSubtreeIfNeeded()
        if changeWhileZoomed {
            #expect(split.dividerThickness == 0)
            let visible = try #require(split.arrangedSubviews.first { !$0.isHidden })
            #expect(abs(visible.frame.width - split.bounds.width) <= 1)
            #expect(controller.performTilingAction(.tile))
            hostingView.rootView = anchorTestView(controller: controller)
            hostingView.layoutSubtreeIfNeeded()
        }

        #expect(nativeSplits(in: hostingView).first === split)
        #expect(split.dividerThickness == 8)
        let first = try #require(split.arrangedSubviews.first)
        let second = try #require(split.arrangedSubviews.last)
        #expect(abs(first.frame.width + second.frame.width + split.dividerThickness - split.bounds.width) <= 1)
        #expect(abs(first.frame.width - (split.bounds.width - split.dividerThickness) * 0.55) <= 1)
        #expect(controller.masterRatio == 0.55)
    }

    @Test(arguments: [PaneTilingAction.tile, .monocle])
    func nonanimatedRendererRetainsLayoutAndNativeContentAcrossInteractivityChanges(layout: PaneTilingAction) throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: 3)
        controller.configuration.appearance.enableAnimations = false
        #expect(controller.performTilingAction(layout))
        let hostingView = NSHostingView(rootView: anchorTestView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let nativeRoot = try #require(nativeSplits(in: hostingView).first)
        let model = controller.treeSnapshot()
        let tiling = controller.tilingConfiguration
        let focus = controller.focusedPaneId
        let zoom = controller.zoomedPaneId
        var anchors: [PaneID: NSView] = [:]
        var hosts: [PaneID: NSView] = [:]
        for pane in controller.allPaneIds {
            let selected = try #require(controller.selectedTab(inPane: pane))
            let anchor = try #require(findNativeAnchor(selected.id, in: hostingView))
            anchors[pane] = anchor
            hosts[pane] = try #require(findNativeAnchorHost(for: anchor))
        }

        for interactive in [false, true] {
            controller.isInteractive = interactive
            hostingView.layoutSubtreeIfNeeded()
            #expect(nativeSplits(in: hostingView).first === nativeRoot)
            #expect(nativeRoot.isHidden == !interactive)
            #expect(controller.treeSnapshot() == model)
            #expect(controller.tilingConfiguration == tiling)
            #expect(controller.focusedPaneId == focus)
            #expect(controller.zoomedPaneId == zoom)
            for pane in controller.allPaneIds {
                let selected = try #require(controller.selectedTab(inPane: pane))
                let anchor = try #require(findNativeAnchor(selected.id, in: hostingView))
                let host = try #require(hosts[pane])
                #expect(anchor === anchors[pane])
                #expect(findNativeAnchorHost(for: anchor) === host)
                #expect(host.window === window)
                #expect(host.isHiddenOrHasHiddenAncestor == (!interactive || (zoom != nil && pane != zoom)))
            }
        }
    }

    @Test
    func renderedTileTransitionMaintainsEveryNativeDividerRatio() async throws {
        _ = NSApplication.shared
        let controller = try makeController(paneCount: 4)
        controller.configuration.appearance.enableAnimations = false
        let hostingView = NSHostingView(rootView: anchorTestView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1053, height: 672),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        for action in [PaneTilingAction.tile, .manual, .tile] {
            #expect(controller.performTilingAction(action))
            hostingView.rootView = anchorTestView(controller: controller)
            hostingView.layoutSubtreeIfNeeded()
            // Initial NSSplitView placement uses bounded main-queue retries for
            // provisional bounds. Deliver that complete scheduling window without
            // a time-based sleep so this checks settled, not first-pass, geometry.
            for _ in 0..<12 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                hostingView.layoutSubtreeIfNeeded()
            }
            let splits = nativeSplits(in: hostingView)
            #expect(splits.count == 3)
            for split in splits {
                let coordinator = try #require(split.delegate as? SplitContainerView<NativeAnchorProbe, EmptyView>.Coordinator)
                let first = try #require(split.arrangedSubviews.first)
                let available = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
                let actual = split.isVertical ? first.frame.width : first.frame.height
                let expected = available * coordinator.splitState.dividerPosition
                #expect(abs(actual - expected) <= 1, "\(action.rawValue): native divider \(actual), planned \(expected), available \(available)")
            }
        }
    }

    private func nativeSplits(in view: NSView) -> [NSSplitView] {
        let current = (view as? NSSplitView).map { [$0] } ?? []
        return current + view.subviews.flatMap { nativeSplits(in: $0) }
    }

    @MainActor
    private struct NativeAnchorProbe: NSViewRepresentable {
        let tabID: TabID

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(tabID.id.uuidString)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.identifier = NSUserInterfaceItemIdentifier(tabID.id.uuidString)
        }
    }

    @Test
    func programmaticParentResizeReconcilesNestedPlannedDivider() {
        _ = NSApplication.shared
        let innerState = SplitState(
            orientation: .vertical,
            first: .pane(PaneState()),
            second: .pane(PaneState()),
            dividerPosition: 1.0 / 3
        )
        let outerState = SplitState(
            orientation: .vertical,
            first: .pane(PaneState()),
            second: .split(innerState)
        )
        let innerCoordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: innerState,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            preservesPlannedDividerPosition: true,
            onGeometryChange: nil
        )
        let outerCoordinator = SplitContainerView<EmptyView, EmptyView>.Coordinator(
            splitState: outerState,
            minimumPaneWidth: 100,
            minimumPaneHeight: 100,
            preservesPlannedDividerPosition: true,
            onGeometryChange: nil
        )
        let inner = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        inner.isVertical = false
        inner.dividerStyle = .thin
        inner.addArrangedSubview(NSView(frame: inner.bounds))
        inner.addArrangedSubview(NSView(frame: inner.bounds))
        inner.adjustSubviews()
        let outer = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 1345))
        outer.isVertical = false
        outer.dividerStyle = .thin
        outer.addArrangedSubview(NSView(frame: outer.bounds))
        outer.addArrangedSubview(inner)
        inner.delegate = innerCoordinator

        outerCoordinator.setPositionSafely(672, in: outer)

        let expected = (inner.bounds.height - inner.dividerThickness) / 3
        #expect(abs(inner.arrangedSubviews[0].frame.height - expected) <= 1)
        #expect(innerState.dividerPosition == 1.0 / 3)
        #expect(innerCoordinator.lastAppliedPosition == 1.0 / 3)
    }

    private func anchorTestView(controller: BonsplitController) -> BonsplitView<NativeAnchorProbe, EmptyView> {
        BonsplitView(controller: controller) { tab, _ in
            NativeAnchorProbe(tabID: tab.id)
        } emptyPane: { _ in
            EmptyView()
        }
    }

    private func findNativeAnchor(_ tabID: TabID, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == tabID.id.uuidString { return view }
        for child in view.subviews {
            if let found = findNativeAnchor(tabID, in: child) { return found }
        }
        return nil
    }

    private func findNativeAnchorHost(for view: NSView) -> NSView? {
        var candidate = view.superview
        while let current = candidate {
            if current is NSHostingView<AnyView> { return current }
            candidate = current.superview
        }
        return nil
    }

    private func expectVisibleFrame(_ view: NSView, filling container: NSView) {
        #expect(abs(view.frame.minX - container.bounds.minX) <= 1)
        #expect(abs(view.frame.minY - container.bounds.minY) <= 1)
        #expect(abs(view.frame.width - container.bounds.width) <= 1)
        #expect(abs(view.frame.height - container.bounds.height) <= 1)
    }

    private func makeController(paneCount: Int) throws -> BonsplitController {
        let controller = BonsplitController()
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 800))
        var previous = try #require(controller.focusedPaneId)
        if paneCount > 1 {
            for index in 1..<paneCount {
                previous = try #require(controller.splitPane(
                    previous,
                    orientation: index.isMultiple(of: 2) ? .horizontal : .vertical,
                    withTab: Tab(title: "Pane \(index)", kind: "terminal", isDirty: true),
                    initialDividerPosition: 0.35
                ))
            }
        }
        for pane in controller.allPaneIds {
            let first = try #require(controller.tabs(inPane: pane).first)
            _ = try #require(controller.createTab(title: "Secondary", isPinned: true, inPane: pane))
            controller.selectTab(first.id)
        }
        return controller
    }

    private func expectFrame(
        _ pane: PaneID,
        in controller: BonsplitController,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws {
        let frame = try #require(controller.layoutSnapshot().panes.first { $0.paneId == pane.id.uuidString }).frame
        #expect(abs(frame.x - x) < 0.000_001)
        #expect(abs(frame.y - y) < 0.000_001)
        #expect(abs(frame.width - width) < 0.000_001)
        #expect(abs(frame.height - height) < 0.000_001)
    }
}
