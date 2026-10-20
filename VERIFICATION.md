# DPT-RP1 Swift 原生客户端 API 验证报告

- 日期：2026-10-20
- 验证对象：`dpa-swift/Sources/DpaNative/DPTClient.swift` + `SmokeTest.swift`
- 参考准绳：Sony 官方 Electron app 逆向源码（dpa-port / dpa-analysis）+ 已实测确认的设备协议事实
- 设备：DPT-RP1 @ 192.168.x.x（digitalpaper.local）

---

## 1. 静态核对结果表

### 1.1 认证链

| # | 项目 | Swift 实现 | 参考源码 | 结果 |
|---|------|-----------|---------|------|
| 1 | nonce 获取 | `GET auth/nonce/<deviceId>`，期望 200 | authctrl.js:78 `GET /auth/nonce/ + deviceId` | ✅ 一致 |
| 2 | nonce 解析 | JSON `nonce` 字段，非空校验 | authctrl.js:166-176 | ✅ 一致 |
| 3 | 签名算法 | `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256)`，输入 nonce 的 UTF-8/ASCII 字节 | authadpt.js:197-201 `crypto.createSign('RSA-SHA256')`，update nonce binary 字节 | ✅ 一致（RSA-SHA256 = PKCS1v15-SHA256） |
| 4 | 签名编码 | `(sig as Data).base64EncodedString()` | authctrl.js:194 `btoa(nonceSigned)` | ✅ 一致 |
| 5 | 认证请求 | `PUT auth`，body `{"client_id": deviceId, "nonce_signed": <b64>}`，期望 204 | authctrl.js:192-204 `PUT /auth`；handleAuthRes:259 要求 204 | ✅ 一致 |
| 6 | 私钥导入 | PKCS#1 PEM → DER → `SecKeyCreateWithData` | （配对密钥即 PKCS#1 格式） | ✅ 一致（背景确认已实测 204 通过） |
| 7 | cookie 管理 | `httpShouldSetCookies=true` + `.always` 接受策略，URLSession 自动管理 Credentials | Electron 靠 XHR cookie | ✅ 等效实现 |
| 8 | 401 重试 | `apiError("40100"/"40101")` 触发 reauth | 设备 401 返回 `{"error_code":"40100", ...}` | ✅ 兼容 |

### 1.2 系统 API

| # | 项目 | Swift 实现 | 参考事实 | 结果 |
|---|------|-----------|---------|------|
| 9 | owner | `GET system/configs/owner`，期望 200，解析 `value` | 协议事实：200 `{"value":"<owner>"}` | ✅ 一致 |
| 10 | storage | `GET system/status/storage`，期望 200 | 协议事实 | ✅ 一致 |

### 1.3 目录 API

| # | 项目 | Swift 实现 | 参考源码 | 结果 |
|---|------|-----------|---------|------|
| 11 | 根目录 id | 字符串 `"root"` | ContentDefs.js:29 `VALUE_ENTRY_ID_ROOT='root'`；FolderDocumentCollection.js:40 | ✅ 一致 |
| 12 | 列目录 | `GET folders/<id>/entries`，期望 200 | FolderDocumentCollection.js:44 `/folders/<id>/entries`，validStatuses [200] | ✅ 一致 |
| 13 | 条目解析 | entry_type/document_id/folder_id/entry_name/file_name/folder_name/file_size/parent_folder_id | Electron 实体模型字段 | ✅ 覆盖一致 |

### 1.4 文档 API（上传两步 / 下载 / 删除）

