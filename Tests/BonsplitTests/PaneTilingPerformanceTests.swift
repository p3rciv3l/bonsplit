import Foundation
import Testing
@testable import Bonsplit

/// Measures synchronous model actions only; it does not instantiate or measure a rendered UI.
@Suite(.serialized)
@MainActor
struct PaneTilingPerformanceTests {
    @Test(arguments: [2, 4, 8, 16])
    func modelActionsStayBelowFiftyMilliseconds(paneCount: Int) throws {
        for action in PaneTilingAction.allCases {
            var samples: [Double] = []
            for iteration in 0..<110 {
                let controller = try fixture(paneCount: paneCount, action: action)
                let paneIDs = Set(controller.allPaneIds)
                let tabIDs = Set(controller.allTabIds)
                let started = DispatchTime.now().uptimeNanoseconds
                let changed = controller.performTilingAction(action)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

                #expect(changed, "The benchmark must exercise a mutation, not a clamped/no-op action: \(action)")
                #expect(Set(controller.allPaneIds) == paneIDs)
                #expect(Set(controller.allTabIds) == tabIDs)
                if iteration >= 10 {
                    samples.append(elapsed)
                }
            }

            let sorted = samples.sorted()
            let maximum = try #require(sorted.last)
            print("TILING_MODEL action=\(action.rawValue) panes=\(paneCount) samples=\(sorted.count) p50_ms=\(percentile(sorted, 0.50)) p95_ms=\(percentile(sorted, 0.95)) max_ms=\(maximum)")
            #expect(maximum < 50, "Every sampled model action must finish below 50 ms: \(action), \(paneCount) panes")
        }
    }

    private func fixture(paneCount: Int, action: PaneTilingAction) throws -> BonsplitController {
        let controller = BonsplitController()
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        _ = try #require(controller.createTab(title: "Pane 0"))
        for index in 1..<paneCount {
            let pane = try #require(controller.splitPane(orientation: index.isMultiple(of: 2) ? .vertical : .horizontal))
            _ = try #require(controller.createTab(title: "Pane \(index)", inPane: pane))
        }

        if action != .tile {
            _ = controller.performTilingAction(.tile)
        }
        if action == .decreaseMasterCount {
            _ = controller.performTilingAction(.increaseMasterCount)
        }
        if action == .promote {
            controller.focusPane(try #require(controller.allPaneIds.last))
        }
        return controller
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
}
