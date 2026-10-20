# P3 范围评估：搜索 / 本地缓存 / 文件夹同步

日期：2026-10-20 · 基于 Electron 1.4.7 源码逆向结论

## 结论先行

| 功能 | 原实现机制 | Swift 复刻成本 | 建议 |
|---|---|---|---|
| 文档搜索 | **设备端 API**（非本地） | **低（0.5 天）** | ✅ 建议升级为 P2.5，直接做 |
| 本地目录缓存 | Electron 端 SQLite（DatabaseWrapper） | 中（2-3 天） | 按需：设备仅 12GB/几百文档，实时拉取已够快 |
| 文件夹同步 | SyncTransferHandler 双向同步 | 高（3-5 天） | 先做单向（Mac→设备），双向另议 |

## 1. 搜索（成本远低于预期）

Electron 的 `SearchCollection.js` 表明搜索走**设备端**：

```
GET /documents?entry_type=<document|folder>
             &search_target=<title|text|annotation>(待确认枚举)
             &search_keyword=<关键词>
             &origin_folder_id=<folder_id|root>
             &order_type=<...>
             &offset=<N>&limit=<N>
```

- 设备固件内置全文索引（PDF 文本层 + 手写批注识别），DPT-RP1 核心卖点之一
- Swift 实现只需一个带 query 的 GET + 结果解析 + UI 搜索框，**不依赖本地缓存**
- 响应格式预计同 entries（`entry_list` 包裹），待真机验证

## 2. 本地目录缓存（必要性存疑）

Electron 用 SQLite 缓存目录树原因：Backbone collection 每次导航都要全量 fetch，UI 卡顿。
Swift 版现状：URLSession 直连，列表请求 < 300ms（真机实测），且设备文档量级小（12GB 存储）。

**仅当以下场景出现才值得做**：
- 离线浏览（设备休眠时翻目录）
- 大文件夹（500+ 条目）秒开需求

实现要点（若做）：系统自带 SQLite3 C API（零依赖）或 GRDB；全量同步 = 递归 GET folders/{id}/entries；增量 = `file_revision`（GET /documents/{id} 返回）对比；缓存失效策略 = 认证成功后后台刷新。

## 3. 文件夹同步（工作量最大）

原版支持 Mac 本地文件夹 ↔ 设备文件夹双向同步（SyncTransferHandler + SQLite 状态记录）：
- 文件监视（FSEvents / DispatchSource）
- 冲突解决（双向改名/同时间修改）
- 删除传播（双向删如何判定）
- 传输队列与断点

**建议拆两步**：
1. 单向自动上传（监视 Mac 文件夹 → 新 PDF 自动上传设备）：1 天，覆盖 80% 场景
2. 完整双向同步：暂缓，待单向用稳后评估

## 建议执行顺序

1. **搜索**（P2.5，本轮即可做）——真机验证 search API 响应格式后实现
2. 单向同步（可选）
3. 本地缓存 / 双向同步（暂缓）
