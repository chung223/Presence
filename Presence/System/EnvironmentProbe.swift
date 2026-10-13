import CoreWLAN
import Foundation
import IOKit.ps
import SystemConfiguration

/// 目前連上的網路。用路由器的硬體位址辨識，不需要任何權限；
/// Wi-Fi 名稱要有定位權限才讀得到，讀不到就是 nil，只拿來當預設名稱。
///
/// 不能用系統的「預設路由器」：開著 Surge 之類的代理或 VPN 時，那是虛擬網卡（utun）的位址。
/// 所以逐一看每個網路服務，只取實體網卡（en 開頭）的路由器。
enum NetworkIdentity {
    struct Current: Equatable {
        let id: String
        let ssid: String?
        /// 路由器用的是共用的虛擬位址（VRRP、HSRP、GLBP），不同地方的網路可能相同。
        let isShared: Bool
    }

    /// 企業、學校、旅館常見的虛擬路由器位址前綴；不同網路常用同一組。
    private static let sharedPrefixes = ["00:00:5e:00:01", "00:00:5e:00:02", "00:00:0c:07:ac", "00:00:0c:9f:f", "00:07:b4:00:01"]

    static func current() async -> Current? {
        guard let store = SCDynamicStoreCreate(nil, "Presence" as CFString, nil, nil) else { return nil }
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        let wifiInterface = CWWiFiClient.shared().interface()

        var candidates: [(interface: String, router: String?, mac: String?)] = []
        for key in keys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = dict["InterfaceName"] as? String, interface.hasPrefix("en") else { continue }
            let router = dict["Router"] as? String
            // 例如 "IPv4.Router=10.0.0.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff"
            let signature = dict["NetworkSignature"] as? String ?? ""
            let mac = signature.split(separator: ";")
                .first { $0.hasPrefix("IPv4.RouterHardwareAddress=") }
                .map { String($0.dropFirst("IPv4.RouterHardwareAddress=".count)) }
            if router != nil || mac != nil { candidates.append((interface, router, mac)) }
        }
        // Wi-Fi 優先，其次依介面名稱排序
        candidates.sort { a, b in
            if (a.interface == wifiInterface?.interfaceName) != (b.interface == wifiInterface?.interfaceName) {
                return a.interface == wifiInterface?.interfaceName
            }
            return a.interface < b.interface
        }
        for candidate in candidates {
            var mac = candidate.mac.flatMap(normalize)
            if mac == nil, let router = candidate.router { mac = await arpLookup(router, interface: candidate.interface) }
            if let mac {
                let ssid = candidate.interface == wifiInterface?.interfaceName ? wifiInterface?.ssid() : nil
                // 共用位址再加上路由器 IP，降低跟其他地方的網路撞在一起的機會
                let shared = sharedPrefixes.contains { mac.hasPrefix($0) }
                let id = shared ? "\(mac)@\(candidate.router ?? "")" : mac
                return Current(id: id, ssid: ssid, isShared: shared)
            }
        }
        return nil
    }

    /// 統一成小寫、每段兩位數；格式不對就回傳 nil。
    private static func normalize(_ raw: String) -> String? {
        let parts = raw.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
    }

    /// 網路簽章裡沒有硬體位址時，改從 ARP 表查：`arp -n 192.168.1.1` → `? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 …`
    private static func arpLookup(_ ip: String, interface: String) async -> String? {
        let output = await Task.detached { () -> String? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-n", "-i", interface, ip]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
        guard let output, let range = output.range(of: " at ") else { return nil }
        return normalize(String(output[range.upperBound...].prefix { !$0.isWhitespace }))
    }
}

enum PowerSource {
    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// 是否接著電源；沒有電池的 Mac 回傳 nil（這個條件對它沒有意義）。
    static var isOnACPower: Bool? {
        guard hasBattery, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == kIOPMACPowerKey
    }
}
