import Foundation
import Testing
@testable import DebutCore

@Suite("Input latency clock")
struct InputLatencyClockTests {
    // A realistic Apple Silicon reading: 125/3 timebase, ~28 days of uptime.
    private let ticks: UInt64 = 59_618_280_000_000
    private var uptimeNanoseconds: UInt64 { ticks * 125 / 3 }

    private var appleSilicon: InputLatencyClock {
        InputLatencyClock(timebaseNumerator: 125, timebaseDenominator: 3)
    }

    @Test("Mach tick timestamps convert through the timebase")
    func machTicks() throws {
        let arrival = uptimeNanoseconds + 5_000_000
        let latency = try #require(appleSilicon.latencyMilliseconds(
            eventTimestamp: ticks,
            arrivalNanoseconds: arrival
        ))
        #expect(abs(latency - 5) < 0.001)
    }

    @Test("Nanosecond timestamps are read without conversion")
    func nanoseconds() throws {
        let arrival = uptimeNanoseconds + 5_000_000
        let latency = try #require(appleSilicon.latencyMilliseconds(
            eventTimestamp: arrival - 3_000_000,
            arrivalNanoseconds: arrival
        ))
        #expect(abs(latency - 3) < 0.001)
    }

    @Test("An identity timebase leaves both readings equivalent")
    func identityTimebase() throws {
        let clock = InputLatencyClock(timebaseNumerator: 1, timebaseDenominator: 1)
        let arrival = uptimeNanoseconds
        let latency = try #require(clock.latencyMilliseconds(
            eventTimestamp: arrival - 7_000_000,
            arrivalNanoseconds: arrival
        ))
        #expect(abs(latency - 7) < 0.001)
    }

    @Test("Synthetic events carry no timestamp and report nothing")
    func unstampedEvent() {
        #expect(appleSilicon.latencyMilliseconds(
            eventTimestamp: 0,
            arrivalNanoseconds: uptimeNanoseconds
        ) == nil)
    }

    @Test("A timestamp from the future reports nothing")
    func futureTimestamp() {
        let arrival = uptimeNanoseconds
        #expect(appleSilicon.latencyMilliseconds(
            eventTimestamp: arrival + 1_000_000,
            arrivalNanoseconds: arrival
        ) == nil)
    }

    @Test("A reading implausible under either unit reports nothing")
    func implausibleTimestamp() {
        #expect(appleSilicon.latencyMilliseconds(
            eventTimestamp: 1,
            arrivalNanoseconds: uptimeNanoseconds
        ) == nil)
    }

    @Test("A latency beyond the plausible window reports nothing")
    func beyondPlausibleWindow() {
        let arrival = uptimeNanoseconds + 5_000_000_000
        #expect(appleSilicon.latencyMilliseconds(
            eventTimestamp: ticks,
            arrivalNanoseconds: arrival
        ) == nil)
    }

    @Test("Conversion overflow reports nothing rather than a wrapped value")
    func overflow() {
        #expect(appleSilicon.latencyMilliseconds(
            eventTimestamp: .max,
            arrivalNanoseconds: uptimeNanoseconds
        ) == nil)
    }
}
