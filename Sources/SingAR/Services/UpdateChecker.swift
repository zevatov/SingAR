import Foundation
import AppKit

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
    }

    @Published var status: Status = .idle

    private let releaseApiUrl = URL(string: "https://api.github.com/repos/zevatov/SingAR/releases/latest")!
    private let fallbackUrl = URL(string: "https://t.me/+fgfWiMVNgDdlMTYy")!

    private init() {}

    func checkForUpdates() {
        guard status != .checking else { return }
        status = .checking

        Task {
            do {
                var request = URLRequest(url: releaseApiUrl)
                request.timeoutInterval = 5.0
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    // Private repo or no releases yet - quiet idle state
                    self.status = .upToDate
                    return
                }

                struct GitHubRelease: Decodable {
                    let tag_name: String
                    let html_url: String
                }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestVersion = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let currentVersion = AppVersion.current

                if isVersion(latestVersion, newerThan: currentVersion), let url = URL(string: release.html_url) {
                    self.status = .updateAvailable(version: latestVersion, url: url)
                } else {
                    self.status = .upToDate
                }
            } catch {
                self.status = .upToDate
            }
        }
    }

    func openUpdateTarget() {
        if case .updateAvailable(_, let url) = status {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(fallbackUrl)
        }
    }

    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        return v1.compare(v2, options: .numeric) == .orderedDescending
    }
}
