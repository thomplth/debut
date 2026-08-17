import Darwin

/// Measures how long a key event waited between being stamped and reaching our tap callback.
public struct InputLatencyClock: Sendable {
    public static let defaultPlausibleLimitNanoseconds: UInt64 = 2_000_000_000

    private let numerator: UInt64
    private let denominator: UInt64
    private let plausibleLimitNanoseconds: UInt64

    public init(
        timebaseNumerator: UInt64,
        timebaseDenominator: UInt64,
        plausibleLimitNanoseconds: UInt64 = defaultPlausibleLimitNanoseconds
    ) {
        numerator = max(1, timebaseNumerator)
        denominator = max(1, timebaseDenominator)
        self.plausibleLimitNanoseconds = plausibleLimitNanoseconds
    }

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.init(
            timebaseNumerator: UInt64(timebase.numer),
            timebaseDenominator: UInt64(timebase.denom)
        )
    }

    /// `CGEventTimestamp` is documented as "roughly, nanoseconds since startup", but Apple
    /// Silicon's mach timebase is 125/3, so a raw tick reading and a nanosecond reading of the
    /// same field differ by ~41x. Rather than trust the header, accept whichever unit puts the
    /// event within a plausible window: a keypress cannot have waited weeks, so the wrong
    /// interpretation is off by orders of magnitude and discards itself.
    public func latencyMilliseconds(
        eventTimestamp: UInt64,
        arrivalNanoseconds: UInt64
    ) -> Double? {
        guard eventTimestamp > 0 else { return nil }
        let readings = [eventTimestamp, nanoseconds(fromTicks: eventTimestamp)]
        let plausible = readings.compactMap { stamp -> UInt64? in
            guard let stamp, arrivalNanoseconds >= stamp else { return nil }
            let elapsed = arrivalNanoseconds - stamp
            return elapsed <= plausibleLimitNanoseconds ? elapsed : nil
        }
        guard let elapsed = plausible.min() else { return nil }
        return Double(elapsed) / 1_000_000
    }

    private func nanoseconds(fromTicks ticks: UInt64) -> UInt64? {
        guard numerator != denominator else { return ticks }
        let (scaled, overflowed) = ticks.multipliedReportingOverflow(by: numerator)
        guard !overflowed else { return nil }
        return scaled / denominator
    }
}
