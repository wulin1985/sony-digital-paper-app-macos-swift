//
// DPTClient.swift
// Sony Digital Paper (DPT-RP1) 原生客户端：认证 + REST API
//
// 协议要素（源自 Sony Digital Paper App 1.4.7 逆向，详见 dpa-analysis/）：
//   - 设备 WebAPI: https://digitalpaper.local:8443（自签名证书）
//   - 认证: GET /auth/nonce/<deviceId> → RSA-SHA256 签名 nonce →
//           PUT /auth {client_id, nonce_signed(base64)} → 204 + Set-Cookie Credentials
//   - 配对密钥: ~/.../DigitalPaperApp/<ws-id>/ {deviceid.dat, privatekey.dat(PKCS#1 PEM)}
//   - 根目录: folder id = "root"
//

import Foundation
import Security

// MARK: - 错误

enum DPTError: LocalizedError {
    case keysNotLoaded
    case authFailed(String)
    case badStatus(Int, String)
    case apiError(String, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .keysNotLoaded:
            return "配对密钥未加载（找不到 deviceid.dat / privatekey.dat）"
        case .authFailed(let why):
            return "认证失败: \(why)"
        case .badStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(160))"
        case .apiError(let code, let message):
            return "设备错误 \(code): \(message)"
        case .invalidResponse:
            return "设备响应无法解析"
        }
    }
}

// MARK: - 数据模型

struct DPEntry: Identifiable, Hashable {
    var id: String { entryId ?? UUID().uuidString }
    var entryId: String?      // document_id / folder_id
    var entryType: String     // "document" | "folder"
    var entryName: String
    var parentFolderId: String?
    var modifiedDate: String?
    var fileSize: Int?
    var entryPath: String?    // 如 "Document/Books"
    var createdDate: String?

    var isFolder: Bool { entryType == "folder" }
}

struct DPDocumentInfo: Codable {
    let document_id: String?
    let file_name: String?
    let file_size: String?
    let modified_date: String?
    let parent_folder_id: String?
}

// MARK: - 客户端

final class DPTClient: NSObject, URLSessionDelegate, @unchecked Sendable {

    static let deviceHost = "digitalpaper.local"
    static let httpsPort = 8443

    private(set) var baseURL: URL
    private lazy var session: URLSession = self.makeSession()

    // 配对身份
    private(set) var deviceId: String?
    private var privateKey: SecKey?

    // 认证状态
    private(set) var isAuthed = false

    override init() {
        self.baseURL = URL(string: "https://\(DPTClient.deviceHost):\(DPTClient.httpsPort)")!
        super.init()
    }

    convenience init(host: String) {
        self.init()
        self.baseURL = URL(string: "https://\(host):\(DPTClient.httpsPort)")!
    }

    // MARK: URLSession（放行设备自签名证书）

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = true       // 原生客户端无 SameSite 限制，自动管理 Credentials cookie
        config.httpCookieAcceptPolicy = .always
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        return s
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 设备使用自签名证书（配对时已交换），直接信任
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: 密钥加载

    /// 解析 Sony app 的 workspace 目录（含配对密钥）
    static func defaultWorkspace() -> String? {
        if let env = ProcessInfo.processInfo.environment["DPA_WORKSPACE"], !env.isEmpty {
            return env
        }
        let home = NSHomeDirectory()
        let base = "\(home)/Library/Application Support/Sony Corporation/Digital Paper App/DigitalPaperApp"
        guard FileManager.default.fileExists(atPath: base) else { return nil }
        // 优先 lastworkspaceid.dat
        let last = try? String(contentsOfFile: base + "/lastworkspaceid.dat", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = last, !last.isEmpty,
           FileManager.default.fileExists(atPath: base + "/" + last + "/deviceid.dat") {
            return base + "/" + last
        }
        // 兜底：扫描 ws* 目录
        if let items = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for item in items where item.hasPrefix("ws") {
                let candidate = base + "/" + item
                if FileManager.default.fileExists(atPath: candidate + "/deviceid.dat") {
                    return candidate
                }
            }
        }
        return nil
    }

