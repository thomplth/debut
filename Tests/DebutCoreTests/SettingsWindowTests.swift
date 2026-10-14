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
    /// the highest drawn layer that starts where the detail column's content does. In-process
    /// SwiftUI publishes no accessibility frames without a client, and on macOS 26 neither
    /// `cacheDisplay` nor `CALayer.render(in:)` draws a scroll view's content under the titlebar,
    /// so this reads the layer tree SwiftUI drew into instead of pixels.
    static func titleTop(of section: SettingsSection) throws -> CGFloat {
        let window = SettingsWindow(rootView: SettingsView(selectedSection: section))
        window.appearance = NSAppearance(named: .aqua)
        OffDesktop.hide(window)
        defer { window.close() }
        window.orderFrontRegardless()
        let root = try #require(window.contentView?.layer)
        // Settled once two readings a run-loop turn apart agree.
        let deadline = Date.now + 5
        var previous: CGFloat?
        while Date.now < deadline {
            RunLoop.main.run(until: .now + 0.05)
            let top = titleTop(in: root)
            if let top, top == previous { return top }
            previous = top
        }
        Issue.record("no settled title layer on \(section.rawValue); last reading \(String(describing: previous))")
        return -1
    }

    /// Titles start 24pt into the detail column, which starts after the sidebar: 180pt wide on
    /// macOS 27, inset to end at 188pt on macOS 26.
    static func titleTop(in root: CALayer) -> CGFloat? {
        var top: CGFloat?
        func walk(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            if layer.contents != nil {
                let frame = layer.convert(layer.bounds, to: root)
                let fromTop = root.contentsAreFlipped() ? frame.minY : root.bounds.height - frame.maxY
                if (200...220).contains(frame.minX), fromTop < top ?? .infinity { top = fromTop }
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return top
    }

    @Test("Every page's title starts at the same height")
    func titlesShareTopMargin() throws {
        var tops: [String: CGFloat] = [:]
        for section in SettingsSection.allCases where section != .about {
            tops[section.rawValue] = try Self.titleTop(of: section)
        }
        // Every title is one line of the same font, so its layer tops agree exactly; the
        // Appearance title sat 2pt low when its backdrop picker set the header row's height
        // (KHA-1070).
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


@MainActor
@Suite("Settings sidebar", .serialized)
struct SettingsSidebarTests {
    static func shownWindow() -> SettingsWindow {
        let window = SettingsWindow(rootView: SettingsView())
        OffDesktop.hide(window)
        window.orderFrontRegardless()
        RunLoop.main.run(until: .now + 0.3)
        return window
    }

    static func splitViewController(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            return controller
        }
        return view.subviews.lazy.compactMap(splitViewController(in:)).first
    }

    @Test("The toolbar has no sidebar toggle button")
    func noSidebarToggleButton() throws {
        let window = Self.shownWindow()
        defer { window.close() }
        let identifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        #expect(!identifiers.contains { $0.localizedCaseInsensitiveContains("toggleSidebar") }, "toolbar items \(identifiers)")
    }

    /// View > Hide Sidebar and its shortcut send `toggleSidebar:` down the responder chain.
    @Test("Toggling the sidebar leaves it visible")
    func sidebarCannotBeHidden() throws {
        let window = Self.shownWindow()
        defer { window.close() }
        let root = try #require(window.contentView?.superview)
        let controller = try #require(Self.splitViewController(in: root))
        controller.toggleSidebar(nil)
        let deadline = Date.now + 2
        while Date.now < deadline, !controller.splitViewItems[0].isCollapsed {
            RunLoop.main.run(until: .now + 0.05)
        }
        let items = controller.splitViewItems.map { "collapsed=\($0.isCollapsed) width=\($0.viewController.view.frame.width)" }
        #expect(!controller.splitViewItems[0].isCollapsed, "split items \(items)")
    }
}
