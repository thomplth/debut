import AppKit
import SwiftUI
import Testing
@testable import DebutCore

@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
    @Test("Settings content extends beneath hidden transparent titlebar chrome")
    func settingsUsesIntegratedSidebarChrome() {
        let window = SettingsWindow(
            rootView: AnyView(Color.clear)
        )

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test("Bug reports open the public GitHub issue form")
    func bugReportOpensGitHubIssueForm() throws {
        let components = try #require(
            URLComponents(url: AboutLinks.bugReport, resolvingAgainstBaseURL: false)
        )

        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/thomplth/Debut/issues/new")
        #expect(components.queryItems?.contains(
            URLQueryItem(name: "template", value: "bug_report.yml")
        ) == true)
    }
}

@MainActor
@Suite("Settings page titles", .serialized)
struct SettingsPageTitleTests {
    /// The top edge of a page's title in a real settings window, in points from the window top:
    /// the first row of title ink where the detail column's content starts. In-process SwiftUI
    /// publishes no accessibility frames without a client, so this reads pixels instead.
    static func titleTop(of section: SettingsSection) throws -> CGFloat {
        let window = SettingsWindow(rootView: SettingsView(selectedSection: section))
        window.appearance = NSAppearance(named: .aqua)
        OffDesktop.hide(window)
        defer { window.close() }
        window.orderFrontRegardless()
        RunLoop.main.run(until: .now + 0.3)
        let view = try #require(window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        // Titles start 24pt into the detail column, which starts after the 180pt sidebar.
        let columns = Int(210 * scale)..<Int(260 * scale)
        for y in 0..<rep.pixelsHigh {
            for x in columns {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5, color.redComponent + color.greenComponent + color.blueComponent < 0.9 {
                    return CGFloat(y) / scale
                }
            }
        }
        Issue.record("no title ink on \(section.rawValue)")
        return -1
    }

    @Test("Every page's title starts at the same height")
    func titlesShareTopMargin() throws {
        var tops: [String: CGFloat] = [:]
        for section in SettingsSection.allCases where section != .about {
            tops[section.rawValue] = try Self.titleTop(of: section)
        }
        // Glyph shapes alone move the first inked row by up to half a point; the Appearance
        // title sat 2pt low when its backdrop picker set the header row's height (KHA-1070).
        let spread = (tops.values.max() ?? 0) - (tops.values.min() ?? 0)
        #expect(spread <= 1, "title tops \(tops)")
    }
}

@MainActor
@Suite("Settings segmented pickers", .serialized)
struct SettingsSegmentedPickerTests {
    static func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segmentedControls(in:))
    }

    /// Slider tracks in window coordinates. SwiftUI draws sliders itself; each leaves only a
    /// focus ring view behind, spanning the track.
    static func sliderTracks(in view: NSView) -> [NSRect] {
        var rings: [NSRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "_FocusRingView" { rings.append(v.convert(v.bounds, to: nil)) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return rings.filter { $0.height < 20 }
    }

    /// A segmented control squeezed below its natural width still draws at that width, past
    /// its frame, and each relayout from a nearby slider redraws it at a different size (KHA-1071).
    @Test("Segmented pickers get their natural width and stay inside the page", arguments: SettingsSection.allCases)
    func segmentsKeepNaturalWidth(section: SettingsSection) throws {
        let window = SettingsWindow(rootView: SettingsView(selectedSection: section))
        defer { window.close() }
        // A titled window is pulled back onto a display when ordered in, so it is also hidden.
        OffDesktop.hide(window)
        window.orderFrontRegardless()
        RunLoop.main.run(until: .now + 0.3)
        let view = try #require(window.contentView)
        let tracks = Self.sliderTracks(in: view)
        let trailing = tracks.map(\.maxX).max() ?? view.bounds.maxX - 24
        for control in Self.segmentedControls(in: view) {
            let frame = control.convert(control.bounds, to: nil)
            let label = control.label(forSegment: 0) ?? "?"
            #expect(frame.width >= control.intrinsicContentSize.width - 0.5,
                "\(label) picker is \(frame.width)pt wide but draws \(control.intrinsicContentSize.width)pt")
            #expect(frame.maxX <= trailing + 0.5, "\(label) picker ends at \(frame.maxX), page content at \(trailing)")
        }
    }
}

