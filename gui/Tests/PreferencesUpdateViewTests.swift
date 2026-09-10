import SwiftUI
import Testing
@testable import NtfsmacGUI

private struct FakeCheckService: ReleaseChecking {
    let info: ReleaseUpdateInfo?
    func checkForUpdates(currentVersion: ProductVersion) async throws -> ReleaseUpdateInfo? {
        info
    }
}

@MainActor
@Test func preferencesViewRendersUpdateRowInIdleState() {
    let updater = AppUpdateController(checkService: FakeCheckService(info: nil))
    let view = PreferencesView(
        settings: Settings(defaults: UserDefaults(suiteName: "com.khr898.ntfsmac.tests.update.idle.\(UUID().uuidString)")!),
        installer: HelperInstaller(),
        uninstaller: HelperUninstaller(),
        updater: updater,
        hasActiveMounts: false,
        onBack: {},
        productVersion: ProductVersion(release: "2.3", build: "040926")
    )
    let renderer = ImageRenderer(content: view)

    #expect(renderer.nsImage != nil)
    #expect(updater.state == .idle)
}

@MainActor
@Test func preferencesViewRendersUpToDateLabel() {
    let updater = AppUpdateController(checkService: FakeCheckService(info: nil))
    updater.forceStateForTesting(.upToDate)

    let view = PreferencesView(
        settings: Settings(defaults: UserDefaults(suiteName: "com.khr898.ntfsmac.tests.update.uptodate.\(UUID().uuidString)")!),
        installer: HelperInstaller(),
        uninstaller: HelperUninstaller(),
        updater: updater,
        hasActiveMounts: false,
        onBack: {},
        productVersion: ProductVersion(release: "2.3", build: "040926")
    )
    let renderer = ImageRenderer(content: view)

    #expect(renderer.nsImage != nil)
    #expect(updater.state == .upToDate)
}

@MainActor
@Test func preferencesViewRendersUpdateAvailableAndReadyToRestartStates() {
    let info = ReleaseUpdateInfo(
        tagName: "v2.4.0",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
        assetSize: 5000,
        releaseNotes: "Update notes"
    )
    let updater = AppUpdateController(checkService: FakeCheckService(info: info))
    updater.forceStateForTesting(.updateAvailable(info))

    let viewAvailable = PreferencesView(
        settings: Settings(defaults: UserDefaults(suiteName: "com.khr898.ntfsmac.tests.update.avail.\(UUID().uuidString)")!),
        installer: HelperInstaller(),
        uninstaller: HelperUninstaller(),
        updater: updater,
        hasActiveMounts: false,
        onBack: {},
        productVersion: ProductVersion(release: "2.3", build: "040926")
    )
    #expect(ImageRenderer(content: viewAvailable).nsImage != nil)

    // Ready to restart with no active mounts
    updater.forceStateForTesting(.readyToRestart(stagedAppURL: URL(fileURLWithPath: "/tmp/staged.app"), version: "2.4.0"))
    let viewReady = PreferencesView(
        settings: Settings(defaults: UserDefaults(suiteName: "com.khr898.ntfsmac.tests.update.ready.\(UUID().uuidString)")!),
        installer: HelperInstaller(),
        uninstaller: HelperUninstaller(),
        updater: updater,
        hasActiveMounts: false,
        onBack: {},
        productVersion: ProductVersion(release: "2.3", build: "040926")
    )
    #expect(ImageRenderer(content: viewReady).nsImage != nil)

    // Ready to restart with active mounts present
    let viewBlocked = PreferencesView(
        settings: Settings(defaults: UserDefaults(suiteName: "com.khr898.ntfsmac.tests.update.blocked.\(UUID().uuidString)")!),
        installer: HelperInstaller(),
        uninstaller: HelperUninstaller(),
        updater: updater,
        hasActiveMounts: true,
        onBack: {},
        productVersion: ProductVersion(release: "2.3", build: "040926")
    )
    #expect(ImageRenderer(content: viewBlocked).nsImage != nil)
}
