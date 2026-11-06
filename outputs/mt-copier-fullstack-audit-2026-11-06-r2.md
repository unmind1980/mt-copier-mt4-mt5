# mt-copier 全栈只读审计报告（2026-11-06 第二轮 / 独立通读）

- **审计对象**：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
- **代码基线**：`de7f62a`（2026-11-05 23:49，工作区干净）
- **审计方式**：单进程整文件顺序通读，**未开子代理**，以便跨模块不变量一次性对齐
- **通读范围**
  - MQL：`src/Include/Copier/*.mqh` 全部 17 个头文件、`CopierSender.mq4`(2386)、`CopierReceiver.mq4`(8829)、`CopierSelfTest.mq4`、`CopierZmqProbe.mq4`
  - Rust：`hub/src/*.rs` 全部 17 个模块（含 `api.rs` 4460 行、`main.rs` 3174 行）
  - 文档：`README.md`、`doc/PROTOCOL.md`、`HANDOFF.md`、`AUDIT-22/23/24`、`CENTRAL-HUB-*-PLAN`、`SNAPSHOT-DEMAND-PLAN`、`TLS-HTTPS-SPECIFICATION`、历史 `outputs/*audit*.md`
- **约束**：**只读，未修改任何源码/配置**；本文件仅为审计结论。

> 说明：本项目已连续多轮审计修复，重复列出"已修项"没有价值。本报告只写
> **在当前代码上仍能复现的问题**，并把上一轮遗留项单独放在第 6 节标注，避免与历史混淆。

---

## 1. 结论摘要

| 编号 | 端 | 等级 | 一句话 |
|---|---|:---:|---|
| **A1** | Hub / 协议 | **高（安全）** | 数据面无法归属发布者：任一 CURVE 授权节点可伪造任意 sender 的 `OPEN/CLOSE/MODIFY/SNAP`，一条 `SNAP N=0` 即可让所有镜像端清仓 |
| **A2** | MQL Sender | **高（性能/带宽）** | 止损或挂单触发价一变动就置 `g_snapDirty` → **每 250ms 广播一次全量快照**；移动止损场景下 4 次/秒，与 `SnapshotSeconds=15` 的节流设计直接矛盾 |
| **B1** | Rust HA | 中 | HA 同步把"对端未启用通知/文件不存在"当成永久差异 → 1Hz 同步循环；Standby `--notifications none` 时写空路径失败 → `sync_err` 永久，**自动回切被永久阻塞**并每秒产生垃圾 `.tmp` 文件 |
| **B2** | Rust API | 中 | `POST /api/v1/commands` 允许**全网 `close`**：同一 ticket 广播到所有 receiver，别的账号上恰好存在同号 ticket 就会被误平 |
| **B3** | MQL 配置 | 中 | `copier.ini` 落盘用 `FILE_ANSI`，与 Hub 的 UTF-8/Unicode 承诺冲突；中文注释经 `CFG` 推送后可能变 `?`，且 `IH=` 随之漂移，最终把损坏文本写回 Hub 的"当前配置" |
| **B4** | Rust TLS | 中 | 启用 TLS 时 `ensure_dedicated_https_listener` 固定绑 `0.0.0.0:https_port`，静默绕过 `--http 127.0.0.1` 的回环默认 |
| **B5** | 协议/Hub | 中 | 每个 sender 每秒一条 `STAT`；100 senders × N receivers 时 Hub 侧为 100×N 帧/秒，信息量可用一条多 `SID` 收据帧替代 |
| **B6** | MQL Receiver | 中 | 配置热重载会清空 `g_ssidSeen`，重载后首个迟到的旧会话/备用 Hub 帧会被当作"新会话"应用，短暂按过期状态收敛 |
| **B7** | Rust Hub | 低中 | `send_receipt` 未做 `copier_nid` 归一；启动后 60s 的 warm 窗口内 `SID` 直接成为发布主题（小型反射面） |
| **C1–C7** | 多端 | 低 | 见第 4 节（日志字节一致性、状态文件删除窗口、desired 残留、sender 状态文件命名、取模偏差、续期首轮 12h 等） |

---

## 2. 高危问题详解

### A1【高危 · 安全/架构】数据面没有发布者归属，任一节点可冒充任意 sender

**位置**
- `hub/src/main.rs:2637-2662`（数据转发前的两道安全判断）
- `hub/src/main.rs:2540-2560`（收据转发的 `sender_valid/receiver_valid` 判定）
- 消费端：`src/Experts/CopierReceiver.mq4:7148-7162`（`AcceptSeq` 只看 `SID` 与主题）、`src/Include/Copier/CopierDefs.mqh:1365-1386`（`CopierIsTopicTarget`）

**机制**

Hub 的转发判断只有两条：

```rust
// main.rs
if env_sid == "hub" || ty == "CFG" || ty == "CMD" { drop }
if !env_sid.is_empty() && topic_str != env_sid && ty != "SNAP" { drop }
// 然后 topic/payload 原样转发
```

