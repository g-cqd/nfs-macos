import Foundation
import Testing

@testable import HubCore

@Suite struct HubTypesTests {
  @Test func spaceBudgetKeepsTheFloor() {
    let budget = SpaceBudget(floor: 25, free: 100)
    #expect(budget.allows(adding: 75))
    #expect(!budget.allows(adding: 76))
    #expect(budget.available == 75)
    #expect(SpaceBudget(floor: 25, free: 10).available == 0)
  }

  @Test func layoutFollowsEnvironment() {
    let layout = HubLayout.standard(
      environment: ["HUB_VOLUME": "/tmp/vol"], home: URL(fileURLWithPath: "/tmp/home"))
    #expect(layout.hub.path == "/tmp/vol/GameHub")
    #expect(layout.bundles.path == "/tmp/vol/Bundles")
    #expect(layout.instances.path == "/tmp/home/Library/Application Support/GameHub/Instances")
  }
}
