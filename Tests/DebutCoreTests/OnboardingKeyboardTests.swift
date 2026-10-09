import CoreGraphics
import Testing
@testable import DebutCore

@MainActor
@Suite("Onboarding keyboard diagram")
struct OnboardingKeyboardTests {
    @Test("The cropped left half places Tab above Caps Lock and Command beside Option")
    func layout() throws {
        let keys = OnboardingKeyboard.leftHalf.flatMap(\.self)
        let tab = try #require(keys.first { $0.keyCode == OnboardingKeyboard.tab })
        let command = try #require(keys.first { $0.keyCode == OnboardingKeyboard.leftCommand })
        let option = try #require(keys.first { $0.keyCode == OnboardingKeyboard.leftOption })
        #expect(tab.label == "tab")
        #expect(command.label == "command")
        #expect(option.label == "option")
        // Right-hand keys are cropped away, so a right Command press has nowhere to show.
        #expect(!keys.contains { $0.keyCode == 54 })
        let bottom = try #require(OnboardingKeyboard.leftHalf.last)
        #expect(bottom.firstIndex(of: option)! + 1 == bottom.firstIndex(of: command)!)
    }

    @Test("Modifier presses follow the physical side that changed")
    func modifiers() {
        var state = OnboardingKeyPresses()
        state.apply(.flagsChanged(keyCode: OnboardingKeyboard.leftCommand, flags: [.maskCommand], deviceFlags: 0x08))
        #expect(state.pressed == [OnboardingKeyboard.leftCommand])
        // Holding right Command too and then lifting left Command keeps only the right side down.
        state.apply(.flagsChanged(keyCode: 54, flags: [.maskCommand], deviceFlags: 0x18))
        state.apply(.flagsChanged(keyCode: OnboardingKeyboard.leftCommand, flags: [.maskCommand], deviceFlags: 0x10))
        #expect(state.pressed == [54])
        state.apply(.flagsChanged(keyCode: 54, flags: [], deviceFlags: 0))
        #expect(state.pressed.isEmpty)
    }

    @Test("Key down and key up mark ordinary keys, including Tab under Command")
    func ordinaryKeys() {
        var state = OnboardingKeyPresses()
        state.apply(.flagsChanged(keyCode: OnboardingKeyboard.leftOption, flags: [.maskAlternate], deviceFlags: 0x20))
        state.apply(.keyDown(keyCode: OnboardingKeyboard.tab))
        #expect(state.pressed == [OnboardingKeyboard.leftOption, OnboardingKeyboard.tab])
        state.apply(.keyUp(keyCode: OnboardingKeyboard.tab))
        state.apply(.flagsChanged(keyCode: OnboardingKeyboard.leftOption, flags: [], deviceFlags: 0))
        #expect(state.pressed.isEmpty)
    }

    @Test("Reset clears keys whose key up never arrived")
    func reset() {
        var state = OnboardingKeyPresses()
        state.apply(.flagsChanged(keyCode: OnboardingKeyboard.leftCommand, flags: [.maskCommand], deviceFlags: 0x08))
        state.apply(.keyDown(keyCode: OnboardingKeyboard.tab))
        state.apply(.reset)
        #expect(state.pressed.isEmpty)
    }
}

@MainActor
@Suite("Permission guide placement")
struct PermissionGuidePlacementTests {
    @Test("The guide sits inside the System Settings window, even on a small screen", arguments: [
        CGRect(x: 0, y: 0, width: 1024, height: 640),
        CGRect(x: 0, y: 0, width: 1440, height: 900),
    ])
    func insideSettings(_ visible: CGRect) {
        // System Settings fills most of a small screen, leaving no room above or below it.
        let settings = CGRect(x: visible.midX - 358, y: visible.minY + 8, width: 716, height: visible.height - 16)
        let frame = OnboardingPermissionGuide.panelFrame(inside: settings, visibleFrame: visible)
        #expect(settings.contains(frame))
        #expect(visible.contains(frame))
        // It belongs to the content pane, right of the sidebar, near the bottom edge.
        #expect(frame.minX >= settings.minX + 200)
        #expect(frame.minY - settings.minY < 40)
    }

    @Test("A narrow System Settings window still keeps the guide within its bounds")
    func narrowWindow() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let settings = CGRect(x: 20, y: 20, width: 480, height: 400)
        let frame = OnboardingPermissionGuide.panelFrame(inside: settings, visibleFrame: visible)
        #expect(settings.contains(frame))
    }
}

