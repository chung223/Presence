import AppKit
import AVFoundation
import ScreenCaptureKit

// 只錄一個視窗（其他視窗、通知、游標都不會入鏡）：winrec <視窗編號> <秒數> <輸出.mov>
final class Done: NSObject, SCRecordingOutputDelegate {
    let finished = DispatchSemaphore(value: 0)
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished.signal() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        FileHandle.standardError.write("recording failed: \(error)\n".data(using: .utf8)!)
        finished.signal()
    }
}

// 命令列工具要先初始化視窗伺服器連線，ScreenCaptureKit 才能用
_ = NSApplication.shared
let args = CommandLine.arguments
let windowID = CGWindowID(args[1])!
let seconds = Double(args[2])!
let url = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: url)

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
    FileHandle.standardError.write("window \(windowID) not found\n".data(using: .utf8)!)
    exit(1)
}
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.width = Int(window.frame.width * 2)
config.height = Int(window.frame.height * 2)
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.showsCursor = false
config.ignoreShadowsSingleWindow = true

let stream = SCStream(filter: filter, configuration: config, delegate: nil)
let output = SCRecordingOutputConfiguration()
output.outputURL = url
output.outputFileType = .mov
output.videoCodecType = .h264
let done = Done()
let recording = SCRecordingOutput(configuration: output, delegate: done)
try stream.addRecordingOutput(recording)
try await stream.startCapture()
print("recording \(Int(window.frame.width))x\(Int(window.frame.height)) for \(seconds)s")
try await Task.sleep(for: .seconds(seconds))
try await stream.stopCapture()
_ = done.finished.wait(timeout: .now() + 10)
print("saved \(url.path)")