`env_sid` 和 `topic_str` **都来自发布者自己**。于是任意一个通过 CURVE + allow-list 的节点（也就是任何一个 EA）可以：

```
发布 [<受害者 sender 的 NID>, "V=1|SID=<受害者 NID>|...|T=OPEN|P=UID=...;SIDE=1;..."]
```

`topic == SID` 成立 → 两条判断全部通过 → Hub 原样转发。订阅了该 sender 的所有 Receiver 会：
- `CopierIsTopicTarget` 通过（主题就是它的 sender）；
- `SenderIndexById(e.sid)` 命中；
- 按各自的过滤/风控**真的开仓**。

同理可发：
- `MODIFY` → 把镜像仓的 SL/TP 改成任意价位（等于强制在指定价格平仓）；
- `CLOSE` → 平掉任意 UID 的镜像；
- `SNAP P= N=0;H=...` → `HandleSnapshot` 判定"发送端已清仓"，`g_desiredCount=0`，converge **平掉该 sender 的全部镜像**（`H` 可省略，`CopierValidateSnapshot` 在无 `H` 时只看 `N` 与解码数）。

**为什么这不是"理论问题"**

项目的威胁模型确实写着"防火墙是边界"，但代码自身已经为跨节点注入写了三道防线（`F-01` 拒 `SID=hub` 走数据主题、`F-02` 数据主题 `topic!=SID` 时必须 `SNAP`、Receiver 端 `H-02` 拒数据流上的 `CFG/CMD`）。这三道防线都在防"一个节点冒充 Hub 或下发控制指令"，却没有防"一个节点冒充另一个 sender"——而后者能造成的损失（强制平仓/改止损）与控制指令同级。

Hub 侧结构上也无法解决：XPUB 只提供 `(topic, payload)`，不提供"这条帧来自哪条 pipe / 哪个 CURVE 公钥"；ZAP 只在握手时回答"这个 key 能不能连"，握手完成后数据面就是全通的。

**建议（按代价从低到高）**
1. **承认并写明边界**：`doc/PROTOCOL.md` / `README` 明确"allow-list 里的任一 key 等价于对全部 sender 数据面的写权限"，一台机器一个租户。当前文档没有这句话，运维会误以为 allow-list 是"按节点隔离"。
2. **收紧 `SNAP` 豁免**：`ty=="SNAP" && topic!=SID` 只允许 `topic` 是**已注册 receiver** 的 NID（定向补发的唯一合法形态）。这不能阻止"用自己的 topic + 受害者 SID"（因为 `topic==SID` 分支仍放行），但能消掉一整类越权路径，并把合法形态写死。
3. **真正的修复是每节点一条 pipe**：Hub 为每个节点建独立 PUB/SUB（或 ROUTER/DEALER），发布时按 pipe 归属校验 SID。代价是拓扑与内存模型重写，属"下一阶段"。
4. 若短期要缓解：把 `MODIFY`/`SNAP` 也纳入签名（sender 用已有 CURVE 私钥对 payload 做 HMAC，Receiver 验签）。这是唯一不依赖传输层归属的方案，但要动协议。

---

### A2【高危 · 带宽/CPU】止损变动触发 250ms 全量快照广播

**位置**
- `src/Experts/CopierSender.mq4:426`（`MarkStateDirty()` 同时置 `g_stateDirty` 与 `g_snapDirty`）
- `src/Experts/CopierSender.mq4:2105-2126`（`stopsDiff || ppriceDiff` 分支：`MarkStateDirty()` + `Emit(CP_T_MODIFY, ...)`）
- `src/Experts/CopierSender.mq4:2252-2261`（广播条件）
- `src/Experts/CopierSender.mq4:1651-1692`（`RebuildSnapshotPayload`：全表导出 + 编码 + 压缩）

**机制**

```mql4
// 2105 起：止损/挂单价变动
if(stopsDiff || ppriceDiff)
  {
   MarkStateDirty();          // ← 同时置 g_snapDirty
   ...
   Emit(CP_T_MODIFY, ...);    // ← 本来就是为了省掉全量快照
  }
...
// 2252：只要 g_snapDirty 且距上次重建 ≥250ms，就广播
if(dueSnap || (g_snapDirty && g_fillSnapshotDueMs==0 && now-s_lastSnapRebuildMs>=250))
  { g_snapDirty=false; BroadcastSnapshot(now); }
```

后果是**每一笔移动止损都把全量快照拉到 4Hz**：
- 每次 `BroadcastSnapshot` 都执行 `RebuildSnapshotPayload`：`CopyToWithSlots` 扫 2048 槽 → 逐条 `CopierEncodeRec` → `CopierCompressField`（Deflate + Z85）→ `Emit` 同时发 direct 与 hub 两条通道。
- 2048 仓位的快照最坏约 380KB（`CP_MAX_MSG_LEN` 的注释自己算过）；4 次/秒 = **1.5MB/s per sender**，Hub 再扇出给 N 个 receiver。
- 一个 300 仓位的普通账户、10 个 receiver：约 4×(30~60KB)×10 ≈ **1.2~2.4MB/s** 的持续出网，全部由"止损挪了 1 个点"引起。

