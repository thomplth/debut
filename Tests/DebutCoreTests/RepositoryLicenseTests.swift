import Foundation
import Testing

@Suite("Repository license")
struct RepositoryLicenseTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Canonical GPLv3 terms are included")
    func canonicalLicenseIsIncluded() throws {
        let licenseURL = repositoryRoot.appendingPathComponent("LICENSE")
        let license = try String(contentsOf: licenseURL, encoding: .utf8)

        #expect(license.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(license.contains("Version 3, 29 June 2007"))
        #expect(license.contains("TERMS AND CONDITIONS"))
        #expect(license.contains("END OF TERMS AND CONDITIONS"))
        #expect(license.count > 30_000)
    }

    @Test("Repository declares GPL-3.0-only")
    func repositoryDeclaresExactLicense() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let packageManifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        #expect(readme.contains("GPL-3.0-only"))
        #expect(packageManifest.contains("SPDX-License-Identifier: GPL-3.0-only"))
    }
}
