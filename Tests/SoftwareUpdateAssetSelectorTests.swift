import Foundation

@main
struct SoftwareUpdateAssetSelectorTests {
    static func main() {
        testAssetOrderDoesNotMatter()
        testUnrelatedDMGsAreIgnored()
        testMissingArchitectureFailsSafely()
        testThinArchitectureMustMatchExactly()
        print("SoftwareUpdateAssetSelector tests passed")
    }

    private static func testAssetOrderDoesNotMatter() {
        let assets = [
            "Y-Clip-v1.0.18-x86_64.dmg",
            "release-notes.txt",
            "Y-Clip-v1.0.18-arm64.dmg"
        ]

        let selected = SoftwareUpdateAssetSelector.selectAssetName(
            from: assets,
            releaseVersion: "v1.0.18",
            architecture: "arm64"
        )
        expect(selected == "Y-Clip-v1.0.18-arm64.dmg", "应按完整名称选择 arm64 资产，与资产顺序无关")
    }

    private static func testUnrelatedDMGsAreIgnored() {
        let assets = [
            "Y-Clip-v1.0.18.dmg",
            "Other-App-v1.0.18-x86_64.dmg",
            "Y-Clip-v1.0.18-arm64.dmg",
            "Y-Clip-v1.0.18-x86_64.dmg"
        ]

        let selected = SoftwareUpdateAssetSelector.selectAssetName(
            from: assets,
            releaseVersion: "1.0.18",
            architecture: "x86_64"
        )
        expect(selected == "Y-Clip-v1.0.18-x86_64.dmg", "不应选择无架构或其他产品的 DMG")
    }

    private static func testMissingArchitectureFailsSafely() {
        let assets = [
            "Y-Clip-v1.0.18-x86_64.dmg",
            "Y-Clip-v1.0.18.dmg",
            "unrelated.dmg"
        ]

        let selected = SoftwareUpdateAssetSelector.selectAssetName(
            from: assets,
            releaseVersion: "v1.0.18",
            architecture: "arm64"
        )
        expect(selected == nil, "缺少当前架构资产时必须返回 nil")
    }

    private static func testThinArchitectureMustMatchExactly() {
        expect(
            SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
                reportedArchitectures: "arm64\n",
                expectedArchitecture: "arm64"
            ),
            "单一 arm64 架构应通过"
        )
        expect(
            SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
                reportedArchitectures: "x86_64",
                expectedArchitecture: "x86_64"
            ),
            "单一 x86_64 架构应通过"
        )
        expect(
            !SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
                reportedArchitectures: "x86_64",
                expectedArchitecture: "arm64"
            ),
            "架构不匹配时必须失败"
        )
        expect(
            !SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
                reportedArchitectures: "arm64 x86_64",
                expectedArchitecture: "arm64"
            ),
            "universal binary 必须失败"
        )
        expect(
            !SoftwareUpdateAssetSelector.isExpectedThinArchitecture(
                reportedArchitectures: "",
                expectedArchitecture: "arm64"
            ),
            "无法读取架构时必须失败"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
