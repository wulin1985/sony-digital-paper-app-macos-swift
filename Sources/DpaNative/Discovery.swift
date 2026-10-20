//
// Discovery.swift
// Bonjour 发现 _digitalpaper._tcp（对应原版 mw-discovery-ctrl）
//

import Foundation
import Network

final class DiscoveryAgent: ObservableObject, @unchecked Sendable {

    struct Device: Identifiable, Equatable {
        let id: String       // 服务实例名
        let hostName: String
        let port: Int
        var isOnline: Bool = true
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var browsing = false

    private var browser: NWBrowser?

    /// 实际连接地址固定用 digitalpaper.local（设备固定 mDNS 名，与 cookie 域一致）
    static let connectionHost = DPTClient.deviceHost

    func start() {
        guard browser == nil else { return }
        browsing = true
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_digitalpaper._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Device] = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return Device(id: name, hostName: name, port: 8443)
                }
                return nil
            }
            DispatchQueue.main.async {
                self?.devices = found
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.browsing = (state == .ready)
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        browsing = false
        devices = []
    }
}
