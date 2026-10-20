//
//  ContentView.swift
//  DpaNative 主界面：设备状态 + 文档列表 + 上传（按钮/拖拽）/下载/删除 + 设置
//
//  2026-10-20 修复：
//   - 下载：fileImporter 只能选中已有 PDF 文件，拼接出「文件/文件名」非法路径 → 改 NSSavePanel 预填文件名
//   - 上传：toolbar 按钮不显眼 → 列表上方操作栏 + List 拖拽上传（悬停提示）+ 多文件
//   - 新增设置：配对目录切换（换设备）/ 设备地址 / 测试连接 / 恢复自动发现
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var discovery = DiscoveryAgent()
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                deviceBar
                Divider()
                actionBar

                Divider()

                // 主列表
                if model.loading {
                    Spacer()
                    ProgressView("加载中…")
                    Spacer()
                } else if let error = model.lastError {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text(error).font(.callout).multilineTextAlignment(.center)
                        Button("重试") { Task { await model.reload() } }
                    }.padding()
                    Spacer()
                } else {
                    entryList
                }

                Divider()
                statusBar
            }
            .frame(minWidth: 760, minHeight: 520)
            .navigationTitle("Digital Paper")
        }
        .navigationViewStyle(.automatic)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.reload() }
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.loading)

                Button {
                    model.showUploadPicker = true
                } label: { Label("上传 PDF", systemImage: "square.and.arrow.up") }

                Button {
                    model.showNewFolder = true
                } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }

                Button {
                    model.showSettings = true
                } label: { Label("设置", systemImage: "gearshape") }

                Button {
                    model.showDeviceInfo = true
                } label: { Label("设备信息", systemImage: "info.circle") }

                Button {
                    model.showWiFi = true
                } label: { Label("WiFi", systemImage: "wifi") }

                Button {
                    Task { await model.takeScreenshot() }
                } label: { Label("设备截屏", systemImage: "camera") }
                .disabled(model.busyMessage != nil)
            }
        }
        .fileImporter(isPresented: $model.showUploadPicker,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await model.upload(files: urls) }
            }
        }
        .alert("新建文件夹", isPresented: $model.showNewFolder) {
            TextField("文件夹名", text: $model.newFolderName)
            Button("创建") { Task { await model.createFolder() } }
            Button("取消", role: .cancel) { model.newFolderName = "" }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showDeviceInfo) {
            DeviceInfoView(client: model.client)
        }
        .sheet(isPresented: $model.showWiFi) {
            WiFiView(client: model.client)
        }
        .sheet(isPresented: Binding(
            get: { model.screenshotImage != nil },
            set: { if !$0 { model.screenshotImage = nil } }
        )) {
            ScreenshotSheet(image: model.screenshotImage)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingMove != nil },
            set: { if !$0 { model.pendingMove = nil } }
        )) {
            if let entry = model.pendingMove {
                FolderPickerView(client: model.client, excludedFolderId: entry.isFolder ? entry.entryId : nil) { folderId, folderName in
                    Task { await model.applyMove(entry: entry, toFolderId: folderId, folderName: folderName) }
                }
            }
        }
        // 重命名 alert（预填当前名）
        .alert("重命名", isPresented: Binding(
            get: { model.pendingRename != nil },
            set: { if !$0 { model.pendingRename = nil } }
        )) {
            TextField("新名称", text: $model.renameText)
            Button("确定") { Task { await model.applyRename() } }
            Button("取消", role: .cancel) { model.pendingRename = nil }
        } message: {
            Text(model.pendingRename?.isFolder == true
                 ? "文件夹：\(model.pendingRename?.entryName ?? "")"
                 : "文档：\(model.pendingRename?.entryName ?? "")")
        }
        .onAppear {
            discovery.start()
            Task { await model.reload() }
        }
    }

    // MARK: 子视图

    private var deviceBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colorForStatus)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.devices.isEmpty ? "未发现设备" : "DPT 已发现（\(discovery.devices.count) 台）")
                    .font(.headline)
                Text(model.statusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let owner = model.ownerName {
                Label(owner, systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 显式操作栏（toolbar 在部分窗口形态下不显眼，这里保证上传入口可见）
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                model.showUploadPicker = true
            } label: {
                Label("上传 PDF", systemImage: "square.and.arrow.up")
            }
            .disabled(model.busyMessage != nil)

            Button {
                model.showNewFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(model.busyMessage != nil)

            Spacer()

            Text("将 PDF 拖入列表即可上传到当前文件夹")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                model.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var colorForStatus: Color {
        if model.lastError != nil { return .orange }
        if !discovery.devices.isEmpty { return .green }
        return .gray
    }

    private var entryList: some View {
        List {
            if !model.pathStack.isEmpty {
                Button {
                    model.navigateUp()
                    Task { await model.reload() }
                } label: {
                    Label("返回上级（\(model.pathStack.dropLast().last?.name ?? "根目录")）", systemImage: "chevron.backward")
                }
            }
            ForEach(model.entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isFolder ? "folder.fill" : "doc.text.fill")
                        .foregroundColor(entry.isFolder ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.entryName)
                        if let date = entry.modifiedDate {
                            Text(date).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if let size = entry.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if entry.isFolder {
                        Button("打开") {
                            model.navigateInto(entry)
                            Task { await model.reload() }
                        }
                        .buttonStyle(.link)
                        Menu {
                            Button("打开") {
                                model.navigateInto(entry)
                                Task { await model.reload() }
                            }
                            Button("重命名…") { model.startRename(entry) }
                            Button("移动到…") { model.pendingMove = entry }
                            Divider()
                            Button("删除", role: .destructive) { model.pendingDelete = entry }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(width: 28)
                    } else {
                        Button {
                            Task { await model.downloadViaSavePanel(entry: entry) }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.link)
                        .help("下载并保存…")
                        Menu {
                            Button("下载并保存…") { Task { await model.downloadViaSavePanel(entry: entry) } }
                            Button("重命名…") { model.startRename(entry) }
                            Button("移动到…") { model.pendingMove = entry }
                            Divider()
                            Button("删除", role: .destructive) {
                                model.pendingDelete = entry
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(width: 28)
                    }
                }
                // 双击进入文件夹 / 双击文档下载
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isFolder {
                        model.navigateInto(entry)
                        Task { await model.reload() }
                    } else {
                        Task { await model.downloadViaSavePanel(entry: entry) }
                    }
                }
            }
        }
        // 拖拽上传：拖入 PDF → 上传到当前文件夹
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await model.upload(files: pdfs) }
            return true
        } isTargeted: { hovering in
            model.dropHovering = hovering
        }
        .overlay {
            if model.dropHovering {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08).cornerRadius(10))
                    .padding(6)
                    .overlay(
                        Label("松开以上传 \(model.currentFolderName ?? "根目录")", systemImage: "square.and.arrow.down.on.square")
                            .font(.headline)
                    )
                    .allowsHitTesting(false)
            }
        }
        .alert("确认删除", isPresented: Binding(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let entry = model.pendingDelete {
                    Task { await model.delete(entry: entry) }
                }
            }
            Button("取消", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("将删除「\(model.pendingDelete?.entryName ?? "")」，不可恢复。")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(model.entries.count) 项", systemImage: "list.bullet")
            if let current = model.currentFolderName {
                Label(current, systemImage: "folder")
            }
            Spacer()
            if model.busyMessage != nil {
                ProgressView().controlSize(.small)
                Text(model.busyMessage ?? "")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - 设置界面（换设备 / 重置连接信息）

/// 表单状态类：当前工具链下 @State 宏插件不可用（SwiftUIMacros not found），
/// 用 ObservableObject + @Published 规避（@StateObject 可正常编译）。
@MainActor
final class SettingsForm: ObservableObject {
    @Published var hostText: String = ""
    @Published var testing = false
    @Published var testResult: String?
    @Published var testOK = false
    @Published var pickError: String?
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = SettingsForm()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2).bold()

            // 配对信息
            GroupBox(label: Label("配对信息（客户端身份）", systemImage: "key")) {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("配对目录", model.workspaceDescription)
                    infoRow("client_id", model.client.deviceId ?? "（未加载）")

                    HStack {
                        Button("选择其他配对目录…") { pickWorkspace() }
                        Button("恢复自动发现") { resetWorkspace() }
                            .disabled(model.workspaceOverride == nil)
                    }
                    if let err = form.pickError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    Text("换设备：选择另一台设备配对时生成的目录（内含 deviceid.dat 与 privatekey.dat）。")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(4)
            }

            // 设备连接
            GroupBox(label: Label("设备连接", systemImage: "antenna.radiowaves.left.and.right")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("设备地址").frame(width: 70, alignment: .leading)
                        TextField("digitalpaper.local 或 IP，如 192.168.1.100", text: $form.hostText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("默认 digitalpaper.local（mDNS 自动解析）。设备频繁休眠导致 mDNS 失效时可改用固定 IP。")
                        .font(.caption).foregroundColor(.secondary)

                    HStack {
                        Button("测试连接") { Task { await runTest() } }
                            .disabled(form.testing || form.hostText.trimmingCharacters(in: .whitespaces).isEmpty)
                        if form.testing { ProgressView().controlSize(.small) }
                        if let r = form.testResult {
                            Image(systemName: form.testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(form.testOK ? .green : .red)
                            Text(r).font(.callout)
                        }
                    }
                }.padding(4)
            }

            HStack {
                Button("应用并关闭") {
                    model.applySettings(host: form.hostText)
                    Task { await model.reload() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)

                Button("取消") { dismiss() }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            form.hostText = model.hostOverride ?? DPTClient.deviceHost
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).frame(width: 70, alignment: .leading).foregroundColor(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }.font(.callout)
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择包含 deviceid.dat 与 privatekey.dat 的配对目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        // 校验配对文件
        guard FileManager.default.fileExists(atPath: path + "/deviceid.dat"),
              FileManager.default.fileExists(atPath: path + "/privatekey.dat") else {
            form.pickError = "所选目录缺少 deviceid.dat / privatekey.dat，不是有效配对目录"
            return
        }
        form.pickError = nil
        model.setWorkspaceOverride(path)
    }

    private func resetWorkspace() {
        form.pickError = nil
        model.setWorkspaceOverride(nil)
    }

    private func runTest() async {
        form.testing = true
        form.testResult = nil
        defer { form.testing = false }
        let summary = await model.testConnection(host: form.hostText)
        form.testOK = summary.hasPrefix("OK")
        form.testResult = summary.hasPrefix("OK")
            ? String(summary.dropFirst(3))
            : summary
    }
}

// MARK: - App Model

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [DPEntry] = []
    @Published var loading = false
    @Published var lastError: String?
    @Published var ownerName: String?
    @Published var busyMessage: String?
    @Published var showUploadPicker = false
    @Published var pendingDelete: DPEntry?
    @Published var showNewFolder = false
    @Published var newFolderName = ""
    @Published var showSettings = false
    @Published var dropHovering = false
    // 重命名 / 移动（P1）
    @Published var pendingRename: DPEntry?
    @Published var renameText = ""
    @Published var pendingMove: DPEntry?
    @Published var showDeviceInfo = false
    // WiFi / 截屏（P2）
    @Published var showWiFi = false
    @Published var screenshotImage: NSImage?

    struct PathElement { var id: String; var name: String }
    @Published var pathStack: [PathElement] = []
    var currentFolderName: String? { pathStack.last?.name }

    private(set) var client = DPTClient()

    // MARK: 设置（UserDefaults 持久化）

    static let wsKey = "dpa.workspace.override"
    static let hostKey = "dpa.host.override"

    var workspaceOverride: String? {
        UserDefaults.standard.string(forKey: Self.wsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    var hostOverride: String? {
        UserDefaults.standard.string(forKey: Self.hostKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    var workspaceDescription: String {
        if let ws = workspaceOverride {
            return ws + "（手动指定）"
        }
        if let ws = DPTClient.defaultWorkspace() {
            return ws + "（自动发现）"
        }
        return "未找到（需 Sony 官方 app 配对数据，或手动指定）"
    }

    var statusDetail: String {
        var parts: [String] = []
        if let deviceId = client.deviceId {
            parts.append("client_id: \(deviceId)")
            parts.append(client.isAuthed ? "已认证" : "未认证")
        } else {
            parts.append("配对密钥未加载")
        }
        parts.append("设备: \(hostOverride ?? DPTClient.deviceHost)")
        return parts.joined(separator: " · ")
    }

    init() {
        rebuildClient()
    }

    /// 根据当前设置重建客户端（换配对目录 / 换设备地址后调用）
    func rebuildClient() {
        let c = DPTClient(host: hostOverride ?? DPTClient.deviceHost)
        if let ws = workspaceOverride ?? DPTClient.defaultWorkspace() {
            try? c.loadKeys(workspace: ws)
        }
        client = c
        ownerName = nil
    }

    func setWorkspaceOverride(_ path: String?) {
        UserDefaults.standard.set(path ?? "", forKey: Self.wsKey)
        rebuildClient()
    }

    func applySettings(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed == DPTClient.deviceHost ? "" : trimmed, forKey: Self.hostKey)
        rebuildClient()
    }

    /// 测试连接：认证 → owner → storage，返回 "OK …" 或错误描述
    func testConnection(host: String) async -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "地址为空" }
        let c = DPTClient(host: trimmed)
        if let ws = workspaceOverride ?? DPTClient.defaultWorkspace() {
            try? c.loadKeys(workspace: ws)
        }
        guard c.deviceId != nil else { return "配对密钥未加载，无法测试" }
        do {
            try await c.authenticate()
            let owner = try await c.ownerName()
            let storage = try await c.storageInfo()
            return "OK 已认证 · owner=\(owner) · \(storage.prefix(60))"
        } catch {
            return "失败: \(error.localizedDescription)"
        }
    }

    // MARK: 数据操作

    private var currentFolderId: String { pathStack.last?.id ?? "root" }

    func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            entries = try await client.listEntries(folderId: currentFolderId)
            if ownerName == nil {
                ownerName = try? await client.ownerName()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func navigateInto(_ entry: DPEntry) {
        guard entry.isFolder, let id = entry.entryId else { return }
        pathStack.append(PathElement(id: id, name: entry.entryName))
    }

    func navigateUp() {
        if !pathStack.isEmpty { pathStack.removeLast() }
    }

    // MARK: 上传（多文件 + 拖拽）

    func upload(files: [URL]) async {
        let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            lastError = "只支持 PDF 文件"
            return
        }
        for (idx, url) in pdfs.enumerated() {
            busyMessage = "上传中（\(idx + 1)/\(pdfs.count)）\(url.lastPathComponent)"
            do {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                _ = try await client.uploadPDF(fileURL: url, parentFolderId: currentFolderId)
            } catch {
                lastError = "上传失败 \(url.lastPathComponent): \(error.localizedDescription)"
                break
            }
        }
        busyMessage = nil
        await reload()
    }

    // MARK: 下载（NSSavePanel 选择保存位置）

    func downloadViaSavePanel(entry: DPEntry) async {
        guard let id = entry.entryId else { return }
        // NSSavePanel 预填设备上的文件名
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = entry.entryName
        panel.allowedContentTypes = [UTType.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        busyMessage = "下载中…"
        defer { busyMessage = nil }
        do {
            try await client.downloadFile(documentId: id, to: dest)
            busyMessage = "已保存到 \(dest.path)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.busyMessage?.hasPrefix("已保存") == true { self?.busyMessage = nil }
            }
        } catch {
            lastError = "下载失败: \(error.localizedDescription)"
        }
    }

    func delete(entry: DPEntry) async {
        guard let id = entry.entryId else { return }
        busyMessage = "删除中…"
        defer { busyMessage = nil }
        do {
            if entry.isFolder {
                try await client.deleteFolder(folderId: id)
            } else {
                try await client.deleteDocument(documentId: id)
            }
            await reload()
        } catch {
            lastError = "删除失败: \(error.localizedDescription)"
        }
    }

    func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newFolderName = ""
        busyMessage = "创建文件夹…"
        defer { busyMessage = nil }
        do {
            _ = try await client.createFolder(name: name, parentFolderId: currentFolderId)
            await reload()
        } catch {
            lastError = "创建失败: \(error.localizedDescription)"
        }
    }

    // MARK: 重命名 / 移动（P1）

    func startRename(_ entry: DPEntry) {
        renameText = entry.entryName
        pendingRename = entry
    }

    func applyRename() async {
        guard let entry = pendingRename, let id = entry.entryId else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        pendingRename = nil
        guard !newName.isEmpty, newName != entry.entryName else { return }
        busyMessage = "重命名中…"
        defer { busyMessage = nil }
        do {
            if entry.isFolder {
                try await client.renameFolder(folderId: id, newName: newName)
            } else {
                try await client.renameDocument(documentId: id, newName: newName)
            }
            await reload()
        } catch {
            // 40007 = 目标名已存在
            let msg = error.localizedDescription
            lastError = msg.contains("40007") ? "重命名失败：目标名称已存在" : "重命名失败: \(msg)"
        }
    }

    func applyMove(entry: DPEntry, toFolderId: String, folderName: String) async {
        pendingMove = nil
        guard let id = entry.entryId, toFolderId != currentFolderId else { return }
        busyMessage = "移动到 \(folderName)…"
        defer { busyMessage = nil }
        do {
            if entry.isFolder {
                try await client.moveFolder(folderId: id, toFolderId: toFolderId)
            } else {
                try await client.moveDocument(documentId: id, toFolderId: toFolderId)
            }
            await reload()
        } catch {
            let msg = error.localizedDescription
            if msg.contains("40007") {
                lastError = "移动失败：目标文件夹已存在同名条目"
            } else if msg.contains("E_MW_UO_DEST_NOT_ALLOWED") || msg.contains("not allowed") {
                lastError = "移动失败：不能移动到自身或其子文件夹内"
            } else {
                lastError = "移动失败: \(msg)"
            }
        }
    }

    // MARK: 设备截屏（P2）

    func takeScreenshot() async {
        busyMessage = "正在截取设备屏幕…"
        defer { busyMessage = nil }
        do {
            let png = try await client.takeScreenshot()
            guard let img = NSImage(data: png) else {
                lastError = "截屏数据无法解析为图像"
                return
            }
            screenshotImage = img
        } catch {
            lastError = "截屏失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 截屏展示 Sheet（P2）

struct ScreenshotSheet: View {
    let image: NSImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("设备屏幕").font(.headline)
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 640)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("保存 PNG…") { save() }
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 580, height: 720)
    }

    private func save() {
        guard let img = image else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "dpt-screen-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