| # | 项目 | Swift 实现 | 参考源码 | 结果 |
|---|------|-----------|---------|------|
| 14 | 建条目 | `POST documents/`（尾斜杠），期望 [200,201] | filetransfer.js:674 `POST /documents/`；实测设备返回 200 | ✅ 路径一致；[200,201] 宽松（设备实际 200），⚠️ 宽松差异标注 |
| 15 | 建条目 body | `{"parent_folder_id", "file_name", "document_source": ""}` | filetransfer.js:669-671 完全一致 | ✅ 一致 |
| 16 | 传文件 | `PUT documents/<id>/file?offset_bytes=0&total_bytes=<N>` | filetransfer.js:695 + 2409 | ⚠️ 路径/query 意图一致，但**修复前 URL 构造有致命 bug**（见 §2 修复 F1） |
| 17 | multipart 字段名 | `name="file"`，filename=实际文件名 | filetransfer.js:2407 字段名 `'file'`、文件名任意 | ✅ 一致 |
| 18 | multipart 构造 | boundary 格式、Content-Disposition、结束符均标准 | Electron FormData | ✅ 一致 |
| 19 | 传文件期望状态 | [200,201,204] | filetransfer.js:2497 接受 200/206 | ⚠️ 宽松差异标注（实现更宽松，不算错误） |
| 20 | 下载 | `GET documents/<id>/file`，期望 [200,206] | filetransfer.js:184 | ✅ 一致 |
| 21 | 删除 | `DELETE documents/<id>`，期望 [200,204] | EntityModel.js:52-54 validStatuses [204] | ⚠️ 宽松差异标注 |

### 1.5 文件夹 API

| # | 项目 | Swift 实现 | 参考源码 | 结果 |
|---|------|-----------|---------|------|
| 22 | 建文件夹 | `POST folders`（修复后），body `{"parent_folder_id","folder_name"}`，期望 [200,201] | DeviceModel.js:699-704 `POST /folders`（**无**尾斜杠），[200] | ✅ 修复后一致（见 §2 修复 F2）；期望状态宽松标注 |
| 23 | 删文件夹 | `DELETE folders/<id>`，期望 [200,204] | EntityModel.js:80-82 [204] | ⚠️ 宽松差异标注 |

### 1.6 URL 构造专项验证（macOS 实测）

用最小 Swift 脚本实测 `URL.appendingPathComponent` 行为：

| 输入 path | 修复前结果 | 修复后结果 |
|---|---|---|
| `documents/abc/file?offset_bytes=0&total_bytes=5` | `.../file%3Foffset_bytes=...`（query 变路径，**必 404**） | `.../file?offset_bytes=0&total_bytes=5` ✅ |
| `documents/` | `.../documents/`（尾斜杠保留） | 同左 ✅ |
| `folders` | `.../folders` | 同左 ✅ |

---

## 2. 修复清单

### F1（致命）：`request()` 把 query 参数编码进路径
- **位置**：DPTClient.swift `request(_:_:body:contentType:)`
- **问题**：原实现 `baseURL.appendingPathComponent(path)` 对含 `?` 的 path（上传第二步 `documents/<id>/file?offset_bytes=0&total_bytes=<N>`）会把 `?` percent-encode 为 `%3F`，query 完全失效，设备端收到路径 `/documents/<id>/file%3Foffset_bytes=...` → 404，上传 roundtrip 必然失败。
- **修复**：path 含 `?` 时拆分为路径+query 两部分：路径部分仍用 `appendingPathComponent`（保留 `POST /documents/` 尾斜杠行为），query 部分经 `URLComponents.percentEncodedQuery` 正确附加。
- **验证**：编译通过 + URL 构造单测（见 §1.6）全部输出正确。

### F2（参数差异）：`createFolder` 路径带多余尾斜杠
- **位置**：DPTClient.swift `createFolder(name:parentFolderId:)`
- **问题**：原实现 `POST folders/`，参考源码 DeviceModel.js:704 为 `POST /folders`（无尾斜杠）。设备 REST 层两种路径可能不等价（`POST /documents/` 尾斜杠是协议要求，folders 无此要求）。
- **修复**：`"folders/"` → `"folders"`，与官方客户端逐字符一致。

### 未修改、仅标注的宽松差异（按任务约束不算错误）
- PUT file 期望 [200,201,204]（参考 200/206）
- DELETE 文档/文件夹期望 [200,204]（参考 [204]）
- POST /documents/ 期望 [200,201]（参考 [200]）
- POST /folders 期望 [200,201]（参考 [200]）

> 以上均为"实现更宽松"：设备实际返回状态码（200/204）都在 Swift 接受列表内，不影响与真机交互，仅放宽了校验。

---

## 3. 编译验证

