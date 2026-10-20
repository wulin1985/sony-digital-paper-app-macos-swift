//
// SmokeTest.swift
// CLI 冒烟/全量验证模式（GUI 之外：DpaNative --smoke / --full / --roundtrip <pdf>)
//

import Foundation

enum SmokeTest {

    static func makeClient() throws -> DPTClient {
        guard let ws = DPTClient.defaultWorkspace() else {
            throw DPTError.keysNotLoaded
        }
        let client = DPTClient()
        let devId = try client.loadKeys(workspace: ws)
        print("[keys] workspace=\(URL(fileURLWithPath: ws).lastPathComponent) client_id=\(devId)")
        return client
    }

    static func makeTestPDF() -> URL {
        // 最小合法 PDF（1 页空白）
        let content = """
        %PDF-1.4
        1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
        2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
        3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]>>endobj
        trailer<</Root 1 0 R>>
        %%EOF
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dpa-native-test-\(Int(Date().timeIntervalSince1970)).pdf")
        try! content.data(using: .utf8)!.write(to: url)
        return url
    }

    /// 核心冒烟：密钥 → 认证 → owner → 根目录列表
    static func smoke() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "✅" : "❌"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }

        do {
            let client = try makeClient()
            do {
                try await client.authenticate()
                check("认证 PUT /auth → 204", true, "client_id 认证成功")
            } catch {
                check("认证", false, error.localizedDescription)
                print("冒烟中止（认证失败后续 API 均不可用）")
                summary(pass: pass, fail: fail)
                return
            }

            if let owner = try? await client.ownerName() {
                check("GET /system/configs/owner", true, "owner=\(owner)")
            } else {
                check("GET /system/configs/owner", false)
            }

            if let storage = try? await client.storageInfo(), !storage.isEmpty {
                check("GET /system/status/storage", true, storage.prefix(80) + "…")
            } else {
                check("GET /system/status/storage", false)
            }

            do {
                let entries = try await client.listEntries(folderId: "root")
                check("GET /folders/root/entries", true, "\(entries.count) 项（folders=\(entries.filter { $0.isFolder }.count), docs=\(entries.filter { !$0.isFolder }.count)）")
                if let first = entries.first {
                    print("   首条: type=\(first.entryType) name=\(first.entryName) id=\(first.entryId ?? "?")")
                }
            } catch {
                check("GET /folders/root/entries", false, error.localizedDescription)
            }
        } catch {
            check("密钥加载", false, error.localizedDescription)
        }
        summary(pass: pass, fail: fail)
    }

    /// 全量验证：冒烟 + 上传 → 列表确认 → 下载 → 内容比对 → 删除 → 删除确认
    static func full(testPDF: URL? = nil) async {
        await smoke()
        print("\n===== Roundtrip（上传→下载→比对→删除）=====")
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "✅" : "❌"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }

        guard let client = try? makeClient() else {
            print("❌ 密钥加载失败，roundtrip 中止")
            summary(pass: pass, fail: fail)
            return
        }

        let pdfURL = testPDF ?? makeTestPDF()
        let fileName = pdfURL.lastPathComponent
        let original = (try? Data(contentsOf: pdfURL)) ?? Data()

        // 1. 上传
        var docId: String?
        do {
            docId = try await client.uploadPDF(fileURL: pdfURL, parentFolderId: "root")
            check("POST /documents/ + PUT file（上传）", true, "document_id=\(docId!) size=\(original.count)B")
        } catch {
            check("上传", false, error.localizedDescription)
            summary(pass: pass, fail: fail)
            return
        }

        // 2. 列表确认
        do {
            let entries = try await client.listEntries(folderId: "root")
            if let found = entries.first(where: { $0.entryId == docId }) {
                check("列表中出现新文档", true, "name=\(found.entryName)")
            } else {
                check("列表中出现新文档", false, "\(fileName) 未出现在根目录列表")
            }
        } catch {
            check("列表复查", false, error.localizedDescription)
        }

        // 3. 下载比对
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dpa-native-download-\(fileName)")
        do {
            try await client.downloadFile(documentId: docId!, to: dest)
            let downloaded = try Data(contentsOf: dest)
            check("GET /documents/{id}/file（下载）", downloaded == original,
                  "大小比对 \(downloaded.count)B vs \(original.count)B")
            try? FileManager.default.removeItem(at: dest)
        } catch {
            check("下载", false, error.localizedDescription)
        }

        // 4. 删除
        do {
            try await client.deleteDocument(documentId: docId!)
            check("DELETE /documents/{id}", true)
            let entries = try await client.listEntries(folderId: "root")
            let gone = !entries.contains { $0.entryId == docId }
            check("删除后列表确认", gone, gone ? "已从设备移除" : "仍出现在列表中！")
        } catch {
            check("删除", false, error.localizedDescription)
        }

        summary(pass: pass, fail: fail)
    }

    private static func summary(pass: Int, fail: Int) {
        print("\n===== 结果: \(pass) 通过 / \(fail) 失败 =====")
        if fail == 0 { print("ALL PASS ✅") } else { print("存在失败项 ❌"); exit(1) }
    }

    // MARK: P1 验证：重命名/移动 roundtrip + 设备信息/配置（全部用临时文件夹，结束后清理）

    static func p1() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "✅" : "❌"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }

        guard let client = try? makeClient() else {
            print("❌ 密钥加载失败"); exit(1)
        }

        // 1. 设备信息
        do {
            let info = try await client.fetchDeviceInfo()
            check("GET /system/status/firmware_version", info.firmwareVersion != nil,
                  "firmware=\(info.firmwareVersion ?? "?") model=\(info.modelName ?? "?")")
            check("GET /system/status/mac_address", info.macAddress != nil, "mac=\(info.macAddress ?? "?")")
        } catch {
            check("设备信息读取", false, error.localizedDescription)
        }

        // 2. 配置聚合 + 原值回写（无副作用验证 PUT）
        do {
            let cfg = try await client.fetchConfigs()
            check("GET /system/configs（聚合）", true,
                  "standby=\(cfg.timeoutToStandby ?? "?") tz=\(cfg.timezone ?? "?") date=\(cfg.dateFormat ?? "?") time=\(cfg.timeFormat ?? "?") owner=\(cfg.owner ?? "?")")
            if let sb = cfg.timeoutToStandby {
                try await client.updateConfig(key: "timeout_to_standby", value: sb)
                check("PUT /system/configs/timeout_to_standby（原值回写）", true, "value=\(sb)")
            }
        } catch {
            check("设备配置读/写", false, error.localizedDescription)
        }

        // 3. 重命名/移动 roundtrip（临时文件夹）
        let stamp = Int(Date().timeIntervalSince1970)
        let f1 = "DpaNative-P1-A-\(stamp)"
        let f1r = "DpaNative-P1-A-rename-\(stamp)"
        let f2 = "DpaNative-P1-B-\(stamp)"
        do {
            let id1 = try await client.createFolder(name: f1, parentFolderId: "root")
            check("POST /folders（建 A）", true, "id=\(id1.prefix(8))…")

            try await client.renameFolder(folderId: id1, newName: f1r)
            check("PUT /folders/{id}（重命名 A）", true, "\(f1) → \(f1r)")

            let id2 = try await client.createFolder(name: f2, parentFolderId: "root")
            check("POST /folders（建 B）", true, "id=\(id2.prefix(8))…")

            try await client.moveFolder(folderId: id1, toFolderId: id2)
            check("PUT /folders/{id}（移动 A → B）", true)

            let inB = try await client.listEntries(folderId: id2)
            let found = inB.contains { $0.entryId == id1 }
            check("B 内确认 A", found, found ? "A 已在 B 内" : "A 未出现在 B！")

            // 清理：先删 B 里的 A，再删 B（设备可能拒绝非空删除，先删子项）
            try await client.deleteFolder(folderId: id1)
            try await client.deleteFolder(folderId: id2)
            let root = try await client.listEntries(folderId: "root")
            let cleaned = !root.contains { $0.entryId == id1 || $0.entryId == id2 }
            check("清理临时文件夹", cleaned, cleaned ? "已全部删除" : "有残留！")
        } catch {
            check("重命名/移动 roundtrip", false, error.localizedDescription)
            print("⚠️ 清理尝试中…")
            let root = (try? await client.listEntries(folderId: "root")) ?? []
            for e in root where e.entryName.contains("DpaNative-P1-") {
                if let id = e.entryId { try? await client.deleteFolder(folderId: id) }
            }
        }

        summary(pass: pass, fail: fail)
    }

    // MARK: P2 验证：WiFi / 截屏 / 固件预检（全部只读操作，不改设备状态）

    static func p2() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "✅" : "❌"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }

        guard let client = try? makeClient() else {
            print("❌ 密钥加载失败"); exit(1)
        }

        // 1. 当前 WiFi 状态
        do {
            let cur = try await client.wifiState()
            check("GET /system/status/wifi_state", true,
                  "ssid=\(cur?.ssid ?? "(空)") state=\(cur?.state ?? "?")")
        } catch {
            check("GET /system/status/wifi_state", false, error.localizedDescription)
        }

        // 2. 已保存网络列表
        do {
            let saved = try await client.registeredWiFi()
            check("GET /system/configs/wifi_accesspoints", true, "\(saved.count) 个已保存网络")
            for ap in saved { print("   · \(ap.ssid) (\(ap.security))") }
        } catch {
            check("GET /system/configs/wifi_accesspoints", false, error.localizedDescription)
        }

        // 3. 扫描（只读，但触发设备扫描动作）
        do {
            let scanned = try await client.scanWiFi()
            check("POST wifi_accesspoints/scan", true, "\(scanned.count) 个网络")
            for ap in scanned.prefix(5) {
                print("   · \(ap.ssid) sec=\(ap.security) band=\(ap.frequencyBand ?? "?") rssi=\(ap.rssiLevel.map(String.init) ?? "?")")
            }
        } catch {
            check("POST wifi_accesspoints/scan", false, error.localizedDescription)
        }

        // 4. 截屏 → /tmp
        do {
            let png = try await client.takeScreenshot()
            let ok = png.count > 100 && png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
            let path = "/tmp/dpt-screenshot-\(Int(Date().timeIntervalSince1970)).png"
            try png.write(to: URL(fileURLWithPath: path))
            check("GET /system/controls/screen_shot", ok, "\(png.count)B → \(path)")
        } catch {
            check("GET /system/controls/screen_shot", false, error.localizedDescription)
        }

        // 5. 固件预检（只读）
        do {
            let pre = try await client.firmwarePrecheck()
            check("GET update_firmware/precheck", true,
                  "image_file=\(pre.imageFileOK ? "ok" : "未上传") battery=\(pre.batteryOK ? "ok" : "电量不足")")
        } catch {
            check("GET update_firmware/precheck", false, error.localizedDescription)
        }

        summary(pass: pass, fail: fail)
    }

    // MARK: WiFi 专项验证：临时开 WiFi → 验证 WiFi API → 恢复原状 + 长超时截屏
    // 用于 USB 场景（设备 WiFi 关闭时 wifi_* API 返回 40304）

    static func wifiVerify() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "✅" : "❌"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }

        guard let client = try? makeClient() else {
            print("❌ 密钥加载失败"); exit(1)
        }

        // 0. 当前 WiFi 开关状态
        var wasOn = false
        do {
            let cfg = try await client.wifiConfig()
            wasOn = (cfg == "on")
            check("GET /system/configs/wifi", true, "wifi=\(cfg)")
        } catch {
            check("GET /system/configs/wifi", false, error.localizedDescription)
        }

        // 1. 临时开 WiFi（USB 连接态下设备可能锁定 WiFi 开关，40307 属预期）
        var turnedOn = false
        if !wasOn {
            do {
                try await client.updateConfig(key: "wifi", value: "on")
                check("PUT wifi on（临时）", true)
                turnedOn = true
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                check("PUT wifi on（临时）", false,
                      error.localizedDescription.contains("40307")
                      ? "40307 设备拒绝（USB 连接态锁定 WiFi 开关，属固件限制，需在 WiFi 场景验证）"
                      : error.localizedDescription)
            }
        }

            // 2-4. WiFi API 验证
            if let st = try? await client.wifiState() {
                check("GET wifi_state", true, "ssid=\(st.ssid.isEmpty ? "(未连接)" : st.ssid) state=\(st.state ?? "?")")
            } else {
                check("GET wifi_state", false)
            }

            if let saved = try? await client.registeredWiFi() {
                check("GET wifi_accesspoints（已保存）", true, "\(saved.count) 个网络")
            } else {
                check("GET wifi_accesspoints（已保存）", false)
            }

            do {
                let scanned = try await client.scanWiFi()
                check("POST wifi scan", true, "\(scanned.count) 个网络")
                for ap in scanned.prefix(3) {
                    print("   · \(ap.ssid) sec=\(ap.security) rssi=\(ap.rssiLevel.map(String.init) ?? "?")")
                }
            } catch {
                check("POST wifi scan", false, error.localizedDescription)
            }

        // 5. 恢复 WiFi 原状（仅在成功开启过的情况下才需要关回）
        if turnedOn && !wasOn {
            do {
                try await client.updateConfig(key: "wifi", value: "off")
                check("PUT wifi off（恢复原状）", true)
            } catch {
                check("PUT wifi off（恢复原状）", false, "⚠️ 设备 WiFi 当前为 on，请手动关闭或重跑")
            }
        } else {
            check("无需恢复（未成功开启）", true, wasOn ? "原状即 on" : "原状 off，开启未成功")
        }

        // 6. 截屏（60s 长超时）
        do {
            let png = try await client.takeScreenshot()
            let isPng = png.count > 100 && png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
            let path = "/tmp/dpt-screenshot-\(Int(Date().timeIntervalSince1970)).png"
            try png.write(to: URL(fileURLWithPath: path))
            check("GET screen_shot", isPng, "\(png.count)B → \(path)")
        } catch {
            check("GET screen_shot", false, error.localizedDescription)
        }

        summary(pass: pass, fail: fail)
    }
}
