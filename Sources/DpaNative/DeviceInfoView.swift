//
//  DeviceInfoView.swift
//  P1：设备信息页（固件/型号/MAC/存储/owner）+ 设备配置编辑（待机/时区/日期/时间格式）
//  + 移动目标文件夹选择器
//
//  协议（源自 Electron 逆向）：
//   - GET /system/status/firmware_version → {"value","model_name"}
//   - GET /system/status/mac_address      → {"value"}
//   - GET /system/status/storage          → {"available","capacity"}（字符串字节数）
//   - GET /system/configs                 → {timezone:{value}, date_format:{value}, ...} 聚合
//   - PUT /system/configs/{key} {"value": v} → 204
//   - 枚举：timeout_to_standby = 5|10|30|never；date_format = yyyy/M/d|M/d/yyyy；
//           time_format = 12hour|24hour；timezone = IANA 名（如 Asia/Shanghai）
//

import SwiftUI

// MARK: - 设备信息 + 配置

@MainActor
final class DeviceInfoModel: ObservableObject {
    @Published var loading = true
    @Published var errorText: String?
    @Published var info = DPTClient.DeviceInfo()
    @Published var configs = DPTClient.DeviceConfigs()

    // 编辑中的配置值
    @Published var standby: String = ""
    @Published var dateFormat: String = ""
    @Published var timeFormat: String = ""
    @Published var timezone: String = ""
    @Published var saving = false
    @Published var saved: String?

    // 固件升级（P2）
    @Published var fwPrecheck: DPTClient.FirmwarePrecheck?
    @Published var fwBusy = false
    @Published var fwMessage: String?
    @Published var fwFileURL: URL?
    @Published var fwConfirmUpdate = false
    @Published var showFwPicker = false

    let client: DPTClient

    init(client: DPTClient) {
        self.client = client
    }

    func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            info = try await client.fetchDeviceInfo()
            configs = try await client.fetchConfigs()
            standby = configs.timeoutToStandby ?? ""
            dateFormat = configs.dateFormat ?? ""
            timeFormat = configs.timeFormat ?? ""
            timezone = configs.timezone ?? ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    var storageText: String {
        guard let raw = info.storageRaw,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let capStr = obj["capacity"] as? String, let cap = Double(capStr) else { return "未知" }
        let avail = (obj["available"] as? String).flatMap(Double.init) ?? 0
        let f = ByteCountFormatter()
        return "\(f.string(fromByteCount: Int64(avail))) 可用 / 共 \(f.string(fromByteCount: Int64(cap)))"
    }

    func save() async {
        saving = true
        saved = nil
        defer { saving = false }
        do {
            var changed = 0
            if standby != configs.timeoutToStandby {
                try await client.updateConfig(key: "timeout_to_standby", value: standby); changed += 1
            }
            if dateFormat != configs.dateFormat {
                try await client.updateConfig(key: "date_format", value: dateFormat); changed += 1
            }
            if timeFormat != configs.timeFormat {
                try await client.updateConfig(key: "time_format", value: timeFormat); changed += 1
            }
            if timezone != configs.timezone {
                try await client.updateConfig(key: "timezone", value: timezone); changed += 1
            }
            saved = changed == 0 ? "无变更" : "已保存 \(changed) 项"
        } catch {
            errorText = "保存失败: \(error.localizedDescription)"
        }
    }

    // MARK: 固件升级（P2）

    func runFirmwarePrecheck() async {
        fwBusy = true
        fwMessage = nil
        defer { fwBusy = false }
        do {
            fwPrecheck = try await client.firmwarePrecheck()
            fwMessage = "image_file: \(fwPrecheck!.imageFileOK ? "ok" : "未上传") · battery: \(fwPrecheck!.batteryOK ? "ok" : "电量不足")"
        } catch {
            fwMessage = "预检失败: \(error.localizedDescription)"
        }
    }