    @discardableResult
    func loadKeys(workspace: String) throws -> String {
        let deviceIdPath = workspace + "/deviceid.dat"
        let privKeyPath = workspace + "/privatekey.dat"

        guard let rawId = try? String(contentsOfFile: deviceIdPath, encoding: .utf8) else {
            throw DPTError.keysNotLoaded
        }
        let devId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard devId.count == 36 else {
            throw DPTError.keysNotLoaded
        }

        guard let pem = try? String(contentsOfFile: privKeyPath, encoding: .utf8),
              let key = DPTClient.importPrivateKey(pem: pem) else {
            throw DPTError.keysNotLoaded
        }

        self.deviceId = devId
        self.privateKey = key
        self.isAuthed = false
        return devId
    }

    /// PKCS#1 PEM ("BEGIN RSA PRIVATE KEY") → SecKey
    static func importPrivateKey(pem: String) -> SecKey? {
        let lines = pem.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let body = lines.filter { !$0.isEmpty && !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error)
        return key
    }

    // MARK: HTTP 基础

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         contentType: String? = nil) -> URLRequest {
        // 注意：不能用 appendingPathComponent 构造含 query 的 URL——
        // 它会把 "?" 编码为 %3F，导致 query 变成路径的一部分（上传 PUT file 必 404）。
        // 含 "?" 的 path 在此拆分：路径部分用 appendingPathComponent（保留尾斜杠，
        // POST /documents/ 依赖此行为），query 部分交给 URLComponents。
        let url: URL
        if let qIdx = path.firstIndex(of: "?") {
            let pathPart = String(path[..<qIdx])
            let queryPart = String(path[path.index(after: qIdx)...])
            var comp = URLComponents(url: baseURL.appendingPathComponent(pathPart),
                                     resolvingAgainstBaseURL: false)!
            comp.percentEncodedQuery = queryPart
            url = comp.url!
        } else {
            url = baseURL.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body = body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest, expected: [Int] = [200]) async throws -> (Data, HTTPURLResponse) {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DPTError.authFailed(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw DPTError.invalidResponse }
        if !expected.contains(http.statusCode) {
            // 设备错误 JSON: {"error_code": "...", "message": "..."}
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ec = obj["error_code"] as? String, let msg = obj["message"] as? String {
                throw DPTError.apiError(ec, msg)
            }
            throw DPTError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    // MARK: 认证

    /// GET /auth/nonce → RSA-SHA256 签名 → PUT /auth（期望 204，Set-Cookie Credentials 由 URLSession 自动管理）
    func authenticate() async throws {
        guard let deviceId = deviceId, let privateKey = privateKey else {
            throw DPTError.keysNotLoaded
        }

        // 1. nonce
        let (data, http) = try await send(request("GET", "auth/nonce/\(deviceId)"), expected: [200])
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = obj["nonce"] as? String, !nonce.isEmpty else {
            throw DPTError.authFailed("nonce 获取失败")
        }

        // 2. 签名（RSA PKCS1v15-SHA256，对 nonce 的 ASCII 字节）
        guard let nonceData = nonce.data(using: .utf8) else {
            throw DPTError.authFailed("nonce 编码失败")
        }
        var sigError: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey,
                                              .rsaSignatureMessagePKCS1v15SHA256,
                                              nonceData as CFData,
                                              &sigError) else {
            throw DPTError.authFailed("签名失败: \(sigError.map { $0.takeRetainedValue().localizedDescription } ?? "?")")
        }

        // 3. PUT /auth
        let authBody: [String: Any] = [
            "client_id": deviceId,
            "nonce_signed": (sig as Data).base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: authBody)
        let (_, putResp) = try await send(request("PUT", "auth", body: body), expected: [204])
        _ = putResp
        self.isAuthed = true
    }

    /// 确保已认证（401 时自动重试一次）
    private func ensureAuthed(_ op: String = "") async throws {
        if !isAuthed {
            try await authenticate()
        }
    }

    func reauthAndRetry(_ block: () async throws -> Void) async throws {
        do { try await block() }
        catch DPTError.apiError(let code, _) where code == "40100" || code == "40101" {
            isAuthed = false
            try await authenticate()
            try await block()
        }
    }

    // MARK: API - 系统信息

    func ownerName() async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/configs/owner"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let v = obj["value"] as? String else { throw DPTError.invalidResponse }
            return v
        }
    }

    func storageInfo() async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/status/storage"), expected: [200])
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: API - 目录

    /// 列出文件夹内容（默认根目录 "root"）
    func listEntries(folderId: String = "root") async throws -> [DPEntry] {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(
                self.request("GET", "folders/\(folderId)/entries"), expected: [200])
            // 设备实际返回包裹结构: {"count":N, "entry_list":[...]}；兼容裸数组兜底
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                throw DPTError.invalidResponse
            }
            let arr: [[String: Any]]
            if let wrapped = obj as? [String: Any], let list = wrapped["entry_list"] as? [[String: Any]] {
                arr = list
            } else if let bare = obj as? [[String: Any]] {
                arr = bare
            } else {
                throw DPTError.invalidResponse
            }
            return arr.map { DPTClient.parseEntry($0) }
        }
    }

    static func parseEntry(_ obj: [String: Any]) -> DPEntry {
        let type = (obj["entry_type"] as? String) ?? "document"
        let entryId = (obj["document_id"] as? String) ?? (obj["folder_id"] as? String) ?? (obj["entry_id"] as? String)
        let name = (obj["entry_name"] as? String)
            ?? (obj["file_name"] as? String)
            ?? (obj["folder_name"] as? String)
            ?? "（未命名）"
        let sizeStr = obj["file_size"] as? String
        return DPEntry(entryId: entryId,
                       entryType: type,
                       entryName: name,
                       parentFolderId: obj["parent_folder_id"] as? String,
                       modifiedDate: obj["modified_date"] as? String ?? obj["created_date"] as? String,
                       fileSize: sizeStr.flatMap(Int.init),
                       entryPath: obj["entry_path"] as? String,
                       createdDate: obj["created_date"] as? String)
    }

    // MARK: API - 文档

    /// 上传 PDF：POST /documents/ 建条目 → PUT /documents/{id}/file 传文件
    func uploadPDF(fileURL: URL, parentFolderId: String = "root") async throws -> String {
        try await ensureAuthed()
        let fileName = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)

        return try await reauth {
            // 1. 创建文档条目
            let meta: [String: Any] = [
                "parent_folder_id": parentFolderId,
                "file_name": fileName,
                "document_source": ""
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            let (data, _) = try await self.send(
                self.request("POST", "documents/", body: metaData), expected: [200, 201])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docId = obj["document_id"] as? String else {
                throw DPTError.invalidResponse
            }

            // 2. multipart 上传文件体（单请求，offset=0, total=size）
            let boundary = "DpaNative-\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var req = self.request("PUT", "documents/\(docId)/file?offset_bytes=0&total_bytes=\(fileData.count)",
                                   body: body,
                                   contentType: "multipart/form-data; boundary=\(boundary)")
            req.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
            _ = try await self.send(req, expected: [200, 201, 204])
            return docId
        }
    }

    /// 下载文档到本地
    func downloadFile(documentId: String, to destURL: URL) async throws {
        try await ensureAuthed()
        try await reauth {
            let (data, _) = try await self.send(
                self.request("GET", "documents/\(documentId)/file"), expected: [200, 206])
            try data.write(to: destURL)
        }
    }

    /// 删除文档
    func deleteDocument(documentId: String) async throws {
        try await ensureAuthed()
        try await reauth {
            _ = try await self.send(self.request("DELETE", "documents/\(documentId)"), expected: [200, 204])
        }
    }

    /// 删除文件夹
    func deleteFolder(folderId: String) async throws {
        try await ensureAuthed()
        try await reauth {
            _ = try await self.send(self.request("DELETE", "folders/\(folderId)"), expected: [200, 204])
        }
    }

    /// 创建文件夹
    func createFolder(name: String, parentFolderId: String = "root") async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let meta: [String: Any] = ["parent_folder_id": parentFolderId, "folder_name": name]
            let body = try JSONSerialization.data(withJSONObject: meta)
            let (data, _) = try await self.send(self.request("POST", "folders", body: body), expected: [200, 201])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fid = obj["folder_id"] as? String else { throw DPTError.invalidResponse }
            return fid
        }
    }

    // MARK: API - 重命名 / 移动（P1）
    // 协议（EntityModel.js sync UPDATE）：PUT /documents/{id} body {file_name?, parent_folder_id?}
    //                              PUT /folders/{id}   body {folder_name?, parent_folder_id?}
    // 期望 204；重名冲突 = 400 / error_code 40007

    /// 重命名文档（保持扩展名是调用方责任，设备按 file_name 原样存储）
    func renameDocument(documentId: String, newName: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let body = try JSONSerialization.data(withJSONObject: ["file_name": newName])
            _ = try await self.send(self.request("PUT", "documents/\(documentId)", body: body), expected: [204])
        }
    }

    /// 重命名文件夹
    func renameFolder(folderId: String, newName: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let body = try JSONSerialization.data(withJSONObject: ["folder_name": newName])
            _ = try await self.send(self.request("PUT", "folders/\(folderId)", body: body), expected: [204])
        }
    }

    /// 移动文档到目标文件夹
    func moveDocument(documentId: String, toFolderId: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let body = try JSONSerialization.data(withJSONObject: ["parent_folder_id": toFolderId])
            _ = try await self.send(self.request("PUT", "documents/\(documentId)", body: body), expected: [204])
        }
    }

    /// 移动文件夹到目标文件夹（设备端会拒绝移动到自身子目录）
    func moveFolder(folderId: String, toFolderId: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let body = try JSONSerialization.data(withJSONObject: ["parent_folder_id": toFolderId])
            _ = try await self.send(self.request("PUT", "folders/\(folderId)", body: body), expected: [204])
        }
    }

    // MARK: API - 设备信息 / 配置（P1）
    // 协议：GET /system/status/* → {"value": ...}；GET /system/configs → 聚合对象；
    //       PUT /system/configs/{key} body {"value": "..."} → 204

    struct DeviceInfo {
        var firmwareVersion: String?
        var modelName: String?
        var macAddress: String?
        var owner: String?
        var storageRaw: String?
    }

    /// 设备信息（固件版本 / 型号 / MAC）
    func fetchDeviceInfo() async throws -> DeviceInfo {
        try await ensureAuthed()
        return try await reauth {
            var info = DeviceInfo()
            if let (data, _) = try? await self.send(self.request("GET", "system/status/firmware_version"), expected: [200]),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.firmwareVersion = obj["value"] as? String
                info.modelName = obj["model_name"] as? String
            }
            if let (data, _) = try? await self.send(self.request("GET", "system/status/mac_address"), expected: [200]),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.macAddress = obj["value"] as? String
            }
            if let (data, _) = try? await self.send(self.request("GET", "system/status/storage"), expected: [200]) {
                info.storageRaw = String(data: data, encoding: .utf8)
            }
            if let (data, _) = try? await self.send(self.request("GET", "system/configs/owner"), expected: [200]),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.owner = obj["value"] as? String
            }
            return info
        }
    }

    struct DeviceConfigs {
        var timezone: String?
        var dateFormat: String?
        var timeFormat: String?
        var timeoutToStandby: String?
        var owner: String?
    }

    /// 读取设备配置聚合（GET /system/configs，每项 {"value": ...}）
    func fetchConfigs() async throws -> DeviceConfigs {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/configs"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DPTError.invalidResponse
            }
            func val(_ keys: [String]) -> String? {
                for k in keys {
                    if let v = obj[k] as? [String: Any], let s = v["value"] as? String { return s }
                }
                return nil
            }
            // 兼容 timezone / time_zone 两种键名（stub 用 time_zone，真机聚合响应用 timezone）
            return DeviceConfigs(timezone: val(["timezone", "time_zone"]),
                                 dateFormat: val(["date_format"]),
                                 timeFormat: val(["time_format"]),
                                 timeoutToStandby: val(["timeout_to_standby"]),
                                 owner: val(["owner"]))
        }
    }

    /// 修改单项设备配置（PUT /system/configs/{key} {"value": v} → 204）
    func updateConfig(key: String, value: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let body = try JSONSerialization.data(withJSONObject: ["value": value])
            _ = try await self.send(self.request("PUT", "system/configs/\(key)", body: body), expected: [204])
        }
    }

    // MARK: API - WiFi（P2）
    // 协议（源自 Electron 逆向，注意：ssid 全程 base64 编码传输）：
    //   POST /system/controls/wifi_accesspoints/scan   → {"aplist":[{ssid(b64),security,state,frequency_band,rssi_level}]}
    //   GET  /system/status/wifi_state                  → {ssid(b64),state,...}
    //   GET  /system/configs/wifi_accesspoints          → {"aplist":[已保存配置]}
    //   PUT  /system/controls/wifi_accesspoints/register → body 全量配置(ssid=b64) → 204
    //   DELETE /system/configs/wifi_accesspoints/{b64ssid}/{security} → 204
    //   PUT wps_start/button(204) / wps_start/pin(200, 返回 PIN) / wps_cancel(204)
    //   GET  /system/status/wps_state → {"value": state}

    struct WiFiAP: Identifiable, Hashable {
        var id: String { "\(ssid)-\(security)" }
        var ssid: String           // 已解码
        var security: String       // nonsec | psk | eap
        var state: String?         // none|connecting|connected|saved|disabled（扫描结果）
        var frequencyBand: String? // 2.4ghz | 5ghz
        var rssiLevel: Int?
    }

    private static func decodeSSID(_ b64: String?) -> String {
        guard let b64 = b64, let d = Data(base64Encoded: b64) else { return b64 ?? "" }
        return String(data: d, encoding: .utf8) ?? b64
    }

    private static func parseAP(_ obj: [String: Any]) -> WiFiAP {
        WiFiAP(ssid: decodeSSID(obj["ssid"] as? String),
               security: (obj["security"] as? String) ?? "",
               state: obj["state"] as? String,
               frequencyBand: obj["frequency_band"] as? String,
               rssiLevel: (obj["rssi_level"] as? String).flatMap(Int.init) ?? (obj["rssi_level"] as? Int))
    }

    /// 扫描周围 WiFi（耗时约 5-15 秒，设备端扫描）
    func scanWiFi() async throws -> [WiFiAP] {
        try await ensureAuthed()
        return try await reauth {
            var req = self.request("POST", "system/controls/wifi_accesspoints/scan")
            req.timeoutInterval = 45
            let (data, _) = try await self.send(req, expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["aplist"] as? [[String: Any]] else {
                throw DPTError.invalidResponse
            }
            return list.map { DPTClient.parseAP($0) }
        }
    }

    /// WiFi 开关状态（GET /system/configs/wifi → {"value":"on"|"off"}；PUT 同路径切换）
    func wifiConfig() async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/configs/wifi"), expected: [200])
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (obj["value"] as? String) ?? ""
        }
    }

    /// 当前 WiFi 连接状态
    func wifiState() async throws -> WiFiAP? {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/status/wifi_state"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DPTError.invalidResponse
            }
            return DPTClient.parseAP(obj)
        }
    }

    /// 已保存的 WiFi 配置列表
    func registeredWiFi() async throws -> [WiFiAP] {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/configs/wifi_accesspoints"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["aplist"] as? [[String: Any]] else {
                // 兼容裸数组
                if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return list.map { DPTClient.parseAP($0) }
                }
                throw DPTError.invalidResponse
            }
            return list.map { DPTClient.parseAP($0) }
        }
    }

    /// 注册（连接）一个 PSK 网络。body 结构对齐 Electron model.toJSON() 全量字段
    func registerWiFi(ssid: String, passwd: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let b64 = Data(ssid.utf8).base64EncodedString()
            let body: [String: Any] = [
                "ssid": b64,
                "security": "psk",
                "passwd": passwd,
                "dhcp": "on",
                "static_address": "", "gateway": "", "network_mask": "",
                "dns1": "", "dns2": "",
                "proxy": "", "proxy_host": "", "proxy_port": "",
                "eap": "", "eap_phase2": "", "eap_id": "", "eap_anid": "",
                "eap_cacert": "", "eap_cert": ""
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await self.send(self.request("PUT", "system/controls/wifi_accesspoints/register", body: data), expected: [204])
        }
    }

    /// 删除已保存的 WiFi 配置
    func deleteWiFiConfig(ssid: String, security: String) async throws {
        try await ensureAuthed()
        try await reauth {
            let b64 = Data(ssid.utf8).base64EncodedString()
            let enc = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
            _ = try await self.send(self.request("DELETE", "system/configs/wifi_accesspoints/\(enc)/\(security)"), expected: [204])
        }
    }

    /// WPS 按钮方式接入
    func wpsStartButton() async throws {
        try await ensureAuthed()
        try await reauth {
            _ = try await self.send(self.request("PUT", "system/controls/wps_start/button"), expected: [204])
        }
    }

    /// WPS PIN 方式接入，返回设备生成的 PIN 码
    func wpsStartPin() async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("PUT", "system/controls/wps_start/pin"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pin = obj["value"] as? String else { throw DPTError.invalidResponse }
            return pin
        }
    }

    /// 取消 WPS
    func wpsCancel() async throws {
        try await ensureAuthed()
        try await reauth {
            _ = try await self.send(self.request("PUT", "system/controls/wps_cancel"), expected: [204])
        }
    }

    /// WPS 状态（none|in_progress|success|overlap_error|wep_prohibited|tkip_only_prohibited|timed_out）
    func wpsState() async throws -> String {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/status/wps_state"), expected: [200])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let v = obj["value"] as? String else { throw DPTError.invalidResponse }
            return v
        }
    }

    // MARK: API - 截屏（P2）
    // GET /system/controls/screen_shot → PNG 二进制（Electron ScreenshotTaker，responseType=arraybuffer）

    func takeScreenshot() async throws -> Data {
        try await ensureAuthed()
        // 主端点 screen_shot（PNG）；个别状态下挂起，超时后回退 screen_shot2?query=jpeg
        do {
            return try await reauth {
                var req = self.request("GET", "system/controls/screen_shot")
                req.timeoutInterval = 30
                let (data, _) = try await self.send(req, expected: [200])
                return data
            }
        } catch {
            return try await reauth {
                var req = self.request("GET", "system/controls/screen_shot2?query=jpeg")
                req.timeoutInterval = 60
                let (data, _) = try await self.send(req, expected: [200])
                return data
            }
        }
    }

    // MARK: API - 固件升级（P2）
    // 流程：PUT /system/controls/update_firmware/file?offset_bytes=0&total_bytes=N（multipart 'file'）
    //   → GET /system/controls/update_firmware/precheck → {image_file:'ok', battery:'ok'}
    //   → PUT /system/controls/update_firmware → 204（设备重启开始刷机）

    struct FirmwarePrecheck {
        var imageFileOK: Bool
        var batteryOK: Bool
        var raw: String
    }

    func firmwarePrecheck() async throws -> FirmwarePrecheck {
        try await ensureAuthed()
        return try await reauth {
            let (data, _) = try await self.send(self.request("GET", "system/controls/update_firmware/precheck"), expected: [200])
            let raw = String(data: data, encoding: .utf8) ?? ""
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return FirmwarePrecheck(imageFileOK: (obj["image_file"] as? String) == "ok",
                                    batteryOK: (obj["battery"] as? String) == "ok",
                                    raw: raw)
        }
    }

    /// 上传固件文件到设备（不启动刷机）
    func uploadFirmware(fileURL: URL) async throws {
        try await ensureAuthed()
        try await reauth {
            let fileData = try Data(contentsOf: fileURL)
            let boundary = "DpaNative-\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"firmware.bin\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            var req = self.request("PUT", "system/controls/update_firmware/file?offset_bytes=0&total_bytes=\(fileData.count)",
                                   body: body,
                                   contentType: "multipart/form-data; boundary=\(boundary)")
            req.timeoutInterval = 300
            _ = try await self.send(req, expected: [200, 201, 204])
        }
    }

    /// 启动固件升级（设备将重启刷机，务必先 precheck 确认 image_file+battery 均 ok）
    func startFirmwareUpdate() async throws {
        try await ensureAuthed()
        try await reauth {
            _ = try await self.send(self.request("PUT", "system/controls/update_firmware"), expected: [204])
        }
    }

    // 通用重试包装
    private func reauth<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch DPTError.apiError(let code, _) where code == "40100" || code == "40101" {
            isAuthed = false
            try await authenticate()
            return try await block()
        }
    }
}
