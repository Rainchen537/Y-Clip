import Foundation

enum SoftwareUpdateAssetSelector {
    static var compiledArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    static func normalizedVersionString(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func expectedAssetName(releaseVersion: String, architecture: String) -> String? {
        guard architecture == "arm64" || architecture == "x86_64" else {
            return nil
        }

        let version = normalizedVersionString(releaseVersion)
        guard versionComponents(version) != nil else {
            return nil
        }

        return "Y-Clip-v\(version)-\(architecture).dmg"
    }

    static func selectAssetName(
        from assetNames: [String],
        releaseVersion: String,
        architecture: String
    ) -> String? {
        guard let expectedName = expectedAssetName(
            releaseVersion: releaseVersion,
            architecture: architecture
        ) else {
            return nil
        }

        return assetNames.first(where: { $0 == expectedName })
    }

    static func isExpectedApplicationVersion(
        actualVersion: String,
        expectedVersion: String
    ) -> Bool {
        !expectedVersion.isEmpty && actualVersion == expectedVersion
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard
            let candidateComponents = versionComponents(normalizedVersionString(candidate)),
            let currentComponents = versionComponents(normalizedVersionString(current))
        else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    static func isExpectedThinArchitecture(
        reportedArchitectures: String,
        expectedArchitecture: String
    ) -> Bool {
        guard expectedArchitecture == "arm64" || expectedArchitecture == "x86_64" else {
            return false
        }

        let architectures = reportedArchitectures
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return architectures == [expectedArchitecture]
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let components = version.components(separatedBy: ".")
        guard !components.isEmpty else {
            return nil
        }

        var values: [Int] = []
        values.reserveCapacity(components.count)
        for component in components {
            guard
                !component.isEmpty,
                component.allSatisfy(\.isNumber),
                let value = Int(component),
                value >= 0
            else {
                return nil
            }
            values.append(value)
        }
        return values
    }
}
