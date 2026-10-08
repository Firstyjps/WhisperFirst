import Darwin
import Foundation

// ตัวเปิด WhisperFirst.app — เล็กและแทบไม่เปลี่ยน (macOS ผูกสิทธิ์ไมค์ + Accessibility กับตัวนี้)
// โค้ดจริงอยู่ใน libWhisperFirstCore.dylib → build ใหม่ได้โดยไม่ต้องขอสิทธิ์ใหม่
let path = NSHomeDirectory() + "/Library/Application Support/WhisperFirst/libWhisperFirstCore.dylib"
guard let handle = dlopen(path, RTLD_NOW) else {
    FileHandle.standardError.write("WhisperFirst: โหลด \(path) ไม่ได้: \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(1)
}
guard let sym = dlsym(handle, "whisperfirst_main") else { exit(2) }
typealias Entry = @convention(c) () -> Void
unsafeBitCast(sym, to: Entry.self)()