```
$ cd dpa-swift && swift build --disable-sandbox
Build complete! (1.55秒)
```

- 仅存留 2 条与本次改动无关的既有 warning（ContentView.swift:233 未使用 `try?`、ld 搜索路径 warning），不阻塞。

---

## 4. 真机实测结果

### 4.1 在线探测（按约束最多 2 次）

| 尝试 | 命令 | 结果 |
|---|---|---|
| 1 | `curl http://192.168.x.x:8080/api_version --max-time 4` | 超时（exit=28），无响应 |
| 2 | IP + mDNS 各一次（--max-time 6） | IP：exit=52（TCP 连上但无 HTTP 响应，半休眠特征）；digitalpaper.local：exit=6（mDNS 解析失败） |

### 4.2 --smoke 运行（2 次）

```
[keys] workspace=<workspace-id> client_id=<client-id>
❌ 认证 — 认证失败: The request timed out.
冒烟中止（认证失败后续 API 均不可用）
===== 结果: 0 通过 / 1 失败 =====
```

- 密钥加载正常（deviceId 36 字符读取成功）。
- `GET /auth/nonce` 对 8443 超时 → 设备处于休眠/半休眠，HTTPS API 不可达。
- 第二次 --smoke（间隔约 25 秒后）同样超时。

### 4.3 --full

- 未运行——依赖认证成功，设备休眠中不可测。

### 结论：**实测待设备唤醒**

设备探测共 4 次（curl×3、smoke×2 触达 8443 超时），已达约束上限，停止重试。静态验证已全部完成且两个 bug 已修复并编译通过；待设备唤醒后直接运行：

```
cd <repo>
./.build/debug/DpaNative --smoke
./.build/debug/DpaNative --full     # 自建测试 PDF，自动清理，不影响设备已有文档
```

---

## 5. 遗留问题

1. **真机 roundtrip 未执行**：设备休眠（8080 半开、8443 超时、mDNS 不解析）。唤醒后跑 --full 即可闭环验证 F1/F2 两个修复。
2. **SmokeTest.swift 的最小 PDF 无 xref 表**：`makeTestPDF()` 生成的 PDF 没有 xref/trailer 结构完整的对象偏移（有 trailer 无 xref）。设备固件若做 PDF 校验可能拒绝（error 4xxxx）；此前协议事实未说明设备是否校验。若 --full 上传步骤报错，优先换真实 PDF 重试（`--full` 支持传参）。
3. **删除状态码**：设备实际返回 204（参考源码），Swift 接受 [200,204]，无功能影响。
4. ContentView.swift:233 既有编译 warning（`try?` 结果未使用），非本次范围。

## 6. 简明总结

- **静态核对**：23 项逐项对照，21 项完全一致，2 项发现真实差异（F1 query 编码致命 bug、F2 folders 尾斜杠），4 项"更宽松"仅标注。
- **修复**：F1（request() query 拆分）、F2（POST /folders 去尾斜杠），均编译通过 + URL 构造单测验证。
- **真机实测**：设备休眠（4 次触达均不可用，达重试上限），smoke/full 待设备唤醒后执行。

---

## 7. 真机实测补录（设备唤醒后，2026-10-20）

### 7.1 修复 F3（响应解析）：`listEntries` 期望裸数组，实际为包裹结构

- **位置**：DPTClient.swift `listEntries(folderId:)`
- **问题**：首跑 `--smoke` 3/4 —— 认证/owner/storage 通过，`GET /folders/root/entries` 报"设备响应无法解析"。用 Node 直连探明设备实际返回包裹结构：
  ```json
  {"count": 7, "entry_list": [ {"entry_id": "...", "entry_name": "Books", "entry_type": "folder", "entry_path": "Document/Books", "parent_folder_id": "root", "created_date": "...", "is_new": "false"}, ... ]}
  ```
  原实现按裸数组 `[[String: Any]]` 解析必然失败。
- **修复**：先解析对象取 `entry_list`，兼容裸数组兜底；`DPEntry` 补充 `entryPath`/`createdDate` 字段，`parseEntry` 的 `modifiedDate` 回退 `created_date`。

