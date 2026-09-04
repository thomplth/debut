import Testing
import CoreGraphics
@testable import DebutCore

/// Fronting fails by doing nothing. `_SLPSSetFrontProcessWithOptions` reports success whether or
/// not the window comes forward, and the event record that makes the window key is posted into
/// another process and answered by nothing at all. Neither outcome can be observed from here, so
/// these tests cover what a mistake in Debut's own code would break: the resolved symbols and the
/// bytes of the record. Whether macOS honours them is a live check, not a unit test.
struct FrontProcessManagementTests {

    @Test("Every symbol fronting needs resolves")
    func symbolsResolve() {
        let readiness = FrontProcessManagement.readiness
        #expect(readiness.frontProcessResolved)
        #expect(readiness.processSerialNumberResolved)
        // Losing this one degrades fronting rather than breaking it: the process still comes
        // forward, the chosen window just never becomes key, and nothing returns an error.
        #expect(readiness.eventRecordPostResolved)
        #expect(FrontProcessManagement.isAvailable)
    }

    @Test("The key-window record is a left mouse-down naming the target window")
    func keyWindowRecordNamesTheWindow() throws {
        let record = FrontProcessManagement.keyWindowEventRecord(for: 4796)

        // Short by even one byte and `CGSEncodeEventRecord` reads uninitialized heap and aborts.
        #expect(record.count == 0x100)
        #expect(record[0x04] == 0xf8)
        #expect(record[0x08] == UInt8(CGEventType.leftMouseDown.rawValue))
        #expect(record[0x3a] == 0x10)

        let windowID = Self.value(CGWindowID.self, in: record, at: 0x3c)
        #expect(windowID == 4796)

        // Window-relative, and deliberately far past any content: apps sanitize a negative or
        // non-finite point back to the origin, which lands the click on a real control.
        let point = Self.value(CGPoint.self, in: record, at: 0x20)
        #expect(point.x > 100_000)
        #expect(point.y > 100_000)
    }

    @Test("Only the fields the record needs are set")
    func recordIsOtherwiseZeroed() {
        let record = FrontProcessManagement.keyWindowEventRecord(for: 1)
        let written = Set([0x04, 0x08, 0x3a]).union(0x20 ..< 0x30).union(0x3c ..< 0x40)
        #expect(record.indices.allSatisfy { written.contains($0) || record[$0] == 0 })
    }

    private static func value<T>(_: T.Type, in bytes: [UInt8], at offset: Int) -> T {
        bytes[offset ..< offset + MemoryLayout<T>.size].withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
}
