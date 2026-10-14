import CoreGraphics
import Foundation

/// What one card showed at the moment the overlay was revealed.
struct PreviewCardFreshness: Equatable, Sendable {
    let windowID: CGWindowID
    /// Seconds since the card's preview was captured; `nil` when it had none to show.
    let ageSeconds: Double?
    /// The preview's shape no longer matches the card's, so it was drawn letterboxed.
    let shapeMismatch: Bool
}

/// Measures whether the overlay shows previews that are current, and what keeping them current
/// costs (KHA-1078).
///
/// A session runs from the reveal to the dismissal. It records each card's age and shape at the
/// reveal, then every preview that lands while the overlay is up: each one is a change the user
/// could see happen. One durable `preview_freshness` event summarises the session.
///
/// Capture batches roll up into an hourly `preview_capture_rollup`, so captures per hour, the
/// number power scales with, can be compared before and after a change. The rollup is emitted
/// by the first batch after the interval ends rather than by a timer, so an idle Debut runs none.
///
/// Main-queue confined, like the controller that drives it.
public final class PreviewFreshnessRecorder: @unchecked Sendable {
    typealias Report = @Sendable (String, DiagnosticLevel, [String: String]) -> Void
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct Session {
        let id: Int
        let revealedAt: UInt64
        let cards: [PreviewCardFreshness]
        let pendingCaptures: Int
        var changeMilliseconds: [Double] = []
        var replacements = 0
        var fills = 0
        var changeScores: [Double] = []
        var visualChangesScored = 0
    }

    private struct Rollup {
        let startedAt: UInt64
        var batches = 0
        var requested = 0
        var captured = 0
        var discarded = 0
        var capturedByReason: [String: Int] = [:]
    }

    /// A mean luminance difference below this, in percent of full scale, is colour-conversion
    /// noise rather than anything a viewer could see change.
    static let visibleChangeThreshold = 2.0
    static let rollupInterval: TimeInterval = 3600

    private let report: Report
    private let measuresDevelopmentCosts: Bool
    private let uptime: @Sendable () -> UInt64
    private let background: Executor
    private let main: Executor
    private let costSampler: (any CaptureCostSampling)?
    private let rollupIntervalNanoseconds: UInt64
    private var session: Session?
    private var nextSessionID = 0
    private var rollup: Rollup?
    private var lastCostSample: CaptureCostSample?

    init(
        report: @escaping Report,
        measuresDevelopmentCosts: Bool = DevelopmentMeasurements.isEnabled,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        rollupInterval: TimeInterval = PreviewFreshnessRecorder.rollupInterval,
        costSampler: (any CaptureCostSampling)? = nil,
        background: @escaping Executor = { DispatchQueue.global(qos: .utility).async(execute: $0) },
        main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.report = report
        self.measuresDevelopmentCosts = measuresDevelopmentCosts
        self.uptime = uptime
        self.rollupIntervalNanoseconds = UInt64(max(0, rollupInterval) * 1_000_000_000)
        self.costSampler = measuresDevelopmentCosts
            ? (costSampler ?? SystemCaptureCostSampler())
            : nil
        self.background = background
        self.main = main
    }

    // MARK: - Overlay sessions

    func sessionRevealed(cards: [PreviewCardFreshness], pendingCaptures: Int) {
        nextSessionID += 1
        session = Session(
            id: nextSessionID,
            revealedAt: uptime(),
            cards: cards,
            pendingCaptures: pendingCaptures
        )
    }

    /// A preview landed. While the overlay is up this is a change on screen: a replacement when
    /// the card already showed an image, a fill when it showed the app icon.
    func previewDelivered(windowID: CGWindowID, previous: CGImage?, replacement: CGImage) {
        guard var current = session,
              current.cards.contains(where: { $0.windowID == windowID })
        else { return }
        current.changeMilliseconds.append(Double(uptime() - current.revealedAt) / 1_000_000)
        if previous == nil { current.fills += 1 } else { current.replacements += 1 }
        session = current
        guard measuresDevelopmentCosts, let previous else { return }
        let sessionID = current.id
        let main = self.main
        background { [weak self] in
            let score = Self.changeScore(previous, replacement)
            main { [weak self] in self?.recordChangeScore(score, sessionID: sessionID) }
        }
    }