这与代码里反复强调的设计意图直接矛盾：
- `SnapshotSeconds` 从 2 提到 15，理由是"~380 KB/push 太贵"；
- `MODIFY` 事件存在的**唯一理由**就是"止损变动不走快照"（PROTOCOL.md 里写得很清楚：`MODIFY` 约 135 字节 vs 快照约 380KB，差 2800 倍）。

现在两者同时发生：`MODIFY` 发了，紧接着 250ms 后又发一次全量快照。带宽不但没省，反而比"只发快照"更高（因为多了一次编码/压缩）。

**为什么之前没暴露**

`g_snapDirty` 的注释（`MQL-02`/`H1`）是为了修"部分平仓在 `SnapshotSeconds=15` 下 15 秒才收敛"的问题。那次修复把"仓位数量变化"（TRIM/开/平）与"止损变化"混在同一个 dirty 标志里，而两者的正确传播方式不同：
- 数量变化 → 必须尽快全量广播（否则 receiver 的 TRIM 延迟 15 秒）；
- 止损变化 → `MODIFY` 已经实时送达，快照只需按 `SnapshotSeconds` 周期兜底。

**建议**

把 `MarkStateDirty()` 拆成两个语义：
```mql4
void MarkStateDirty()          { g_stateDirty=true; }                 // 只落盘
void MarkSnapshotDirty()       { g_stateDirty=true; g_snapDirty=true; }// 需要全量广播
```
- `stopsDiff` / `ppriceDiff` 分支改用 `MarkStateDirty()`（`MODIFY` 已负责实时性）；
- 开仓/平仓/TRIM/kind 变化继续用 `MarkSnapshotDirty()`。

这样"移动止损"回到设计意图：一条 135 字节的 `MODIFY`，加每 15 秒一次的快照兜底。

**验证方法**：在 sender 上挂一个每 tick 移动 1 点的移动止损，`LogLevel=3` 下统计 `SNAPSHOT` 发送次数/分钟。修复前应约 240 次/分钟；修复后应约 4 次/分钟。

---

## 3. 中危问题详解

### B1【中 · HA】"对端没有这个文件"被当成永久差异，同步循环 + 自动回切被阻塞

**位置**
- `hub/src/cluster.rs:655-662`（`needs_sync`）
- `hub/src/cluster.rs:812-838`（通知文件落盘）
- `hub/src/notifications.rs:328-332`（`--notifications none` → `path = PathBuf::new()`）
- `hub/src/notifications.rs:357-359`（`path()` 返回空路径）

**机制**

```rust
let needs_sync = ... || remote_st.notif_hash != notif_h
                     || remote_st.curve_clients_hash != curve_h;
```

`file_sha256("")` 返回 `""`（`fs::metadata("")` 失败）。于是：

**场景 1：Standby 用 `--notifications none`，Primary 有 `alert_channels.json`**
- Primary `notif_hash = <hash>`，Standby `notif_hash = ""` → 永远不等 → 每秒一次 sync。
- Standby 申请同步 → Primary 返回 `notif_content` → Standby 执行：
  ```rust
  let p = notif_store.lock().path().to_path_buf();   // 空
  let tmp = format!("{}.tmp.{}", p.display(), pid);  // ".tmp.1234"（当前目录！）
  File::create(&tmp) ... atomic_replace_file(&tmp_path, &p)  // rename 到 "" → 失败
  ```
- `file_sync_err = Some(...)` → `sync_status = "sync_err"`。
- `continuous_online_start` 每次都被清空 → **ADR-10 自动回切永远不满足**（`can_failback` 要求 `sync_status=="synced"` 且连续在线 ≥ N 小时）。
- 附带：工作目录里每秒丢一个 `.tmp.<pid>` 垃圾文件。

**场景 2：Primary 用 `--notifications none`，Standby 有文件**
- Primary `notif_content = None`（`read_to_string("")` 失败）→ Standby 的 hash 永不更新 → 每秒 sync 请求 + 每秒一行 `Initiating sync ...`（`was_syncing` 在成功后变 `synced`，下一次又打印）。

`curve_clients.txt` 同理：一侧不存在、另一侧存在，就是永久差异。

**建议**
1. `needs_sync` 里对"功能未启用"的一侧短路：只有**双方都 enabled** 时才比较该 hash。具体做法：`ClusterStatusResponse` 增加 `notif_enabled: bool` / `curve_clients_enabled: bool`，未启用时该 hash 字段置空并跳过比较。
2. 写盘前校验 `p.as_os_str().is_empty()` → 直接视为"本端未启用，跳过"，并**清掉 `file_sync_err`**，不要让一个可预期的配置差异把 `sync_status` 永久钉在 `sync_err`。
3. `sync_err` 不应阻塞 failback 的"稳定计时"以外的判定——至少要区分"数据不一致"与"本端功能未启用"。

