import Foundation

struct ConfigFile: Codable {
    var intranetDomains: [String]?
    var intranetRoutes: [String]?
    var autoApply: Bool?
}

final class Config: ObservableObject {
    static let shared = Config()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let intranetDomains = "intranetDomains"
        static let intranetRoutes = "intranetRoutes"
        static let autoApply = "autoApply"
    }

    /// Search paths for external config file (first match wins)
    static let configSearchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.config/harmony-split-tunnel/config.json",
            "\(home)/.harmony-split-tunnel.json",
            "/etc/harmony-split-tunnel/config.json",
        ]
    }()

    @Published var intranetDomains: [String] {
        didSet { defaults.set(intranetDomains, forKey: Keys.intranetDomains) }
    }

    @Published var intranetRoutes: [String] {
        didSet { defaults.set(intranetRoutes, forKey: Keys.intranetRoutes) }
    }

    @Published var autoApply: Bool {
        didSet { defaults.set(autoApply, forKey: Keys.autoApply) }
    }

    private(set) var configFilePath: String?

    private init() {
        // Load external config file if present
        let fileConfig = Self.loadConfigFile()
        self.configFilePath = fileConfig.path

        let fileDomains = fileConfig.config?.intranetDomains
        let fileRoutes = fileConfig.config?.intranetRoutes
        let fileAutoApply = fileConfig.config?.autoApply

        // Priority: UserDefaults (user edits) > config file > empty defaults
        if let ud = defaults.stringArray(forKey: Keys.intranetDomains) {
            self.intranetDomains = ud
        } else if let fd = fileDomains {
            self.intranetDomains = fd
            defaults.set(fd, forKey: Keys.intranetDomains)
        } else {
            self.intranetDomains = []
        }

        if let ud = defaults.stringArray(forKey: Keys.intranetRoutes) {
            self.intranetRoutes = ud
        } else if let fr = fileRoutes {
            self.intranetRoutes = fr
            defaults.set(fr, forKey: Keys.intranetRoutes)
        } else {
            self.intranetRoutes = []
        }

        if defaults.object(forKey: Keys.autoApply) != nil {
            self.autoApply = defaults.bool(forKey: Keys.autoApply)
        } else {
            self.autoApply = fileAutoApply ?? true
            defaults.set(self.autoApply, forKey: Keys.autoApply)
        }

        // Sanitize loaded values to prevent shell injection
        self.intranetDomains = self.intranetDomains.compactMap { InputValidation.validateDomain($0) }
        self.intranetRoutes = self.intranetRoutes.compactMap { InputValidation.validateCIDR($0) }
    }

    private static func loadConfigFile() -> (config: ConfigFile?, path: String?) {
        for path in configSearchPaths {
            guard FileManager.default.fileExists(atPath: path),
                  let data = FileManager.default.contents(atPath: path) else { continue }
            do {
                let config = try JSONDecoder().decode(ConfigFile.self, from: data)
                return (config, path)
            } catch {
                print("[Config] Failed to parse \(path): \(error)")
            }
        }
        return (nil, nil)
    }
}
