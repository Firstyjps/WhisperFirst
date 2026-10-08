// swift-tools-version: 5.10
// WhisperFirst — พิมพ์ด้วยเสียงภาษาไทยแบบ Wispr Flow (แอป menu bar)
// Launcher (ตัวแอป แทบไม่เปลี่ยน — macOS ผูกสิทธิ์ไมค์/Accessibility ไว้กับตัวนี้) + WhisperFirstCore (dylib โค้ดจริง)
import PackageDescription

let package = Package(
    name: "WhisperFirst",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperFirstCore", type: .dynamic, targets: ["WhisperFirstCore"]),
        .executable(name: "WhisperFirst", targets: ["Launcher"]),
        .executable(name: "wf", targets: ["CLI"]),
    ],
    targets: [
        .target(name: "ObjCTry", path: "Sources/ObjCTry"),   // ดัก NSException จาก AVAudioEngine (Swift จับไม่ได้)
        .target(name: "WhisperFirstCore", dependencies: ["ObjCTry"], path: "Sources/Core"),
        .executableTarget(name: "Launcher", path: "Sources/Launcher"),
        .executableTarget(name: "CLI", dependencies: ["WhisperFirstCore"], path: "Sources/CLI"),   // ทดสอบ engine จากไฟล์เสียง
    ]
)
