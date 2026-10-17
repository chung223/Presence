import AudioToolbox
import CoreAudio
import PresenceLink

/// Mac 的系統音量（目前的聲音輸出），給手機的簡報畫面調：簡報裡的影片太大聲或太小聲時用。
///
/// 直接用 CoreAudio 調，不模擬鍵盤的音量鍵：投影畫面上不會跳出音量圖示，也不需要輔助使用權限。
/// 接 HDMI 的電視、投影機常常不能從 Mac 調音量（系統的音量鍵也沒用），這時 `adjustable` 是 false。
enum SystemVolume {
    /// 目前的音量；找不到聲音輸出是 nil。
    static var current: MacVolume? {
        guard let device = outputDevice else { return nil }
        let level: Float32? = get(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device)
        let mute: UInt32? = get(kAudioDevicePropertyMute, of: device)
        // 沒有靜音開關的裝置用音量 0 代替（見 change）
        let muted = mute.map { $0 != 0 } ?? (level == 0)
        return MacVolume(level: Double(level ?? 0), muted: muted,
                         adjustable: settable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device))
    }

    /// 沒有靜音開關的裝置：靜音前的音量，取消靜音時調回來。
    private static var levelBeforeMute: Float32?

    /// 做不到（聲音輸出不能調）時回傳 false。
    static func change(_ change: VolumeChange) -> Bool {
        guard let device = outputDevice, let volume = current else { return false }
        let main = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        let hasMute = settable(kAudioDevicePropertyMute, of: device)
        switch change {
        case .set(let level):
            guard volume.adjustable, set(main, Float32(min(max(level, 0), 1)), of: device) else { return false }
            // 跟鍵盤的音量鍵一樣：調大聲就取消靜音
            if level > 0, hasMute { _ = set(kAudioDevicePropertyMute, UInt32(0), of: device) }
        case .step(let up):
            // 一格 1/16，跟鍵盤的音量鍵一樣
            let steps = (volume.level * 16).rounded() + (up ? 1 : -1)
            return self.change(.set(min(max(steps, 0), 16) / 16))
        case .mute(let muted):
            if hasMute { return set(kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), of: device) }
            guard volume.adjustable else { return false }
            if muted {
                levelBeforeMute = Float32(volume.level)
                return set(main, 0, of: device)
            }
            defer { levelBeforeMute = nil }
            return set(main, levelBeforeMute ?? 0.5, of: device)
        }
        return true
    }

    // MARK: - CoreAudio

    private static var outputDevice: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: Numeric & BitwiseCopyable>(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> T? {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func settable(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func set<T: Numeric & BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ value: T, of device: AudioObjectID) -> Bool {
        guard settable(selector, of: device) else { return false }
        var address = address(selector)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