    func sessionEnded() {
        guard let ended = session else { return }
        session = nil
        let ages = ended.cards.compactMap(\.ageSeconds).sorted()
        var details: [String: String] = [
            "cards": "\(ended.cards.count)",
            "withPreview": "\(ages.count)",
            "shapeMismatches": "\(ended.cards.filter(\.shapeMismatch).count)",
            "pendingCaptures": "\(ended.pendingCaptures)",
            "replacementsAfterReveal": "\(ended.replacements)",
            "fillsAfterReveal": "\(ended.fills)",
        ]
        if !ages.isEmpty {
            details["ageMedianSeconds"] = Self.format(ages[ages.count / 2])
            details["ageMaxSeconds"] = Self.format(ages[ages.count - 1])
        }
        if let first = ended.changeMilliseconds.min(), let last = ended.changeMilliseconds.max() {
            details["firstChangeMilliseconds"] = Self.format(first)
            details["lastChangeMilliseconds"] = Self.format(last)
        }
        if measuresDevelopmentCosts {
            // Scores still being computed when the overlay closes are left out rather than
            // waited for; the count says how many the summary covers.
            details["changesScored"] = "\(ended.changeScores.count)"
            details["visibleChanges"] = "\(ended.changeScores.filter { $0 >= Self.visibleChangeThreshold }.count)"
            if let maximum = ended.changeScores.max() {
                details["changeScoreMaxPercent"] = Self.format(maximum)
                let mean = ended.changeScores.reduce(0, +) / Double(ended.changeScores.count)
                details["changeScoreMeanPercent"] = Self.format(mean)
            }
        }
        report("preview_freshness", .lifecycle, details)
    }

    private func recordChangeScore(_ score: Double, sessionID: Int) {
        guard var current = session, current.id == sessionID else { return }
        current.changeScores.append(score)
        session = current
    }

    // MARK: - Capture accounting

    func batchFinished(
        reason: String,
        requested: Int,
        captured: Int,
        discarded: Int,
        wallMilliseconds: Double
    ) {
        let failed = max(0, requested - captured - discarded)
        // Durable only where it is being studied: background capture makes batches frequent, and
        // the hourly rollup already carries the counts a shipped build needs.
        report(
            "preview_capture_batch",
            measuresDevelopmentCosts ? .lifecycle : .transient,
            [
                "reason": reason,
                "requested": "\(requested)",
                "captured": "\(captured)",
                "discarded": "\(discarded)",
                "failed": "\(failed)",
                "wallMilliseconds": Self.format(wallMilliseconds),
            ]
        )

        let now = uptime()
        var current = rollup ?? Rollup(startedAt: now)
        if rollup == nil { sampleCostBaseline() }
        current.batches += 1
        current.requested += requested
        current.captured += captured
        current.discarded += discarded
        current.capturedByReason[reason, default: 0] += captured
        if now - current.startedAt >= rollupIntervalNanoseconds {
            emitRollup(current, endedAt: now)
            rollup = nil
        } else {
            rollup = current
        }
    }

    private func emitRollup(_ finished: Rollup, endedAt: UInt64) {
        let seconds = Double(endedAt - finished.startedAt) / 1_000_000_000
        var details: [String: String] = [
            "intervalSeconds": Self.format(seconds),
            "batches": "\(finished.batches)",
            "requested": "\(finished.requested)",
            "captured": "\(finished.captured)",
            "discarded": "\(finished.discarded)",
            "failed": "\(max(0, finished.requested - finished.captured - finished.discarded))",
            "capturesPerHour": Self.format(seconds > 0 ? Double(finished.captured) * 3600 / seconds : 0),
            "capturedByReason": finished.capturedByReason
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ","),
        ]
        guard let costSampler, let baseline = lastCostSample else {
            report("preview_capture_rollup", .lifecycle, details)
            return
        }
        // Reading root-owned daemons runs `ps`, so the sample is taken off the main queue and
        // the rollup reported from there.
        let report = self.report
        let counts = details
        let main = self.main
        background { [weak self] in
            let sample = costSampler.sample()
            var details = counts
            details.merge(sample.delta(since: baseline).diagnosticDetails) { $1 }
            report("preview_capture_rollup", .lifecycle, details)
            main { [weak self] in self?.lastCostSample = sample }
        }
    }

    private func sampleCostBaseline() {
        guard let costSampler else { return }
        let main = self.main
        background {
            let sample = costSampler.sample()
            main { [weak self] in self?.lastCostSample = sample }
        }
    }

    // MARK: - Helpers

    /// Mean luminance difference between two previews on a 16x16 area-averaged grid, in percent
    /// of full scale. Drawing both through Core Graphics is why it is a development measurement.
    static func changeScore(_ first: CGImage, _ second: CGImage, gridSize: Int = 16) -> Double {
        guard let a = luminanceGrid(first, size: gridSize),
              let b = luminanceGrid(second, size: gridSize)
        else { return 100 }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count) / 255 * 100
    }

    private static func luminanceGrid(_ image: CGImage, size: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: size,
                      height: size,
                      bitsPerComponent: 8,
                      bytesPerRow: size,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            // `.medium` area-averages, as `WindowImageStatistics.holdsContent` explains.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
