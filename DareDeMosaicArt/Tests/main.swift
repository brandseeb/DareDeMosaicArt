import Foundation

// LabColor, MosaicTile, ColorMission, MosaicProject, MosaicEngine をロードしてテスト実行
runVerification()
runStoreKitVerification()
runPhase2Verification()
if CommandLine.arguments.contains("--large-benchmark") {
    runPerformanceVerification(photoCount: 50_000)
} else if CommandLine.arguments.contains("--benchmark") {
    runPerformanceVerification()
}
