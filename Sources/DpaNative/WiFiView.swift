//
//  WiFiView.swift
//  P2：WiFi 管理 — 当前连接 / 扫描 / PSK 接入 / 已保存网络 / WPS
//
//  ssid 在设备协议中 base64 编码传输，DPTClient 已解码。
//

import SwiftUI

@MainActor
final class WiFiModel: ObservableObject {
    @Published var current: DPTClient.WiFiAP?
    @Published var scanned: [DPTClient.WiFiAP] = []
    @Published var saved: [DPTClient.WiFiAP] = []
    @Published var scanning = false
    @Published var errorText: String?
    @Published var message: String?

    // 接入表单
    @Published var connectTarget: DPTClient.WiFiAP?
    @Published var password = ""

    // WPS
    @Published var wpsStateText: String?
    @Published var wpsPin: String?
    @Published var wpsBusy = false

    let client: DPTClient
    init(client: DPTClient) { self.client = client }

    func load() async {
        errorText = nil
        do {
            current = try await client.wifiState()
            saved = (try? await client.registeredWiFi()) ?? []
            if let s = try? await client.wpsState() { wpsStateText = s }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func scan() async {
        scanning = true
        errorText = nil
        message = nil
        defer { scanning = false }
        do {
            scanned = try await client.scanWiFi()
            if scanned.isEmpty { message = "未扫描到网络" }
        } catch {
            errorText = "扫描失败: \(error.localizedDescription)"
        }
    }

    func connect() async {
        guard let target = connectTarget else { return }
        let ssid = target.ssid
        let pwd = password
        connectTarget = nil
        password = ""
        message = "正在连接 \(ssid)…"
        do {
            try await client.registerWiFi(ssid: ssid, passwd: pwd)
            message = "已提交 \(ssid) 配置，设备正在连接…"
            // 稍等后刷新状态
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await load()
        } catch {
            errorText = "连接失败: \(error.localizedDescription)"
        }
    }

    func forget(_ ap: DPTClient.WiFiAP) async {
        do {
            try await client.deleteWiFiConfig(ssid: ap.ssid, security: ap.security)
            await load()
        } catch {
            errorText = "删除失败: \(error.localizedDescription)"
        }
    }

    func wpsButton() async {
        wpsBusy = true
        defer { wpsBusy = false }
        do {
            try await client.wpsStartButton()
            message = "WPS 按钮模式已启动，请在 2 分钟内按下路由器 WPS 按钮"
            await pollWps()
        } catch {
            errorText = "WPS 启动失败: \(error.localizedDescription)"
        }
    }

    func wpsPinStart() async {
        wpsBusy = true
        defer { wpsBusy = false }
        do {
            let pin = try await client.wpsStartPin()
            wpsPin = pin
            message = "在路由器上输入 PIN: \(pin)"
            await pollWps()
        } catch {
            errorText = "WPS PIN 启动失败: \(error.localizedDescription)"
        }
    }

    func wpsStop() async {
        wpsBusy = true
        defer { wpsBusy = false }
        do {
            try await client.wpsCancel()
            wpsPin = nil
            await load()
        } catch {
            errorText = "WPS 取消失败: \(error.localizedDescription)"
        }
    }

    private func pollWps() async {
        // 轮询 6 次 × 5s
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let s = try? await client.wpsState() {
                wpsStateText = s
                if s == "success" {
                    message = "WPS 连接成功"
                    await load()
                    return
                }
                if s == "timed_out" || s.contains("error") { return }
            }
        }
    }
}

struct WiFiView: View {
    @StateObject private var model: WiFiModel
    @Environment(\.dismiss) private var dismiss

