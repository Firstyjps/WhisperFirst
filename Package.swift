// swift-tools-version: 5.10
// WhisperFirst — พิมพ์ด้วยเสียงภาษาไทยแบบ Wispr Flow (แอป menu bar)
// Launcher (จุดเข้าของแอป) ลิงก์ WhisperFirstCore แบบ static → ทั้งแอปเป็นไฟล์เดียว sign ด้วยใบรับรองในเครื่อง + hardened runtime
import PackageDescription

let package = Package(
    name: "WhisperFirst",
    platforms: [.macOS("14.2")],   // CATapDescription (หยุดเพลงบนลำโพงจอ) มีตั้งแต่ 14.2 — ลิงก์แบบ strong
    products: [
        .executable(name: "WhisperFirst", targets: ["Launcher"]),
        .executable(name: "wf", targets: ["CLI"]),
    ],
    targets: [
        .target(name: "ObjCTry", path: "Sources/ObjCTry"),   // ดัก NSException จาก AVAudioEngine (Swift จับไม่ได้)
        .target(name: "WhisperFirstCore", dependencies: ["ObjCTry"], path: "Sources/Core"),
        .executableTarget(name: "Launcher", dependencies: ["WhisperFirstCore"], path: "Sources/Launcher"),
        .executableTarget(name: "CLI", dependencies: ["WhisperFirstCore"], path: "Sources/CLI"),   // ทดสอบ engine จากไฟล์เสียง
    ]
)
