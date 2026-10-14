import CoreAudio
import Foundation

/// 鎖定時暫停播放、解鎖後繼續。
///
/// macOS 15.4 起第三方 App 讀不到 MediaRemote 的播放狀態，但送出暫停與播放指令仍然有效（在 macOS 26.7 驗證過）。
/// 所以改用 CoreAudio 判斷「預設輸出裝置有沒有在出聲」。
enum MediaControl {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    static func isAudioPlaying() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func pause() {
        if Demo.isActive { return }
        _ = sendCommand?(1, nil) // kMRPause
    }

    static func play() {
        if Demo.isActive { return }
        _ = sendCommand?(0, nil) // kMRPlay
    }
}