    /// 上传固件文件 → 预检 → 弹出最终确认
    func uploadAndPrepareUpdate(fileURL: URL) async {
        fwBusy = true
        fwMessage = "上传固件中（可能需要几分钟）…"
        defer { fwBusy = false }
        do {
            let secured = fileURL.startAccessingSecurityScopedResource()
            defer { if secured { fileURL.stopAccessingSecurityScopedResource() } }
            try await client.uploadFirmware(fileURL: fileURL)
            fwMessage = "固件已上传，正在预检…"
            fwPrecheck = try await client.firmwarePrecheck()
            if fwPrecheck!.imageFileOK && fwPrecheck!.batteryOK {
                fwFileURL = fileURL
                fwConfirmUpdate = true
            } else {
                fwMessage = "预检未通过：image_file=\(fwPrecheck!.imageFileOK ? "ok" : "异常") battery=\(fwPrecheck!.batteryOK ? "ok" : "电量不足")，已中止"
            }
        } catch {
            fwMessage = "固件上传失败: \(error.localizedDescription)"
        }
    }

    func confirmFirmwareUpdate() async {
        fwBusy = true
        fwMessage = "已发送升级指令，设备即将重启刷机（期间请勿断电）…"
        defer { fwBusy = false }
        do {
            try await client.startFirmwareUpdate()
            fwMessage = "✅ 升级指令已下发，设备将重启完成刷机，约 3-5 分钟后可重新连接"
        } catch {
            fwMessage = "升级失败: \(error.localizedDescription)"
        }
    }
}

struct DeviceInfoView: View {
    @StateObject private var model: DeviceInfoModel
    @Environment(\.dismiss) private var dismiss

    static let standbyOptions = [("5", "5 分钟"), ("10", "10 分钟"), ("30", "30 分钟"), ("never", "永不")]
    static let dateFormatOptions = [("yyyy/M/d", "yyyy/M/d"), ("M/d/yyyy", "M/d/yyyy")]
    static let timeFormatOptions = [("12hour", "12 小时制"), ("24hour", "24 小时制")]
    static let timezoneOptions = [
        "Asia/Shanghai", "Asia/Tokyo", "Asia/Hong_Kong", "Asia/Singapore",
        "UTC", "Europe/London", "Europe/Amsterdam", "America/New_York",
        "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Anchorage",
        "Pacific/Honolulu", "Australia/Sydney"
    ]

