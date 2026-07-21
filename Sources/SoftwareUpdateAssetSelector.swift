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

    static func expectedAssetName(releaseVersion: String, architecture: String) -> String? {
        guard architecture == "arm64" || architecture == "x86_64" else {
            return nil
        }

        let version = releaseVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty else {
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
}
