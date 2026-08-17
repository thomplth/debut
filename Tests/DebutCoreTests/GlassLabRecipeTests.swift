import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Glass lab recipes")
struct GlassLabRecipeTests {
    @Test("The comparison matrix covers every requested family")
    func coversRequestedFamilies() {
        let recipes = GlassLabRecipe.allCases

        #expect(recipes.contains { $0.family == .swiftUIIndependent })
        #expect(recipes.contains { $0.family == .swiftUIContainer })
        #expect(recipes.contains { $0.family == .appKitGlass })
        #expect(recipes.contains { $0.family == .supportedTuning })
        #expect(recipes.contains { $0.family == .legacyControl })
        #expect(recipes.contains { $0.family == .privateResearch })
    }

    @Test("Only research recipes use undocumented styles")
    func privateRecipesAreClearlySeparated() {
        let privateRecipes = GlassLabRecipe.allCases.filter(\.usesPrivateAPI)

        #expect(Set(privateRecipes) == [.privateDock, .privateAppIcons])
        #expect(privateRecipes.allSatisfy { $0.family == .privateResearch })
        #expect(GlassLabRecipe.privateDock.appKitStyleRawValue == 2)
        #expect(GlassLabRecipe.privateAppIcons.appKitStyleRawValue == 3)
    }

    @Test("Artifact names are stable and unique")
    func artifactNamesAreStableAndUnique() {
        let names = GlassLabRecipe.allCases.map(\.artifactName)

        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("DebutGlassLab-") })
        #expect(names.allSatisfy { !$0.contains(" ") })
    }

    @Test("Supported tuning is exact and neutral")
    func supportedTuningIsExact() {
        let tuning = GlassLabRecipe.appKitTunedNeutral.tuning

        #expect(tuning.tintWhite == 0.5)
        #expect(tuning.tintAlpha == 0.10)
        #expect(tuning.borderWhite == 1.0)
        #expect(tuning.borderAlpha == 0.18)
        #expect(tuning.borderWidth == 0.5)
        #expect(tuning.shadowAlpha == 0.28)
        #expect(tuning.shadowRadius == 22)
        #expect(tuning.shadowOffsetY == -8)
        #expect(tuning.cornerRadius == 28)
    }

    @Test("Bundle configuration falls back to the production baseline")
    func bundleConfigurationFallback() {
        #expect(GlassLabRecipe(bundleValue: nil) == .swiftUIIndependentClear)
        #expect(GlassLabRecipe(bundleValue: "not-a-recipe") == .swiftUIIndependentClear)
        #expect(GlassLabRecipe(bundleValue: "appkit-tuned-neutral") == .appKitTunedNeutral)
    }

    @Test("Capture validation rejects uniform pixels")
    func captureValidationRejectsUniformPixels() throws {
        let uniform = try #require(makeImage(pixels: [0xFF777777, 0xFF777777]))
        let varied = try #require(makeImage(pixels: [0xFF111111, 0xFFEEEEEE]))

        #expect(!GlassLabCaptureValidator.containsVisibleContent(uniform))
        #expect(GlassLabCaptureValidator.containsVisibleContent(varied))
    }

    private func makeImage(pixels: [UInt32]) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: pixels.count,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixels.count * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