### 7.2 --smoke（修复后）：4 通过 / 0 失败 ✅

```
✅ 认证 PUT /auth → 204 — client_id 认证成功
✅ GET /system/configs/owner — owner=<owner>
✅ GET /system/status/storage — {"available":"4540287200","capacity":"11898335232"}…
✅ GET /folders/root/entries — 7 项（folders=7, docs=0）
```

### 7.3 --roundtrip（真实 PDF 3.2MB）：5 通过 / 0 失败 ✅

测试文件：`让你的 Skill 可测可迭代 - Agent Skill Benchmark 评测经验 - KM平台.pdf`（3,240,371 字节，真实含 xref 表的 PDF，规避 §5.2 自制 PDF 风险）

```
✅ POST /documents/ + PUT file（上传） — document_id=d05aae54-… size=3240371B
✅ 列表中出现新文档 — name=让你的 Skill 可测可迭代 … .pdf
✅ GET /documents/{id}/file（下载） — 大小比对 3240371B vs 3240371B（字节级一致）
✅ DELETE /documents/{id}
✅ 删除后列表确认 — 已从设备移除
```

### 7.4 最终结论

**全链路真机验证通过：smoke 4/4 + roundtrip 5/5。** F1/F2/F3 三个修复均经真机闭环确认；上传→列表确认→下载字节比对→删除→删除确认完整 roundtrip 无残留（测试文档已从设备清除）。遗留 §5.1 已闭环，§5.2 风险已用真实 PDF 规避（自制 PDF 路径 `--full` 未单独复测，若设备接受无 xref PDF 则同样可用）。

---

## 8. P1 真机实测（2026-10-20）：10 通过 / 0 失败 ✅

`--p1` 全部通过（临时文件夹闭环，无残留）：

```
✅ GET /system/status/firmware_version — firmware=1.6.50.14130 model=DPT-RP1
✅ GET /system/status/mac_address — mac=<MAC>
✅ GET /system/configs（聚合） — standby=10 tz=Etc/GMT-8 date=yyyy/M/d time=12hour owner=<owner>
✅ PUT /system/configs/timeout_to_standby（原值回写） — value=10
✅ POST /folders（建 A）→ PUT /folders/{id}（重命名）→ POST /folders（建 B）
✅ PUT /folders/{id}（移动 A → B）→ B 内确认 A → 清理临时文件夹
===== 10 通过 / 0 失败 =====
```

协议确认（源码逆向 + 真机验证）：
- 重命名/移动 = `PUT /documents/{id}` `{file_name?,parent_folder_id?}` / `PUT /folders/{id}` `{folder_name?,parent_folder_id?}` → 204
- 配置读写 = `GET /system/configs`（聚合）/ `PUT /system/configs/{key}` `{"value":v}` → 204
- 枚举：standby=`5|10|30|never`；date_format=`yyyy/M/d|M/d/yyyy`；time_format=`12hour|24hour`

## 9. P2 实现（2026-10-20）：代码完成，真机验证待设备唤醒

实现清单（已编译通过）：
- **WiFi**：状态(wifi_state)/扫描(POST scan)/PSK 接入(PUT register，body 对齐 Electron 全量字段，ssid base64)/已存列表/删除/WPS 按钮/PIN/取消/状态轮询
- **截屏**：GET screen_shot → PNG → 预览 + 保存
- **固件**：PUT update_firmware/file（multipart）→ precheck → PUT update_firmware，UI 双重确认
- `--p2` CLI 只读验证模式已就绪

⚠️ 首跑 `--p2` 时设备已自动休眠（standby=10 分钟），5 项超时——**非代码问题**，待唤醒后重跑。

P2 协议要点（全部源码逆向确认，未真机验证项标注）：
- ssid 在 WiFi 协议中全程 base64 编码（btoa/atob）
- WPS：PUT button(204)/pin(200 返回 PIN)/cancel(204)，GET wps_state
- 固件上传与文档上传同构：multipart 字段 `file` + `?offset_bytes=0&total_bytes=N`
- 搜索为设备端 API：`GET /documents?search_target=&search_keyword=...`（详见 P3-PLAN.md）