    init(client: DPTClient) {
        _model = StateObject(wrappedValue: DeviceInfoModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设备信息").font(.title2).bold()

            if model.loading {
                HStack { ProgressView(); Text("读取中…") }.padding()
            } else if let err = model.errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err).foregroundColor(.red).font(.callout)
                    Button("重试") { Task { await model.load() } }
                }.padding()
            } else {
                GroupBox(label: Label("基本信息", systemImage: "cpu")) {
                    VStack(alignment: .leading, spacing: 6) {
                        row("型号", model.info.modelName ?? "DPT-RP1")
                        row("固件版本", model.info.firmwareVersion ?? "未知")
                        row("MAC 地址", model.info.macAddress ?? "未知")
                        row("所有者", model.info.owner ?? "未知")
                        row("存储", model.storageText)
                    }.padding(4)
                }

                GroupBox(label: Label("固件升级", systemImage: "arrow.down.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("预检") { Task { await model.runFirmwarePrecheck() } }
                                .disabled(model.fwBusy)
                            Button("选择固件文件并升级…") { model.showFwPicker = true }
                                .disabled(model.fwBusy)
                            if model.fwBusy { ProgressView().controlSize(.small) }
                        }
                        if let m = model.fwMessage {
                            Text(m).font(.caption).foregroundColor(.secondary)
                        }
                        Text("需从 Sony 官网下载对应机型的固件包。升级期间设备会重启，请保持电量充足。")
                            .font(.caption2).foregroundColor(.secondary)
                    }.padding(4)
                }

                GroupBox(label: Label("设备配置（修改后点保存）", systemImage: "gearshape.2")) {
                    VStack(alignment: .leading, spacing: 10) {
                        pickerRow("自动待机", selection: $model.standby,
                                  options: Self.standbyOptions)
                        pickerRow("日期格式", selection: $model.dateFormat,
                                  options: Self.dateFormatOptions)
                        pickerRow("时间格式", selection: $model.timeFormat,
                                  options: Self.timeFormatOptions)
                        // 时区：当前值不在常用列表时附加显示
                        HStack {
                            Text("时区").frame(width: 70, alignment: .leading)
                            Picker("", selection: $model.timezone) {
                                ForEach(tzOptions, id: \.self) { Text($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        HStack {
                            Button {
                                Task { await model.save() }
                            } label: {
                                if model.saving { ProgressView().controlSize(.small) }
                                Text("保存配置")
                            }
                            .disabled(model.saving)
                            if let s = model.saved {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text(s).font(.callout)
                            }
                            Spacer()
                        }
                    }.padding(4)
                }
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { Task { await model.load() } }
        .fileImporter(isPresented: $model.showFwPicker,
                      allowedContentTypes: [.data, .zip, .image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.uploadAndPrepareUpdate(fileURL: url) }
            }
        }
        .confirmationDialog("确认开始固件升级？",
                            isPresented: $model.fwConfirmUpdate,
                            titleVisibility: .visible) {
            Button("开始升级（设备将重启）", role: .destructive) {
                Task { await model.confirmFirmwareUpdate() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("固件文件：\(model.fwFileURL?.lastPathComponent ?? "?")\n预检已通过（文件完整 + 电量充足）。升级期间请勿断电、勿离开 WiFi。")
        }
    }

    private var tzOptions: [String] {
        var opts = Self.timezoneOptions
        if !model.timezone.isEmpty, !opts.contains(model.timezone) {
            opts.insert(model.timezone, at: 0)
        }
        return opts
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).frame(width: 70, alignment: .leading).foregroundColor(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }.font(.callout)
    }

    private func pickerRow(_ key: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack {
            Text(key).frame(width: 70, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { v, label in Text(label).tag(v) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            Spacer()
        }
    }
}

// MARK: - 移动目标文件夹选择器

@MainActor
final class FolderPickerModel: ObservableObject {
    @Published var entries: [DPEntry] = []
    @Published var loading = false
    @Published var errorText: String?
    @Published var path: [FolderPathElement] = []

    struct FolderPathElement { var id: String; var name: String }

    let client: DPTClient
    /// 不可选为目标的位置（条目自身 id；其后代由设备端拒绝并报错）
    let excludedFolderId: String?

    init(client: DPTClient, excludedFolderId: String?) {
        self.client = client
        self.excludedFolderId = excludedFolderId
    }

    var currentFolderId: String { path.last?.id ?? "root" }
    var currentIsExcluded: Bool {
        if let ex = excludedFolderId, currentFolderId == ex { return true }
        return false
    }

    func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let all = try await client.listEntries(folderId: currentFolderId)
            entries = all.filter { $0.isFolder }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func navigateInto(_ e: DPEntry) {
        guard let id = e.entryId else { return }
        path.append(FolderPathElement(id: id, name: e.entryName))
        Task { await load() }
    }

    func navigateUp() {
        if !path.isEmpty { path.removeLast() }
        Task { await load() }
    }
}

struct FolderPickerView: View {
    @StateObject private var model: FolderPickerModel
    let onSelect: (String, String) -> Void   // (folderId, folderName)
    @Environment(\.dismiss) private var dismiss

    init(client: DPTClient, excludedFolderId: String?, onSelect: @escaping (String, String) -> Void) {
        _model = StateObject(wrappedValue: FolderPickerModel(client: client, excludedFolderId: excludedFolderId))
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择目标文件夹").font(.headline)
                Spacer()
                Text(breadcrumb).font(.caption).foregroundColor(.secondary)
            }.padding(12)

            Divider()

            if model.loading {
                Spacer(); ProgressView(); Spacer()
            } else if let err = model.errorText {
                Spacer()
                Text(err).foregroundColor(.red)
                Button("重试") { Task { await model.load() } }
                Spacer()
            } else {
                List {
                    if !model.path.isEmpty {
                        Button {
                            model.navigateUp()
                        } label: {
                            Label("返回上级", systemImage: "chevron.backward")
                        }
                    }
                    ForEach(model.entries) { entry in
                        Button {
                            model.navigateInto(entry)
                        } label: {
                            Label(entry.entryName, systemImage: "folder.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
                .frame(minHeight: 280)
            }

            Divider()

            HStack {
                if model.currentIsExcluded {
                    Label("不能移动到自身", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("移动到这里") {
                    let name = model.path.last?.name ?? "根目录"
                    onSelect(model.currentFolderId, name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.currentIsExcluded)
            }
            .padding(12)
        }
        .frame(width: 420, height: 420)
        .onAppear { Task { await model.load() } }
    }

    private var breadcrumb: String {
        model.path.isEmpty ? "根目录" : model.path.map { $0.name }.joined(separator: " / ")
    }
}