---

### B2【中 · 运维安全】全网 `close` 会把同一 ticket 发给所有 receiver

**位置**：`hub/src/api.rs:2836-2846`（`commands_global`）

```rust
// N83-09: 只挡了空 ticket
if op == "close" && args.trim().is_empty() { return 400; }
...
for node in &nodes { cmds.issue_op(node, &op, &args, &actor, ""); }
```

`OPS` 包含 `close`，而 `commands_global` 遍历**所有 receiver**。`close` 的语义是"平掉本账号上 ticket=N 的仓位"，ticket 是账号内唯一、跨账号毫无意义。结果：
- 大多数 receiver 回 `OK=1;NOTE=ticket_not_found_or_already_closed`（无害）；
- 但只要某个账号上恰好存在同号 ticket（同经纪商、同批开户的账号很常见），那笔**完全无关的仓位会被平掉**。

**建议**：`commands_global` 明确拒绝 `op=="close"`（返回 400 并提示用 `/nodes/{id}/commands`）；或者要求 `close` 必须带 `node` 字段。`pause/resume/closeall/reload/reqpos/reqcfg` 保持全网语义（它们本来就是账号级操作）。

---

### B3【中 · i18n/一致性】ini 落盘使用 ANSI，与 Hub 的 Unicode 承诺冲突

**位置**
- `src/Include/Copier/CopierConfig.mqh:720-752`（`CopierIniWriteAll` 用 `FILE_WRITE|FILE_TXT|FILE_ANSI`）
- `src/Include/Copier/CopierConfig.mqh:660-717`（`CopierIniReadAll` 用 `FILE_READ|FILE_TXT|FILE_ANSI`）
- 对端承诺：`hub/src/config.rs:708-736`（`escape_ini` 的注释明确写"Chinese comments included"必须往返）

**机制**

Hub 的 `escape_ini` 按 `chars()` 迭代，非 ASCII 原样透传；MQL 的 `CopierIniEscape` 按 `StringGetCharacter` 逐字符处理，也能保住码点。**内存里确实往返无损**（自检脚本也是这么测的）。

但 `CopierIniWriteAll` 用 `FILE_ANSI` 写盘：MQL 会把字符串按**当前系统 ANSI 代码页**编码。在非中文 Windows（CP1252）上，中文注释写盘即变成 `?`；在中文 Windows（CP936/GBK）上，GBK 能表示中文，但 **GBK 不是 UTF-8**——Hub 侧存的 ini 是 UTF-8 文本，节点落盘后再读回，只要代码页不是 UTF-8，字节就变了。

后果链：
1. `CFG` 推送一份带中文注释的 ini → 节点 `CopierIniUnescape` → `CopierIniWriteAll(FILE_ANSI)` → 注释被替换/转码。
2. `SerializeCurrentConfigToIni` 序列化的是**内存中的字符串**（此时还是正确的 Unicode），`CopierCfgHash` 走 `StringToCharArray(CP_UTF8)`，所以 `IH=` 一开始是对的。
3. 但下一次 `LoadConfig()` 从磁盘读回（`FILE_ANSI`）→ 注释已损坏 → 重新序列化 → `IH=` 变了 → Hub 判定"不一致" → `reqcfg` → 节点 `CFGRPT` 上报**损坏后的文本** → Hub 把 `node_current_ini` 覆盖成损坏版本。
4. 仪表盘的 "Load Current Setting from Node" 从此显示乱码/`?`，而磁盘上的 ini 也已经不是 Hub 当初推的那份。

**建议**
1. 读写都改用 `FILE_UNICODE`（UTF-16LE，MQL 原生），或 `FILE_ANSI` + 显式 `StringToCharArray(..., CP_UTF8)` 自行编解码；文件里加 BOM 便于识别。
2. 若坚持 ANSI，则 `escape_ini`/`CopierIniEscape` 应把非 ASCII 字符转为 `%XX`（UTF-8 字节级转义），使落盘内容纯 ASCII —— 这与"不破坏分隔符"的初衷一致，且彻底消除代码页依赖。
3. 补测试：`CopierSelfTest` 里做一次"含中文注释的 ini → 写盘 → 读回 → 再序列化"的往返，断言 `CopierCfgHash` 不变。

---

### B4【中 · 安全】启用 TLS 会静默把 API 暴露到 0.0.0.0

**位置**：`hub/src/api.rs:2043-2047`

```rust
tokio::spawn(async move {
    let bind_addr = format!("0.0.0.0:{}", https_port);
    match tokio::net::TcpListener::bind(&bind_addr).await {
```

`--http` 的默认值是 `127.0.0.1:6010`，`main.rs` 的注释专门解释过"绑定回环是刻意的，因为这个端口暴露每一笔持仓"。但运维在仪表盘点一下 "Enable TLS / 自签证书" 后，`ensure_dedicated_https_listener` 会新建一个 **`0.0.0.0:443`** 的 HTTPS 监听（默认 `https_port=443`）。原来的回环保证被一次 UI 操作悄悄取消，且日志只有一行 `Dedicated HTTPS listener active on https://0.0.0.0:443`，没有任何"这会把面板暴露到公网"的提示。

