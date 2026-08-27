import Foundation
import Testing
@testable import SpaceSwitchLabCore

@Suite("Measured gesture recipes")
struct GestureRecipeTests {
    @Test("Debut instant is the current confirmed two-phase gesture")
    func debutInstant() {
        let recipe = GestureRecipe.preset(.debutInstant)

        #expect(recipe.hopScheduling == .confirmedAdjacent)
        #expect(recipe.durationMilliseconds == 0)
        #expect(recipe.velocity == 400)
        #expect(recipe.includeEnvelope)
        #expect(recipe.includeDirectionFlag)
        #expect(recipe.includeZoomEpsilon)
        #expect(recipe.includeHorizontalMotion)
        #expect(recipe.includeScrollY)
        #expect(recipe.velocityPhases == .endedOnly)
        #expect(recipe.yVelocity == .zero)

        let frames = recipe.frames(direction: .right, distance: 3)
        #expect(frames.map(\.phase) == [.began, .ended])
        #expect(frames.map(\.progress) == [0, 2])
        #expect(frames.map(\.velocityX) == [0, 400])
        #expect(frames.map(\.velocityY) == [0, 0])
    }

    @Test("Debut driven uses timed cubic progress and a release velocity")
    func debutDriven() {
        let recipe = GestureRecipe.preset(.debutDriven)
        let frames = recipe.frames(direction: .left, distance: 1)

        #expect(recipe.durationMilliseconds == 150)
        #expect(recipe.sampleRate == 120)
        #expect(recipe.easing == .cubicEaseOut)
        #expect(frames.first?.phase == .began)
        #expect(frames.last?.phase == .ended)
        #expect(frames.last?.progress == -1)
        #expect(frames.last?.velocityX == -60)
        #expect(frames.dropFirst().dropLast().allSatisfy { $0.phase == .changed })
        #expect(frames.dropFirst().dropLast().allSatisfy { $0.velocityX == 0 })
        #expect(frames.map(\.delayMilliseconds) == frames.map(\.delayMilliseconds).sorted())
    }

    @Test("Space Rabbit legacy batches its instant two-phase gestures")
    func spaceRabbitLegacy() {
        let recipe = GestureRecipe.preset(.spaceRabbitLegacy)

        #expect(recipe.hopScheduling == .batched)
        #expect(recipe.velocity == 400)
        #expect(recipe.frames(direction: .right, distance: 2).map(\.phase) == [.began, .ended])
        #expect(recipe.includeEnvelope)
    }

    @Test("InstantSpaceSwitcher fields match the code, not the Instant label")
    func instantSpaceSwitcher() {
        let recipe = GestureRecipe.preset(.instantSpaceSwitcher)
        let frames = recipe.frames(direction: .left, distance: 3)
        let epsilon = -Double(Float.leastNonzeroMagnitude)

        #expect(recipe.hopScheduling == .batched)
        #expect(recipe.scaleVelocityByDistance)
        #expect(!recipe.includeEnvelope)
        #expect(!recipe.includeDirectionFlag)
        #expect(!recipe.includeZoomEpsilon)
        #expect(!recipe.includeHorizontalMotion)
        #expect(!recipe.includeScrollY)
        #expect(recipe.velocityPhases == .all)
        #expect(recipe.yVelocity == .matchX)
        #expect(frames.map(\.phase) == [.began, .changed, .ended])
        #expect(frames.allSatisfy { $0.progress == epsilon })
        #expect(frames.allSatisfy { $0.velocityX == -6000 })
        #expect(frames.allSatisfy { $0.velocityY == -6000 })
    }

    @Test("Recipe values are clamped before posting")
    func sanitization() {
        var recipe = GestureRecipe.preset(.debutDriven)
        recipe.durationMilliseconds = -50
        recipe.sampleRate = 10_000
        recipe.velocity = -1
        recipe.endedProgress = 100

        let clean = recipe.sanitized()

        #expect(clean.durationMilliseconds == 0)
        #expect(clean.sampleRate == 240)
        #expect(clean.velocity == 0)
        #expect(clean.endedProgress == 10)
    }
}

@Suite("Switch routing")
struct SwitchRoutingTests {
    @Test("Confirmed mode posts only the next adjacent hop")
    func confirmed() {
        let route = SwitchRoute(from: 0, to: 3, desktopCount: 4)
        #expect(route?.directions(for: .confirmedAdjacent) == [.right])
    }

    @Test("Batched mode posts every requested hop immediately")
    func batched() {
        let route = SwitchRoute(from: 3, to: 0, desktopCount: 4)
        #expect(route?.directions(for: .batched) == [.left, .left, .left])
    }

    @Test("Invalid and same-desktop routes do not post")
    func invalid() {
        #expect(SwitchRoute(from: 1, to: 1, desktopCount: 3) == nil)
        #expect(SwitchRoute(from: 1, to: 3, desktopCount: 3) == nil)
    }
}

@Suite("Control-number shortcuts")
struct HotkeyMappingTests {
    @Test("Control plus number-row 1 through 9 maps to zero-based desktops")
    func numbers() {
        let keyCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, keyCode) in keyCodes.enumerated() {
            #expect(HotkeyMapping.desktopIndex(
                keyCode: Int64(keyCode),
                modifiers: .control,
                requiredModifiers: .control
            ) == index)
        }
    }

    @Test("Additional modifiers and non-number keys pass through")
    func rejectsOtherKeys() {
        #expect(HotkeyMapping.desktopIndex(
            keyCode: 18,
            modifiers: [.control, .shift],
            requiredModifiers: .control
        ) == nil)
        #expect(HotkeyMapping.desktopIndex(
            keyCode: 0,
            modifiers: .control,
            requiredModifiers: .control
        ) == nil)
    }
}

@Suite("Lab settings persistence")
struct LabSettingsTests {
    @Test("A customized recipe survives JSON persistence")
    func roundTrip() throws {
        var settings = LabSettings.defaults
        settings.selectedPreset = .custom
        settings.recipe.velocity = 777
        settings.requiredModifiers = [.control, .option]

        let decoded = try JSONDecoder().decode(
            LabSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded == settings)
    }
}
