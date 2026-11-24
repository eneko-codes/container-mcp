import Foundation

/// Just enough of the OCI reference grammar to find the registry a pull would contact.
public enum ImageReference {
    /// Docker Hub answers under several names; the allowlist treats them as one.
    static let dockerHubAliases: Set<String> = ["docker.io", "registry-1.docker.io", "index.docker.io"]

    /// True for references made only of characters the OCI grammar allows.
    public static func isWellFormed(_ reference: String) -> Bool {
        guard !reference.isEmpty, reference.count <= 512 else { return false }
        return reference.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$"#, options: .regularExpression) != nil
    }

    /// The registry domain, lowercased. A first path component counts as a domain when it
    /// contains a dot or a colon or is `localhost`, as in Docker's reference parser; otherwise
    /// the reference belongs to `defaultDomain`.
    public static func domain(of reference: String, defaultDomain: String) -> String {
        guard let slash = reference.firstIndex(of: "/") else { return defaultDomain.lowercased() }
        let first = String(reference[..<slash])
        if first.contains(".") || first.contains(":") || first == "localhost" {
            return first.lowercased()
        }
        return defaultDomain.lowercased()
    }

    /// True when `domain` is listed, counting Docker Hub's aliases as the same registry.
    public static func isAllowed(domain: String, registries: [String]) -> Bool {
        let domain = domain.lowercased()
        if registries.contains(domain) { return true }
        if dockerHubAliases.contains(domain) {
            return registries.contains { dockerHubAliases.contains($0) }
        }
        return false
    }
}
