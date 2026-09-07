import XCTest
import Sparkle

final class VersionOrderingTests: XCTestCase {
    func testPublishedVersionsMigrateToMonotonicBuilds() {
        // Last stable/daily before migration, then nightly, patch, minor. Tags and
        // display versions do not participate in Sparkle's installed-build order.
        let versions = ["0.3.0", "0.4.0", "0.4.3", "10000", "10001", "10002"]
        let comparator = SUStandardVersionComparator.default
        for (index, older) in versions.enumerated() {
            for newer in versions.dropFirst(index + 1) {
                XCTAssertEqual(comparator.compareVersion(older, toVersion: newer), .orderedAscending)
                XCTAssertEqual(comparator.compareVersion(newer, toVersion: older), .orderedDescending)
            }
        }
    }
}
