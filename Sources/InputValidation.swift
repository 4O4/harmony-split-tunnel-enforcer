import Foundation

enum InputValidation {
    /// Validates CIDR route: "10.0.0.0/8", "192.168.1.0/24"
    static func validateCIDR(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return s
    }

    /// Validates domain name per RFC 1123.
    static func validateDomain(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 253,
              !s.hasPrefix("."), !s.hasSuffix(".") else { return nil }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        let labelPattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
        for label in labels {
            let l = String(label)
            guard !l.isEmpty, l.count <= 63,
                  l.range(of: labelPattern, options: .regularExpression) != nil
            else { return nil }
        }
        return s
    }

    /// Validates IPv4 address. Returns normalized string or nil.
    static func validateIPv4(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = s.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }

    /// Validates network interface name (e.g. "en0", "utun4").
    static func validateInterface(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^[a-zA-Z][a-zA-Z0-9]{0,14}$"#, options: .regularExpression) != nil
        else { return nil }
        return s
    }
}