@MainActor
@Suite("Onboarding keyboard and demo layout")
struct OnboardingDemoLayoutTests {
    nonisolated static let commandTab: Set<CGKeyCode> = [OnboardingKeyboard.leftCommand, OnboardingKeyboard.tab]
    nonisolated static let optionTab: Set<CGKeyCode> = [OnboardingKeyboard.leftOption, OnboardingKeyboard.tab]
    // Visible plate aspects of the bundled Command-Tab and Option-Tab demos.
    nonisolated static let commandPlate = 1630.0 / 1168
    nonisolated static let optionPlate = 2548.0 / 828

    static func layout(_ aspect: Double, _ keys: Set<CGKeyCode>, height: CGFloat = 310) -> OnboardingDemoLayout {
        OnboardingDemoLayout(width: 740, height: height, plateAspect: aspect, unit: 40, highlighted: keys)
    }

    @Test("Margin, gap and right margin are equal, with the keyboard's faded tail one key into the gap", arguments: [
        (commandPlate, commandTab), (optionPlate, optionTab),
    ])
    func equalSpacing(_ aspect: Double, _ keys: Set<CGKeyCode>) {
        let layout = Self.layout(aspect, keys)
        let tailEnd = layout.keyboardMinX + layout.keyboardWidth
        let right = 740 - layout.plate.maxX
        #expect(abs(layout.plate.minX - tailEnd - (layout.keyboardMinX - OnboardingDemoLayout.reachUnits * 40)) < 0.5)
        #expect(abs(right - layout.keyboardMinX) < 0.5)
        #expect(layout.plate.minY >= 0 && layout.plate.maxY <= 310)
    }

    @Test("The keyboard keeps one anchor across both switcher pages")
    func anchored() {
        #expect(Self.layout(Self.commandPlate, Self.commandTab).keyboardMinX
            == Self.layout(Self.optionPlate, Self.optionTab).keyboardMinX)
    }

    @Test("Highlighted keys stay sharp, left of the fade, even beside a very wide demo")
    func highlightedKeysVisible() {
        for keys in [Self.commandTab, Self.optionTab] {
            let layout = Self.layout(5, keys)
            let sharp = layout.keyboardWidth - OnboardingDemoLayout.fadeUnits * 40
            #expect(sharp + 0.001 >= OnboardingKeyboard.rightEdge(of: keys) * 40)
            #expect(layout.plate.minX >= layout.keyboardMinX + layout.keyboardWidth
                - OnboardingDemoLayout.reachUnits * 40)
        }
    }

    @Test("Beside the wide Option-Tab demo, Command sits left of the fade")
    func commandStaysSharpOnOptionTab() {
        let layout = Self.layout(Self.optionPlate, Self.optionTab)
        let sharp = layout.keyboardWidth - OnboardingDemoLayout.fadeUnits * 40
        #expect(sharp + 0.001 >= OnboardingKeyboard.rightEdge(of: [OnboardingKeyboard.leftCommand]) * 40 - 10)
    }

    @Test("A short window keeps the anchor and gap, and never reveals the rows' ends")
    func compact() {
        let layout = Self.layout(Self.commandPlate, Self.commandTab, height: 246)
        #expect(layout.keyboardMinX == Self.layout(Self.optionPlate, Self.optionTab).keyboardMinX)
        let reach = OnboardingDemoLayout.reachUnits * 40
        #expect(abs(layout.plate.minX - layout.keyboardMinX - layout.keyboardWidth - (layout.keyboardMinX - reach)) < 0.5)
        #expect(layout.keyboardWidth <= (OnboardingDemoLayout.maximumUnits + OnboardingDemoLayout.reachUnits) * 40)
        for row in OnboardingKeyboard.leftHalf {
            #expect(row.reduce(0) { $0 + $1.width } >= OnboardingDemoLayout.maximumUnits + OnboardingDemoLayout.reachUnits)
        }
    }

    @Test("Right edges are measured in key units along the key's row")
    func rightEdges() {
        // fn, control, option: option ends three keys in; command adds 1.25 more.
        #expect(OnboardingKeyboard.rightEdge(of: [OnboardingKeyboard.leftOption]) == 3)
        #expect(OnboardingKeyboard.rightEdge(of: [OnboardingKeyboard.leftCommand]) == 4.25)
        #expect(OnboardingKeyboard.rightEdge(of: [OnboardingKeyboard.tab]) == 1.5)
    }
}
