import Foundation
import Testing
@testable import NtfsmacGUI

private struct FakeHTTPDataLoading: HTTPDataLoading {
    let result: Result<(Data, HTTPURLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch result {
        case .success(let pair):
            return (pair.0, pair.1)
        case .failure(let error):
            throw error
        }
    }
}

private let sampleGitHubReleaseJSON = """
{
  "tag_name": "v2.4.0",
  "name": "Release v2.4.0",
  "body": "What's new:\\n- Added update button\\n- Bug fixes",
  "published_at": "2026-09-10T12:00:00Z",
  "assets": [
    {
      "name": "ntfsmac-cli-v2.4.0.tar.gz",
      "size": 55954477,
      "browser_download_url": "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac-cli-v2.4.0.tar.gz"
    },
    {
      "name": "ntfsmac-gui-v2.4.0.dmg",
      "size": 61496426,
      "browser_download_url": "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac-gui-v2.4.0.dmg"
    }
  ]
}
"""

@Test func checkReturnsReleaseUpdateInfoWhenNewerVersionExists() async throws {
    let data = sampleGitHubReleaseJSON.data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/khr898/ntfsmac/releases/latest")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let loader = FakeHTTPDataLoading(result: .success((data, response)))
    let service = GitHubReleaseCheckService(loader: loader)

    let currentVersion = ProductVersion(release: "2.3", build: "040926")
    let update = try await service.checkForUpdates(currentVersion: currentVersion)

    #expect(update != nil)
    #expect(update?.version == "2.4.0")
    #expect(update?.dmgURL.absoluteString == "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac-gui-v2.4.0.dmg")
    #expect(update?.assetSize == 61496426)
    #expect(update?.releaseNotes.contains("Added update button") == true)
}

@Test func checkReturnsNilWhenCurrentVersionIsUpToDate() async throws {
    let data = sampleGitHubReleaseJSON.data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/khr898/ntfsmac/releases/latest")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let loader = FakeHTTPDataLoading(result: .success((data, response)))
    let service = GitHubReleaseCheckService(loader: loader)

    // Current version already at 2.4.0
    let currentVersion = ProductVersion(release: "2.4.0", build: "040926")
    let update = try await service.checkForUpdates(currentVersion: currentVersion)

    #expect(update == nil)
}

@Test func checkSurfacesErrorWhenNoDMGAssetPresent() async throws {
    let noDMGJSON = """
    {
      "tag_name": "v2.4.0",
      "body": "Only CLI",
      "assets": [
        {
          "name": "ntfsmac-cli.tar.gz",
          "size": 12345,
          "browser_download_url": "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac-cli.tar.gz"
        }
      ]
    }
    """
    let data = noDMGJSON.data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/khr898/ntfsmac/releases/latest")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let loader = FakeHTTPDataLoading(result: .success((data, response)))
    let service = GitHubReleaseCheckService(loader: loader)

    await #expect(throws: ReleaseCheckError.missingDMGAsset) {
        _ = try await service.checkForUpdates(currentVersion: ProductVersion(release: "2.3", build: "test"))
    }
}

@Test func checkRejectsUntrustedAssetHost() async throws {
    let spoofedJSON = """
    {
      "tag_name": "v2.5.0",
      "body": "Spoofed",
      "assets": [
        {
          "name": "ntfsmac.dmg",
          "size": 12345,
          "browser_download_url": "https://malicious-site.com/ntfsmac.dmg"
        }
      ]
    }
    """
    let data = spoofedJSON.data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/khr898/ntfsmac/releases/latest")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let loader = FakeHTTPDataLoading(result: .success((data, response)))
    let service = GitHubReleaseCheckService(loader: loader)

    await #expect(throws: ReleaseCheckError.untrustedDownloadHost("malicious-site.com")) {
        _ = try await service.checkForUpdates(currentVersion: ProductVersion(release: "2.3", build: "test"))
    }
}
