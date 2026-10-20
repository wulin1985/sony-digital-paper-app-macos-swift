# DPT-RP1 Native — Sony Digital Paper macOS 原生客户端（Swift）

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Swift/AppKit 原生 macOS 客户端，直连 Sony Digital Paper（DPT-RP1 / DPT-CP1）设备 REST API，零 Electron 依赖。适用于 Sony 官方 Digital Paper App（1.4.7，x86/Rosetta）在 Apple Silicon / 未来 macOS 上无法运行的场景。

> 本项目与 Sony 无关，非官方实现。Digital Paper / DPT-RP1 / DPT-CP1 是 Sony Corporation 的商标，本项目仅为个人学习与设备互操作用途。

## 功能

**文档管理**
- 文件夹浏览/导航（双击进入）、新建/删除/重命名/移动
- PDF 上传（按钮 / 拖拽 / 多选）、下载（NSSavePanel）、删除
- mDNS 自动发现设备（`_digitalpaper._tcp`）

**设备管理**
- 设备信息：型号 / 固件版本 / MAC / 存储
- 设备配置：自动待机时长 / 时区 / 日期格式 / 时间格式（读写）
- WiFi：状态 / 扫描 / PSK 接入 / 已存网络管理 / WPS（按钮 & PIN）
- 设备截屏（实时抓取设备屏幕 → PNG）
- 固件升级（上传固件 → 预检 → 确认刷机）

**连接配置**
- 自动发现 Sony 官方 app 的配对密钥（复用已有配对，无需重新注册）
- 支持手动指定配对目录（多设备切换）与设备地址（mDNS 名 / 固定 IP）

## 架构

```
SwiftUI UI (ContentView / DeviceInfoView / WiFiView / FolderPickerView)
    │
DiscoveryAgent (Network.framework NWBrowser → _digitalpaper._tcp)   ← 设备在线指示
    │
DPTClient (URLSession)
    ├── https://digitalpaper.local:8443（系统 mDNS 解析，自签名证书 delegate 放行）
    ├── 认证: GET /auth/nonce/<deviceId> → RSA-SHA256 签名 → PUT /auth → 204
    ├── Cookie: URLSession HTTPCookieStorage 自动管理（原生无 SameSite 限制）
    └── 401 自动重认证
```

与 Electron 方案的关键简化：
- 无本地端口转发（port forwarder）：直连 8443
- 无 host-rules / cookie 中继：URLSession 无 SameSite/第三方 cookie 限制
- 复用官方 app 配对密钥：`~/Library/Application Support/Sony Corporation/Digital Paper App/DigitalPaperApp/<ws-id>/{deviceid.dat, privatekey.dat}`

## 构建与运行

要求：macOS 13+，Xcode Command Line Tools（Swift 5.9+）

```bash
swift build
# GUI
.build/debug/DpaNative
# CLI 验证
.build/debug/DpaNative --smoke              # 认证 → owner → storage → 根目录列表
.build/debug/DpaNative --full               # + 上传→下载字节比对→删除 roundtrip
.build/debug/DpaNative --roundtrip <pdf>    # 用指定 PDF 做 roundtrip
.build/debug/DpaNative --p1                 # 重命名/移动/设备信息/配置 读写验证
.build/debug/DpaNative --p2                 # WiFi/截屏/固件预检 只读验证
```

> 在某些受限沙箱环境下构建需 `swift build --disable-sandbox`。

## 设备 REST API 摘要

完整参数表见 [VERIFICATION.md](VERIFICATION.md)，以下为核心：

| 操作 | 请求 | 关键参数 |
|---|---|---|
| 认证 | `GET /auth/nonce/<deviceId>` → `PUT /auth` | body `{client_id, nonce_signed}`；nonce_signed = RSA PKCS1v15-SHA256(nonce UTF8) base64；204 + Set-Cookie `Credentials` |
| 目录 | `GET /folders/{id}/entries` | 根目录 id=`"root"`；响应 `{count, entry_list:[…]}` |
| 上传 | `POST /documents/` → `PUT /documents/{id}/file?offset_bytes=0&total_bytes=N` | multipart 字段 `file` |
| 下载/删除 | `GET /documents/{id}/file` / `DELETE /documents/{id}` | |
| 重命名/移动 | `PUT /documents/{id}` `{file_name?,parent_folder_id?}` / `PUT /folders/{id}` | 204；重名 = 400/40007 |
| 设备配置 | `GET /system/configs`（聚合）/ `PUT /system/configs/{key}` `{"value":v}` | standby=`5\|10\|30\|never`；tz=IANA |
| WiFi | `POST …/scan` / `PUT …/register` / `GET wifi_state` | **ssid 全程 base64** |
| 截屏 | `GET /system/controls/screen_shot` | PNG 二进制 |
| 固件 | `PUT update_firmware/file` → `GET …/precheck` → `PUT update_firmware` | multipart `file` |

## 已验证

- `--smoke` 4/4、`--roundtrip`（真实 PDF 3.2MB 字节级比对）5/5、`--p1` 10/10 真机通过
- 测试环境：DPT-RP1 @ 固件 1.6.50.14130
- 详见 [VERIFICATION.md](VERIFICATION.md)

## License

[Apache License 2.0](LICENSE) — 商用、修改、分发、私用均可，需保留版权与许可声明。

## 致谢

协议逆向参考了 Sony Digital Paper App 1.4.7 的行为分析；感谢社区既有的 DPT-RP1 开源工具提供的互操作先例。