**建议**
- 新增 `tls.http_bind`（默认 `127.0.0.1`），与 `--http` 的 host 部分保持一致；需要公网时由运维显式改成 `0.0.0.0`。
- 或在 `tls_configure` 的响应/审计里明确写出 `bind=0.0.0.0`，并在文档的"安全边界"一节加一行。

---

### B5【中 · 扩展性】"每 sender 一条 STAT" 在 100 senders 下是 100 倍帧量

**位置**
- `src/Experts/CopierReceiver.mq4:8704-8756`（按 sender 循环，每个发一条 `STAT`）
- `hub/src/main.rs:2456-2621`（每帧都要过一遍 `STAT` 处理 + 收据去重 + `mirrors` 维护）

**机制**

`SyncHeartbeatSeconds=1` 时，一个镜像 100 个 sender 的 receiver 每秒发 **100 条** `STAT`，每条只带一个 `SID/H` 对。Hub 侧要对每一条做：解析、`note_ping`、`mirrors` 更新、收据去重表查询。100 receivers × 100 senders = **10,000 帧/秒**，而承载的信息量是 100×N 个 8 字节哈希。

`doc/PROTOCOL.md` 对这一点的解释是"每个 sender 一条，sender 才能判断收据是不是关于自己"。但 Hub 已经知道每条收据对应哪个 sender（它按 `SID` 转发 `RCPT`），所以**批量收据完全可行**：一条 `STAT` 里放 `R0=<sid>:<h>` 这样的多对，Hub 拆成 N 条 `RCPT` 单播。协议是自描述的 `k=v;`，加一个可选字段不破坏兼容（旧 Hub 忽略未知键）。

**建议**
- 新增可选字段 `RH=<sid1>:<h1>,<sid2>:<h2>,...`（或 `R=` 复用），节点在 `g_nSenders>1` 时用它替代 N 条 `STAT`；
- Hub 侧：有 `RH` 时按对拆分转发，无 `RH` 时退回旧逻辑；
- 收益：帧数从 `O(senders)` 降到 `O(1)`，Hub 的 `STAT` 处理开销同比。

这是纯优化，不动语义，但需要两端同版本；建议与 `CP_NODE_VER` 升版一起做。

---

### B6【中 · 一致性】热重载清空 `g_ssidSeen`，迟到帧会被当成"新会话"

**位置**：`src/Experts/CopierReceiver.mq4:1898-1914`（`LoadConfigForHub` 每个 sender 重置）、`7158-7162`（`AcceptSeq` 的 SSID 分支）

**机制**

`LoadConfigForHub()` 在每次 `CFG`/`reload` 后对每个 sender 执行：

```mql4
g_lastSeq[i][...] = -1;
g_ssidSeen[i]="";
ClearAbandonedSsids(i);
g_ready[i]=false;
g_desiredCount[i]=0;
```

于是重载后的第一条帧（无论 SSID 是什么）都会命中 `AcceptSeq` 的 `g_ssidSeen[si]!=e.ssid` 分支 → 被当作"发送端重启" → 再清一次 desired、记一条 `new session ... -> resync` 日志，然后按这条帧的内容建立 desired。

在双 Hub 部署下，这条"第一条帧"完全可能是**备用 Hub 迟到的一帧**（两个 ZMQ pipe 的相对顺序不保证）。它携带的是几秒前的状态（可能是某个仓位尚未开/尚未平的中间态），而 `g_ready` 此时已被置 true，`ConvergeSender` 会**立刻按过期状态收敛一次**：
- 过期快照里没有、而本地有的镜像 → 被判"发送端已平" → **误平**；
- 过期快照里有、本地没有的 → **误开**。

等真正的当前快照到达（`SSID` 相同但内容更新）后会自动纠正，但这一次误动作是真实成交、真实点差。

**建议**
- 重载时**保留** `g_ssidSeen[i]` 与 `g_lastSnapMs[i]`（配置变了不代表会话变了）；只清 `g_lastSeq`（因为重载可能改变订阅），并保留 `g_desiredCount` 直到新快照到达（或至少保留 `g_ready` 的"已见快照"语义）。
- 更稳妥：重载后设一个"等待新快照"的短暂窗口（例如 30s），期间 `g_ready=false`，不收敛（代价是最多 30s 不动作，换来不误平）。
- 若保留清空逻辑，至少应把"备用 Hub 的迟到帧"排除：`AcceptSeq` 的 SSID 分支要求 `stream==CP_STREAM_SNAP` 或 `topic==g_sid[si]`（现在只对 EVENT 做了这个检查，见 `7083-7090`）。

---

### B7【低中 · 安全】`send_receipt` 未归一化 SID，且 warm 窗口内 `SID` 直接成为主题

