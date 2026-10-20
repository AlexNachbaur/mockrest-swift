import Foundation
import MockRESTCore
import Testing

/// `MockRESTVersion.current` is maintained by hand, so it is checked against the changelog —
/// the one other place a release is recorded.
@Suite struct VersionTests {
    /// `CHANGELOG.md` at the package root, located from this source file. It is not there when
    /// tests run somewhere the checkout is not (a device or emulator), and the test skips.
    static let changelogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("CHANGELOG.md")

    static var changelogIsReadable: Bool {
        FileManager.default.isReadableFile(atPath: changelogURL.path)
    }

    private func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { $0 }
        return numbers.count == 3 ? numbers : nil
    }

    @Test func currentIsThreeNumericComponents() {
        #expect(components(MockRESTVersion.current) != nil)
    }

    @Test(.enabled(if: VersionTests.changelogIsReadable))
    func currentTracksTheNewestReleasedChangelogHeading() throws {
        let changelog = try String(contentsOf: Self.changelogURL, encoding: .utf8)
        let headings = changelog.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("## [") }
        #expect(headings.first == "## [Unreleased]", "The changelog must open with a fresh Unreleased section")

        // The first `## [x.y.z]` heading is the newest release.
        let released = headings.compactMap { heading -> String? in
            guard let close = heading.firstIndex(of: "]") else { return nil }
            let name = String(heading[heading.index(heading.startIndex, offsetBy: 4)..<close])
            return components(name) == nil ? nil : name
        }
        let newest = try #require(released.first, "CHANGELOG.md has no released version heading")
        let newestComponents = try #require(components(newest))
        let current = try #require(components(MockRESTVersion.current))

        // Whether anything is recorded between `## [Unreleased]` and the next heading.
        let lines = changelog.split(whereSeparator: \.isNewline).map(String.init)
        let start = try #require(lines.firstIndex(of: "## [Unreleased]"))
        let unreleased = lines[(start + 1)...].prefix { !$0.hasPrefix("## [") }
        let hasUnreleasedWork = unreleased.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if hasUnreleasedWork {
            // Mid-cycle the constant may already name the release being prepared, but it can
            // never lag the last one that shipped.
            #expect(
                !current.lexicographicallyPrecedes(newestComponents),
                "MockRESTVersion.current (\(MockRESTVersion.current)) is older than the released \(newest)")
        } else {
            #expect(
                MockRESTVersion.current == newest,
                "MockRESTVersion.current must equal the newest released CHANGELOG heading")
        }
    }
}