    init(client: DPTClient) {
        _model = StateObject(wrappedValue: WiFiModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WiFi 设置").font(.title2).bold()

            if let err = model.errorText {
                Text(err).font(.callout).foregroundColor(.red)
            }
            if let msg = model.message {
                Text(msg).font(.callout).foregroundColor(.blue)
            }

            // 当前连接
            GroupBox(label: Label("当前连接", systemImage: "wifi")) {
                currentRow.padding(4)
            }

            // 已保存网络
            GroupBox(label: Label("已保存网络", systemImage: "bookmark")) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.saved.isEmpty {
                        Text("（无）").foregroundColor(.secondary).font(.callout)
                    }
                    ForEach(model.saved) { ap in
                        HStack {
                            Image(systemName: "lock").font(.caption).foregroundColor(.secondary)
                            Text(ap.ssid).font(.callout)
                            Spacer()
                            Button("忘记") { Task { await model.forget(ap) } }
                                .buttonStyle(.link).foregroundColor(.red)
                        }
                    }
                }.padding(4)
            }

            // 扫描
            GroupBox(label: Label("扫描并连接", systemImage: "antenna.radiowaves.left.and.right")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            if model.scanning { ProgressView().controlSize(.small) }
                            Text(model.scanning ? "扫描中…（约 10 秒）" : "开始扫描")
                        }
                        .disabled(model.scanning)
                        Spacer()
                    }
                    if !model.scanned.isEmpty {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(model.scanned) { ap in
                                    scanRow(ap)
                                }
                            }
                        }.frame(maxHeight: 200)
                    }
                }.padding(4)
            }

            // WPS
            GroupBox(label: Label("WPS", systemImage: "wave.3.right")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Button("按钮接入") { Task { await model.wpsButton() } }
                            .disabled(model.wpsBusy)
                        Button("PIN 接入") { Task { await model.wpsPinStart() } }
                            .disabled(model.wpsBusy)
                        Button("取消") { Task { await model.wpsStop() } }
                            .disabled(model.wpsBusy)
                        if model.wpsBusy { ProgressView().controlSize(.small) }
                    }
                    if let pin = model.wpsPin {
                        Text("PIN: \(pin)").font(.callout).textSelection(.enabled)
                    }
                    if let s = model.wpsStateText {
                        Text("状态: \(s)").font(.caption).foregroundColor(.secondary)
                    }
                }.padding(4)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .onAppear { Task { await model.load() } }
        // 连接密码输入
        .sheet(isPresented: Binding(
            get: { model.connectTarget != nil },
            set: { if !$0 { model.connectTarget = nil; model.password = "" } }
        )) {
            if let target = model.connectTarget {
                VStack(alignment: .leading, spacing: 12) {
                    Text("连接 \(target.ssid)").font(.headline)
                    SecureField("WiFi 密码", text: $model.password)
                    HStack {
                        Spacer()
                        Button("取消") { model.connectTarget = nil; model.password = "" }
                        Button("连接") { Task { await model.connect() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.password.isEmpty)
                    }
                }
                .padding(20)
                .frame(width: 340)
            }
        }
    }

    private var currentRow: some View {
        HStack {
            if let cur = model.current, !cur.ssid.isEmpty {
                Image(systemName: cur.state == "connected" ? "wifi" : "wifi.exclamationmark")
                Text(cur.ssid).font(.callout)
                Text("（\(cur.state ?? "unknown")）").font(.caption).foregroundColor(.secondary)
            } else {
                Image(systemName: "wifi.slash").foregroundColor(.secondary)
                Text("未连接").foregroundColor(.secondary)
            }
            Spacer()
            Button("刷新") { Task { await model.load() } }
        }
    }

    private func scanRow(_ ap: DPTClient.WiFiAP) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ap.security == "nonsec" ? "wifi" : "lock")
                .font(.caption).foregroundColor(.secondary)
            Text(ap.ssid).font(.callout)
            if let band = ap.frequencyBand {
                Text(band).font(.caption2).foregroundColor(.secondary)
            }
            if let rssi = ap.rssiLevel {
                Text("信号 \(rssi)").font(.caption2).foregroundColor(.secondary)
            }
            if let state = ap.state, state != "none" {
                Text(state).font(.caption2).foregroundColor(.blue)
            }
            Spacer()
            Button("连接") { model.connectTarget = ap }
                .buttonStyle(.link)
                .disabled(ap.security == "eap") // EAP 需证书，暂不支持
        }.padding(.vertical, 1)
    }
}