**位置**：`hub/src/main.rs:870-892`（`send_receipt` 直接 `format!("@{}", sid)`）、`2540-2560`（`started.elapsed()<60s` 时任意 SID 视为有效）

**机制**

- `send_cfg` / `send_cmd` / `send_topology` 都走 `copier_nid(acc)`，只有 `send_receipt` 直接用 payload 里的 `SID` 字符串。对 10 位账号的旧 ini，`SID` 可能是原始账号，实际主题是 `@<10位>`；节点订阅了 `@<9位nid>` 与 `@<rawAcc>`，所以**恰好还能到**，但这是巧合，不是设计。
- 更值得注意：Hub 启动后 60 秒内 `sender_valid/receiver_valid` 为真（`warm`），任意 `SID` 都会触发 `send_receipt(&sock, &sid, ...)`。于是一个节点可以让 Hub 向**任意主题**发布一条 `RCPT`（每秒一次）。这不是提权，但是一个可被滥用的"Hub 代发"原语，且会把 `last_rcpt_relayed` 表塞满。

**建议**：`send_receipt` 统一走 `copier_nid(sid)`；`warm` 窗口只放宽"是否已注册"的判断，不放宽"主题必须是合法 NID（纯数字、≤9 位）"。

---

## 4. 低危 / 一致性问题

| 编号 | 位置 | 问题 | 影响 |
|---|---|---|---|
| **C1** | `hub/src/commands.rs:422-455`、`hub/src/config.rs:272-295` | 备机追加的是**重新序列化**的 `Command`/`Revision`，不是 Primary 的原始行 | 备机日志与主机非字节一致；将来 Primary 新增字段（如 `note`）在角色互换后丢失。当前无功能影响，但"物理行对齐"的说法只在行数层面成立 |
| **C2** | `hub/src/main.rs:1858-1871` | 收到 `PING` 时按 payload `FROM` 直接 `send_pong`，不校验 `FROM` 是否为已注册节点 | 任意节点可让 Hub 向任意 `@topic` 发 PONG（小型反射）；建议只回已注册节点，或回 `topic` 对应的节点 |
| **C3** | `src/Include/Copier/CopierState.mqh:1307-1317` | `Save()` 的注释说"successor 先写、旧文件不动"，但代码在打开 dst 前先 `FileDelete(path)` | 该窗口内主文件缺失（只能靠 `.tmp` 兜底）。注释与实现相反，容易误导后续维护者；建议改成 `FileOpen(path, FILE_WRITE)` 直接覆写（MQL 的 `FILE_WRITE` 本身会截断），无需先删 |
| **C4** | `src/Experts/CopierReceiver.mq4:6053-6059` | `HandleSnapshot` 只写 `g_desired[base..base+n)`，不清理 `n` 之后的历史行 | 最多 2048 条 `CopierPos` 的字符串引用滞留（每次快照变小都留一批）；建议把 `[n, 旧count)` 区间的 `uid/sym/cmt` 置空 |
| **C5** | `src/Experts/CopierSender.mq4:431` | `StatePath()` 只按**账号**命名，不按端口/实例 | 同一账号挂两个 Sender（不同 `EventsPort`）会共享 UID 表，第二个实例会把第一个的仓位当成"自己的"接管。文档默认"一账号一 sender"，但代码没有拦住这种配置；建议文件名加 `SenderId()`（代码已有 `copier_sender_<port>.st` 的 legacy 读取分支，说明设计上本就打算按端口） |
| **C6** | `hub/src/users.rs:957-966` | `random_password` 用 `b % 56`（256 不能被 56 整除） | 字符分布轻微偏差（部分字符概率高 14%）；bootstrap 密码熵仍约 70 bit，属"能改就改"级别。建议 rejection sampling |
| **C7** | `hub/src/tls.rs:1552-1556` | 自动续期 worker 先 `sleep(12h)` 再检查 | 一个"证书还剩 2 天"的 Hub 重启后要等 12 小时才可能续期；建议启动后先检查一次再进入循环 |

---

## 5. 性能优化空间（非缺陷）

