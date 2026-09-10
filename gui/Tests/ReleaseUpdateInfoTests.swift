import Foundation
import Testing
@testable import NtfsmacGUI

@Test func releaseUpdateInfoParsesStandardSemverTag() {
    let info = ReleaseUpdateInfo(
        tagName: "v2.4.0",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Bug fixes and improvements",
        publishedAt: Date()
    )

    #expect(info.version == "2.4.0")
    #expect(info.isNewer(than: ProductVersion(release: "2.3", build: "040926")))
}

@Test func releaseUpdateInfoParsesVersionAndDateBuildTag() {
    let info = ReleaseUpdateInfo(
        tagName: "v2.3.050926",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.3.050926/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Build update",
        publishedAt: Date()
    )

    #expect(info.version == "2.3")
    #expect(info.build == "050926")
    #expect(info.isNewer(than: ProductVersion(release: "2.3", build: "040926")))
}

@Test func releaseUpdateInfoRecognizesSameOrOlderVersionIsNotNewer() {
    let sameVersion = ReleaseUpdateInfo(
        tagName: "v2.3.040926",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.3.040926/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Current build",
        publishedAt: Date()
    )
    #expect(!sameVersion.isNewer(than: ProductVersion(release: "2.3", build: "040926")))

    let olderVersion = ReleaseUpdateInfo(
        tagName: "v1.0.140726",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v1.0.140726/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Older build",
        publishedAt: Date()
    )
    #expect(!olderVersion.isNewer(than: ProductVersion(release: "2.3", build: "040926")))
}

@Test func releaseUpdateInfoHandlesMajorMinorIncrements() {
    let majorBump = ReleaseUpdateInfo(
        tagName: "v3.0.0",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v3.0.0/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Major release",
        publishedAt: Date()
    )
    #expect(majorBump.isNewer(than: ProductVersion(release: "2.3", build: "040926")))

    let minorBump = ReleaseUpdateInfo(
        tagName: "v2.4",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4/ntfsmac.dmg")!,
        assetSize: 61496426,
        releaseNotes: "Minor release",
        publishedAt: Date()
    )
    #expect(minorBump.isNewer(than: ProductVersion(release: "2.3", build: "040926")))
}
