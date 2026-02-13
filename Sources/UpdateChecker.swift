import Foundation
import Combine

final class UpdateChecker: ObservableObject {
    struct UpdateInfo {
        let version: String  // "0.5.0" (no "v" prefix)
        let url: URL         // GitHub release html_url
    }

    @Published var availableUpdate: UpdateInfo? = nil

    private let currentVersion: String?
    private var timer: Timer?
    private let repoURL = "https://api.github.com/repos/4O4/harmony-split-tunnel-enforcer/releases/latest"

    init() {
        #if DEBUG
        if let envVersion = ProcessInfo.processInfo.environment["APP_VERSION"] {
            currentVersion = envVersion
            return
        }
        #endif
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func startPolling(interval: TimeInterval = 4 * 3600) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func checkNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.check()
        }
    }

    private func check() {
        guard let current = currentVersion else {
            SplitTunnelEngine.shared.log("[UpdateChecker] No version available, skipping update check")
            return
        }

        guard let url = URL(string: repoURL) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                SplitTunnelEngine.shared.log("[UpdateChecker] Network error: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String,
                  let releaseURL = URL(string: htmlURL) else {
                SplitTunnelEngine.shared.log("[UpdateChecker] Failed to parse release response")
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if Self.isNewer(latest: latestVersion, current: current) {
                SplitTunnelEngine.shared.log("[UpdateChecker] Update available: \(latestVersion) (current: \(current))")
                DispatchQueue.main.async {
                    self.availableUpdate = UpdateInfo(version: latestVersion, url: releaseURL)
                }
            } else {
                SplitTunnelEngine.shared.log("[UpdateChecker] Up to date (current: \(current), latest: \(latestVersion))")
                DispatchQueue.main.async {
                    self.availableUpdate = nil
                }
            }
        }
        task.resume()
    }

    /// Compare semantic versions. Returns true if `latest` is newer than `current`.
    static func isNewer(latest: String, current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        let count = max(latestParts.count, currentParts.count)
        for i in 0..<count {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}