| 编号 | 位置 | 内容 | 收益 |
|---|---|---|---|
| **P1** | `src/Experts/CopierSender.mq4:1912-1942`、`1944-1984` | `EncodeSenderPositions` / `SendSenderStatusReport` 对每条持仓 `g_prev.Find(uid)` 线性扫 2048 槽（`P4` 遗留项） | `reqpos` 时从 O(N×2048) 降到 O(N)；复用 `BuildCurrent` 刚写好的 `g_prevSlotScratch[i]` 即可 |
| **P2** | `hub/src/notifications.rs:1255-1302` | `resolve_pinned_client` 每次发送都新建 `reqwest::Client`（`P2` 遗留项） | 每条告警省 1 次 DNS + 1 次 TCP + 1 次 TLS 握手；建议加 TTL 300s 的 `(host, ip, port) -> Client` 缓存，仍保持 SSRF 免疫 |
| **P3** | `src/Include/Copier/CopierTransport.mqh:513-535` | `SendUp` 尾帧失败后 `send("",true)` 也可能失败，套接字残留 `SNDMORE`（`P3` 遗留项） | 建议置 `m_framingCorrupted` 并在下一次发送前重建 socket（或至少记录并跳过本轮所有后续发送，避免"把下一条消息拼到上一条尾巴"） |
| **P4** | `src/Experts/CopierReceiver.mq4:8704-8756` | 每 sender 一条 STAT（见 B5） | 100 senders 时帧数降 100 倍 |
| **P5** | `src/Include/Copier/CopierSymbol.mqh:235-314` | `CopierSymbolQuoteAgeMs` 每次调用线性扫 256 槽（外层还有 16 槽 memo） | 100 符号 × 10Hz = 25.6 万次字符串比较/秒；改成 `CopierUidIndex` 同款哈希即可降为 O(1) |
| **P6** | `src/Experts/CopierReceiver.mq4:4881-4981` | `RefreshRisk` 在 fast path（每个事件批次）也调用，而 `ScanAndResolveAccountPositions` 的 `forceFullScan` 分支要读全部注释 | 高频事件（网格/马丁）时每秒可能十几次全量扫描；建议 fast path 只做"增量 + 计数"，30s 全扫仍留在慢车道 |
| **P7** | `hub/src/main.rs:1694-1706` | snap-worker 的 200ms poke 节流用 `static LAST_SNAP_POKE`，与主循环的 `poke_pending` 两套节流 | 逻辑重复；合并到主循环一次节流即可，行为更可预测 |

---

## 6. 上一轮（2026-11-05 / 11-06）遗留项复核

| 历史编号 | 本轮复核结论 | 证据 |
|---|---|---|
| C1 挂单宽限期震荡 | **已修复** | `CopierReceiver.mq4:5326-5332` 到期不再 `Forget`，仅保留键并继续走撤单；`5350` 在 kind 对齐时清理 |
| C2 单播修复改写全局哈希 | **已修复** | `CopierSender.mq4:1403-1411` 只 `NoteRecentSnapHash`，注释明确不改 `g_snapHash/g_snapPayload` |
| C3 `senderIdx==-1` 不扣计数 | **已修复** | `CopierReceiver.mq4:3404-3408` 扣 `g_orphanCount`，`3409` 扣 `g_acctPositions` |
| **C4 PONG 提前 Disarm** | **仍存在** | `CopierSender.mq4:1846-1849`、`CopierReceiver.mq4:7197-7201` 仍是"任一 PONG 到达即 `Disarm`"；双 Hub 下慢的那个 RTT 仍被 `OnTimer` 周期放大。修法：`m_connectedHubs>1` 时收齐两个 `FROM` 或 15ms 超时后再 Disarm |
| C5 备机物理行数漂移 | **结构仍在，但当前不可达** | `commands.rs:442-448` 仍只把 `should_insert` 的行写入磁盘。当前每种状态转移在 `(ts, rank, attempts)` 上都严格递增（`due` 增 attempts、`ack` 提 rank、`revive` 改 ts），所以备机不会漏行；但这是一个**隐性不变量**，将来任何人加一条"同 ts/同 rank/同 attempts" 的转移就会重新触发 `replace_all` 死循环。建议加断言 + 单测 |
| P1 平仓阶梯探测 | **已实现** | `CopierSender.mq4:2177-2180` |
| P2 通知连接池 | **未实现**（见 P2 表） | — |
| P3 尾帧错位保护 | **未实现**（见 P3 表） | — |
| P4 `EncodeSenderPositions` O(2048) | **未实现**（见 P1 表） | — |

---

## 7. 测试缺口建议

1. **Sender 快照频率**（对应 A2）：构造持续移动的止损，断言单位时间内 `SNAP` 发送次数 ≤ `60/SnapshotSeconds + 少量余量`。这是最容易回归的一条。
2. **Hub HA + `--notifications none`**（对应 B1）：一端禁用通知、一端启用，断言 `sync_status` 不会停在 `sync_err`、不产生 `.tmp.*`、`continuous_online_start` 能累积。
3. **API 全网 `close`**（对应 B2）：断言 `POST /api/v1/commands {"op":"close","ticket":1}` 返回 400。
4. **ini 编码往返**（对应 B3）：含中文注释的 ini → `CopierIniWriteAll` → `CopierIniReadAll` → 序列化，断言 `CopierCfgHash` 前后一致。
5. **伪造数据帧**（对应 A1）：在 `tools/` 增加一个黑盒脚本，用一个 XSUB 以"另一个 sender 的 topic + SID"发 `SNAP N=0`，**当前会成功让 receiver 清仓**——把它固定成"已知风险"的红灯用例，直到 A1 的方案落地。
6. **备机日志字节一致**（对应 C5）：一条命令经历 issue→retry→ack，断言备机 `commands.jsonl` 的**行内容**（不只是行数）与主机一致；若决定只保证行数，则把该断言改成"行数一致 + 每条 id 的最后状态一致"。

