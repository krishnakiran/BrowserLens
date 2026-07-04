import Foundation

public struct URLCanonicalizer: Sendable {
    public var strippedQueryItems: Set<String>

    public init(strippedQueryItems: Set<String> = URLCanonicalizer.defaultStrippedQueryItems) {
        self.strippedQueryItems = strippedQueryItems
    }

    public func canonicalString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let queryItems = components.queryItems {
            let keptItems = queryItems
                .filter { !strippedQueryItems.contains($0.name.lowercased()) }
                .sorted { left, right in
                    if left.name == right.name {
                        return (left.value ?? "") < (right.value ?? "")
                    }
                    return left.name < right.name
                }
            components.queryItems = keptItems.isEmpty ? nil : keptItems
        }

        return components.string ?? url.absoluteString
    }

    public func domain(for url: URL) -> String {
        guard let host = url.host?.lowercased() else {
            return "unknown"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static let defaultStrippedQueryItems: Set<String> = [
        "fbclid",
        "gclid",
        "igshid",
        "mc_cid",
        "mc_eid",
        "msclkid",
        "ref",
        "spm",
        "utm_campaign",
        "utm_content",
        "utm_medium",
        "utm_source",
        "utm_term"
    ]
}
