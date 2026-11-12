import Testing
@testable import ServiceBusKit

@Test func packageLoads() {
    #expect(!ServiceBusKit.version.isEmpty)
}
