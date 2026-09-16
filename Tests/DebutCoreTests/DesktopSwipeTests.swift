import Testing
import CoreGraphics
import Foundation
@testable import DebutCore

@MainActor
@Suite("Desktop swipe interception")
struct DesktopSwipeTests {
    func service(
        desktopNavigationBlocked: @escaping @Sendable () -> Bool = { false },
        mode: DockSwipePostingMode = .legacy,
        switchDesktop: @escaping (Int) -> Void
    ) -> DesktopSwipeService {
        DesktopSwipeService(
            desktopNavigationBlocked: desktopNavigationBlocked,
            postingMode: { mode },
            switchDesktop: switchDesktop
        )
    }

    func event(_ phase: Int64, _ progress: Double = 0, horizontal: Bool = true) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: horizontal ? 1 : 2)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress)
        return event
    }

    @Test("Only horizontal desktop swipes are claimed and one gesture makes one hop")
    func claimsOnlyDesktopSwipe() {
        var moves: [Int] = []
        let service = service { moves.append($0) }
        #expect(service.handle(event(1), enabled: false) != nil)
        #expect(service.handle(event(1, horizontal: false), enabled: true) != nil)
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.01), enabled: true) == nil)
        #expect(moves.isEmpty)
        #expect(service.handle(event(2, -0.12), enabled: true) == nil)
        #expect(service.handle(event(2, -0.7), enabled: true) == nil)
        #expect(service.handle(event(4, -0.7), enabled: true) == nil)
        #expect(moves == [-1])
    }

    @Test("Own synthetic events pass through and disabling drains the physical gesture")
    func syntheticAndDisable() {
        var moves: [Int] = []
        let service = service { moves.append($0) }
        let synthetic = DockSwipeEvent.make(phase: .began, direction: .right)!
        #expect(service.handle(synthetic, enabled: true) != nil)
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.3), enabled: false) == nil)
        #expect(service.handle(event(4), enabled: false) == nil)
        #expect(moves.isEmpty)
        #expect(service.handle(event(1), enabled: false) != nil)
    }

    @Test("Cancelled gestures never switch; a flick can commit from terminal velocity")
    func cancellationAndFlick() {
        var moves: [Int] = []
        let service = service { moves.append($0) }
        _ = service.handle(event(1), enabled: true)
        _ = service.handle(event(8), enabled: true)
        #expect(moves.isEmpty)
        _ = service.handle(event(1), enabled: true)
        let ended = event(4)
        ended.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0.3)
        _ = service.handle(ended, enabled: true)
        #expect(moves == [1])
        service.desktopNavigationAvailable = false
        #expect(service.handle(event(1), enabled: true) != nil)
    }

    @Test("An overview receives the complete native gesture and interception resumes afterwards")
    func overviewPassthroughDoesNotLeaveTrackingState() {
        var moves: [Int] = []
        let overview = SwipeOverviewState(active: true)
        let service = service(
            desktopNavigationBlocked: { overview.active },
            switchDesktop: { moves.append($0) }
        )

        #expect(service.handle(event(1), enabled: true) != nil)
        #expect(service.handle(event(2, 0.4), enabled: true) != nil)
        #expect(service.handle(event(4, 0.4), enabled: true) != nil)
        #expect(moves.isEmpty)

        overview.active = false
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.4), enabled: true) == nil)
        #expect(service.handle(event(4, 0.4), enabled: true) == nil)
        #expect(moves == [1])
    }

    @Test("An overview arriving during a claimed gesture drains it without switching")
    func overviewDrainsClaimedGesture() {
        var moves: [Int] = []
        let service = service { moves.append($0) }

        #expect(service.handle(event(1), enabled: true) == nil)
        service.cancelActiveGesture()
        #expect(service.handle(event(2, 0.4), enabled: true) == nil)
        #expect(service.handle(event(4, 0.4), enabled: true) == nil)
        #expect(moves.isEmpty)

        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, -0.4), enabled: true) == nil)
        #expect(service.handle(event(4, -0.4), enabled: true) == nil)
        #expect(moves == [-1])
    }

    @Test("macOS 27 passes a zero-motion terminal payload through to close the physical gesture")
    func augmentedTerminalCleanup() throws {
        var moves: [Int] = []
        let service = service(mode: .augmented(invertSigns: true)) { moves.append($0) }

        func physical(_ phase: DockSwipePhase, progress: Double, velocity: Double) throws -> CGEvent {
            let event = try #require(DockSwipeEvent.makeForPosting(
                phase: phase,
                direction: .right,
                velocity: velocity,
                progress: progress,
                mode: .augmented(invertSigns: true),
                markSynthetic: false
            ))
            return event
        }

        #expect(service.handle(
            try physical(.began, progress: 1, velocity: 0), enabled: true
        ) == nil)
        #expect(service.handle(
            try physical(.changed, progress: 0.4, velocity: 0), enabled: true
        ) == nil)
        let result = try #require(service.handle(
            try physical(.ended, progress: 1, velocity: 9_999), enabled: true
        ))

        #expect(moves == [-1])
        #expect(result.getDoubleValueField(kCGEventGestureSwipeProgress) == 0)
        #expect(result.getDoubleValueField(kCGEventGestureSwipeVelocityX) == 0)
        let serialized = try #require(result.data as Data?)
        let payload = try #require(Self.binaryField(4_205, in: serialized))
        #expect(Self.littleEndianInt32(payload, at: 64) == 0)
        #expect(Self.littleEndianInt32(payload, at: 84) == 0)
    }

    private static func binaryField(_ field: UInt16, in bytes: Data) -> Data? {
        guard bytes.count >= 4 else { return nil }
        var offset = 4
        while offset + 4 <= bytes.count {
            let elementSize = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let tagAndField = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
            let tag = tagAndField >> 14
            let valueSize: Int
            switch (tag, elementSize) {
            case (0, 1): valueSize = 8
            case (0, let size) where size > 1: valueSize = Int(size)
            case (1, 1), (3, 1): valueSize = 4
            case (3, 2): valueSize = 8
            default: return nil
            }
            let end = offset + 4 + valueSize
            guard end <= bytes.count else { return nil }
            if tagAndField & 0x3FFF == field {
                return bytes.subdata(in: (offset + 4)..<end)
            }
            offset = end
        }
        return nil
    }

    private static func littleEndianInt32(_ data: Data, at offset: Int) -> Int32 {
        let value = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, byte in
            result | (UInt32(byte.element) << UInt32(byte.offset * 8))
        }
        return Int32(bitPattern: value)
    }
}

private final class SwipeOverviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActive: Bool

    init(active: Bool) {
        storedActive = active
    }

    var active: Bool {
        get { lock.withLock { storedActive } }
        set { lock.withLock { storedActive = newValue } }
    }
}