---

## 8. 修复优先级建议

| 顺序 | 项目 | 理由 |
|---|---|---|
| 1 | **A2** | 改动小（一个函数拆分 + 两个调用点），收益立竿见影（带宽降 2 个数量级），且完全在 MQL 侧、无需协议变更 |
| 2 | **B1** | HA 的自动回切被永久阻塞，是"高可用"承诺的直接破口；改动集中在 `cluster.rs` 一个 `needs_sync` 与两个写入分支 |
| 3 | **B2** | 一行拒绝 + 一个测试，避免"误平别人仓位"这类不可逆事故 |
| 4 | **B3** | 影响 i18n 与配置真实性；修法明确（UTF-8 或字节级转义），但要动 MQL 写盘/读盘两处，需回归 |
| 5 | **A1** | 结构性风险，短期只能"写清楚 + 收紧 SNAP 豁免"，真正的修复要重做数据面归属，应单独立项 |
| 6 | **B4 / B5 / B6 / B7** | 按运维暴露面与规模排序 |
| 7 | C1–C7、P1–P7 | 清理项，可分批做 |

---

## 9. 已确认无问题（本轮重点反查）

以下跨模块不变量本轮逐一追到消费端读值，确认闭合，列出来是为了避免下一轮重复排查：

1. **快照三方计数一致性**：`CopierEncodeSnapshot` 的 `N=` → `CopierDecodeSnapshot` 的 clamp → `CopierValidateSnapshot` 的 `decoded==min(N,cap)`，与 sender 端 `CopierLotEncodable` 咽喉过滤一致；`N=0` 且 `R=` 非空会被 `NH-02` 拒绝。
2. **`CopierSeenRing` 的 `m_occ` 紧凑索引 + `DropAt` 交换删除**：`Forget`/`ForgetPrefix`/`ForgetUidActions`/`PruneExpired` 四个消费端都不在删除后前进下标，与 `DropAt` 契约一致。
3. **`CopierBackoff` 开放寻址**：`Note` 先清槽再 `EraseHash`、`EraseHashSlot` 的 backward-shift 与 `IsBetweenCircular` 的方向经推演正确（r 在 (i,j] 内不搬，否则搬），256 次探测上限无死循环。
4. **动作队列 head 偏移**：`PushAction` 的 `CompactQueue` 触发、`RotateQueue` 满载就地轮转、`ShiftQueue` 清字符串、`skipped<=g_qn` 上界，四条路径的 `g_qHead+g_qn` 边界一致。
5. **`ExecuteQueue` 出队复核链**：sender ready/stale → desired 复核（side/kind/lots）→ 全局风控 → per-sender 风控 → 账户/券商配额，与 `AllowOpen(held+pending)` 语义对齐；成功/失败/sweeper 三条路径的计数扣减（含 `N57-14` 的 pending 分支）都已闭环。
6. **`QueueModifyIfNeeded` 签名缓存**：13 字段覆盖 desired/local 双侧几何 + `g_stOvEpoch` 失效链（config/sender 配置/override/STOPS 清理/改单失败）完整；`clamped`/`emergencyMissing`/`invertedCrossed` 三个出口都拒绝写签名。
7. **Hub 转发安全（F-01/F-02/H-02）**：数据主题拒 `SID=hub`/`CFG`/`CMD`；Receiver 端 `CopierIsTopicTarget` 精确主题匹配 + `s_errs=-999` 前缀碰撞丢弃。**（A1 的问题是这两道防线的覆盖范围，不是它们的实现）**
8. **snap-worker 异步解析**：无锁 `last_known_receipt` 前置对比、队列满不推进回执（`F-07`）、`catch_unwind` 隔离、200ms poke 合并。
9. **命令 journal 单调性**：`(ts, rank, attempts)` 三级序在 `load`/`apply_delta_lines`/`due` 三处一致；两阶段"先落盘后提交"（`F-01`）；`--commands none` 的 `(0,0)` 口径。
10. **SSRF 防护**：`check_url_base`（scheme/userinfo/host 字面量）→ `check_single_ip`（link-local/元数据/CGNAT/私网/IPv4-mapped）→ `resolve_pinned_client`（DNS 结果逐个校验 + `resolve_to_addrs` 钉死 + 禁重定向），三步覆盖 DNS rebinding TOCTOU；`send_webhook` 还过滤了 `Host/Content-Length/Transfer-Encoding/Connection`。
11. **鉴权与会话**：`verify_password` 常量时间、轮数来自存储哈希（升 `HASH_ROUNDS` 不会锁死老用户）、`session()` 每次校验 `disabled/role/pass_hash`（改密/降权/禁用即时撤销）、WS 5s 续验、`--users none` 下写端点仍走角色门。
12. **CURVE**：读写两侧都显式 Z85→32 字节并 fail-closed；空 allow-list 拒绝启动；ZAP 在 bind 前监听；learn 模式只追加不覆盖。
