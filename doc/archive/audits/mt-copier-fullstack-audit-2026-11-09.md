# mt-copier 全栈深度审计报告（2026-11-09）

> **审计执行模式**：严格只读（Strictly Read-Only），未对任何生产代码、头文件、脚本或配置文件执行任何写操作。  
> **审计执行方式**：单代理全栈纵深逐行推演与全系统关联分析（未开任何 Sub-Agent，确保跨端关联逻辑完整闭环与全局因果一致）。  
> **代码与规范基线**：
> - 核心规范与文档：`doc/` 13 份核心 MD、`MEMORY.md`、`HANDOFF.md`、`PROTOCOL.md`、`CENTRAL-HUB-HA-FINAL-PLAN.md`、`TLS-HTTPS-SPECIFICATION.md`、历史审计报告（2026-11-08 r1 ~ r6）；
> - 客户端与头文件：`src/Experts/CopierSender.mq4`（2512行）、`src/Experts/CopierReceiver.mq4`（9881行）、`src/Include/Copier/*.mqh` 全部 17 个头文件；
> - 服务端 Hub：`hub/src/*.rs` 全部 17 个核心模块（main、cluster、commands、config、positions、registry、api、envelope、curve、stats、alerts、users、tls、notifications、lockx、audit、service）；
> - 测试套件验证：`hub/build.sh --test`（176 passed, 0 failed）、`tools/tests.sh`（19 个测试套件，包含 snapshot/repair/modify/positions/commands/config/cluster/chaos/tls 等，全部通过）。

---

## 1. 执行摘要与全栈问题矩阵

本轮审计在 2026-11-08 r6 基线之上，对全栈代码库（MQL4/MQL5 客户端、Include 底层头文件、Rust Hub 核心路由引擎、高可用集群同步机制与测试体系）展开了全面纵深审查。

### 本轮审计核心结论
1. **前期已发现逻辑缺陷修复确认**：
   - `LocalTicketStillOpen`（`CopierReceiver.mq4:634-640`）：已彻底改写为复用 `CopierResolveCloseTicket`，消除了 MT4 `SELECT_BY_TICKET` 历史单误判与 MT5 `POSITION_IDENTIFIER` 部分平仓失效的双重陷阱。
   - `CopierPayloadModifyParse`（`CopierCodec.mqh:788`）：已将 `PEXP=` 升级为 64 位 `CopierParseLong`，消除 wire 协议整型截断隐患。
   - `Emit()`（`CopierSender.mq4:556`）：已补齐 `e.gts = (long)TimeGMT()`，消除了隐式零初始化的时钟漂移风险。
   - 节点驱逐清理（`main.rs:3166`）：已补齐 `state.last_topo_sent.remove(acc)`，闭环了拓扑缓存泄露问题。
2. **本轮新发现的性能、架构与边缘逻辑问题**：
   - **Hub 高可用集群 1 秒定时器同步阻塞磁盘 I/O 与 SHA-256 计算**（**P-01**）：稳态下每秒重复读取并哈希数十兆日志文件，占用 Tokio 异步线程与磁盘带宽。
   - **ZMQ 核心订单路由主线程抖动与 WebSocket 广播深拷贝**（**P-02**）：在单线程毫秒级订单转发主循环中执行全量看板快照 JSON 序列化，对多客户端重复 clone 字符串。
   - **收据去重表极端容量清退引发集群收据雪崩**（**L-01**）：`last_rcpt_relayed` 超限时执行全量 `clear()`，导致所有活跃发送端并发重发 `RCPT`。
   - **持久化配置日志与命令日志缺乏运行时 Compaction**（**A-01**）：`config_revisions.jsonl` 完全无压缩机制，`commands.jsonl` 仅在冷启动压缩，长期运行单调膨胀。
   - **MQL 队列执行中的 `CopierWaitMs` 忙等自旋锁死 CPU**（**P-03**）：在定时器中执行 20~30ms 空循环流控，在单核 VPS 上引发 100% vCPU 尖刺与宿主限速。

---

### 全栈问题分级矩阵

| 编号 | 严重度 | 模块 / 位置 | 问题摘要 | 业务 / 运行影响 | 修复方案建议 |
|---|---|---|---|---|---|
| **P-01** | **高·Hub 性能** | `hub/src/cluster.rs:655-659, 1140-1145`<br>Cluster 1s Worker | Primary 与 Standby 节点每秒在 Tokio 异步线程中对 `config_revisions.jsonl`（可达数十MB）和 `commands.jsonl`（可达8MB+）调用 `file_sha256`（`fs::read` 全量载入堆内存）。 | 稳态下每秒重复读盘并分配/释放数十兆内存（~100GB/小时无谓 I/O），阻塞 Tokio 异步执行线程，造成宿主 CPU 抖动。 | 引入 `(mtime, len)` 元数据预检缓存；哈希计算移入 `tokio::task::spawn_blocking` 并采用流式读取。 |
| **P-02** | **中·Hub 实时性** | `hub/src/main.rs:3389-3398`<br>`hub/src/api.rs:854`<br>看板快照广播 | ZMQ 路由主线程在订单转发主循环中执行 `api::snapshot_text(&shared)` 全量 JSON 序列化；WebSocket 广播对每个连接客户端执行 `(*s).clone()` 内存拷贝。 | 抢占单线程订单路由引擎的毫秒级调度时间窗口；多看板连接并发时造成频繁内存分配与 CPU 尖刺。 | 路由线程仅通过 Atomic 标记或轻量通知唤醒后台工作线程；看板推送改用 `Bytes` / `Arc` 零拷贝广播。 |
| **L-01** | **中·Hub 容错** | `hub/src/main.rs:1096-1102`<br>收据去重表清退 | `last_rcpt_relayed.len() > MAX_RCPT_RELAYED_KEYS` 且 60s 裁剪仍超限时，执行 `last_rcpt_relayed.clear()` 全量清空。 | 瞬间清空所有正常发送端的收据记忆，引发全集群接收端并发触发 `should_relay = true`，造成收据风暴（Thundering Herd）。 | 采用 LRU / 最旧条目修剪或仅淘汰非注册发送端键；避免对活跃发送端一刀切清空。 |
| **A-01** | **中·Hub 架构** | `hub/src/config.rs`<br>`hub/src/commands.rs`<br>Store Compaction | `config_revisions.jsonl` 完全缺乏 Compaction 压缩例程；`commands.jsonl` 的 `compact_journal` 仅在冷启动时调用一次，运行时零压缩。 | 长稳运行数月后持久化日志无限单调膨胀，恶化 P-01 的读取与哈希耗时，增加集群对齐网络开销。 | `config.rs` 引入 `compact_journal`；两处均接入定时（如每日凌晨）或高水位触发的运行时日志压缩机制。 |
| **P-03** | **中·MQL 性能** | `CopierReceiver.mq4:3327-3335, 3779, 4227`<br>`CopierWaitMs` 忙等 | `CopierWaitMs` 采用 `while(CopierNowMs()-start<waitMs)` 空循环忙等 20ms~30ms 进行券商限速流控。 | 在单核或双核云 VPS 上引发 100% vCPU 尖刺，可能导致虚拟机被云厂商降频，并延误行情刷新与 tick 处理。 | 改造为非阻塞跨 tick 事件调度（调用 `g_pump.ArmFast(waitMs)` 并退出当前回调，由下一次计时器唤醒续跑）。 |
| **L-02** | **低·Hub 代码** | `hub/src/cluster.rs:1127-1131`<br>Primary 校验锁作用域 | Primary 验证逻辑中获取 `st.lock_or_recover()` 提取配置与命令路径后立即释放，紧接着再次获取同一锁只为了读取 `notif_store` 路径。 | 无谓的双重互斥锁获取与上下文切换，破坏了锁操作的原子性与局部性。 | 合并进第一个锁作用域，单次加锁完成所有路径与状态属性读取。 |
| **A-02** | **低·架构演进** | `CopierTransport.mqh:584`<br>Dual-Active 上行传输 | `copies = (m_connectedHubs > 1) ? 2 : 1` 在 XSUB 轮询机制下向双 Hub 连续发送 2 次以覆盖 Primary 与 Standby。 | 当其中一个 Hub 处于网络半开或降级时，多余的上行重发在客户端产生轻微开销。 | 在下一代协议规划中评估基于 ZMQ ROUTER/DEALER 的确定性双链路寻址方案。 |

---

## 2. 深度分析与缺陷逻辑证明

### 2.1 P-01【高·Hub 性能】高可用同步定时器中的同步多兆字节 SHA-256 阻塞

#### 代码位置
- `hub/src/cluster.rs:646-659`（Standby 节点同步循环）
- `hub/src/cluster.rs:1136-1145`（Primary 节点健康自检）
- `hub/src/cluster.rs:175-180`（`file_sha256` 实现）

```rust
pub fn file_sha256(path: &Path) -> String {
    match fs::read(path) {
        Ok(bytes) => crate::users::hex(&crate::users::sha256(&bytes)),
        Err(_) => String::new(),
    }
}
```

#### 根因剖析与运行影响
1. **稳态下的高频无谓 I/O 与内存分配**：
   在 HA 双机热备集群中，当系统达到稳态（Primary 与 Standby 的命令日志行数、序列号与配置版本完全一致）：
   ```rust
   let lines_differ = remote_st.cfg_lines != cfg_lines_count
       || remote_st.cmd_lines != cmd_lines_count
       || remote_st.max_cmd_seq != local_max_cmd_seq;

   let (cfg_h, cmd_h) = if lines_differ {
       (String::new(), String::new())
   } else {
       (file_sha256(&cfg_path), file_sha256(&cmd_path))
   };
   ```
   代码为了确认内容绝对一致，在 `lines_differ == false`（即稳态）时，**每隔 1 秒同时对 `config_revisions.jsonl` 和 `commands.jsonl` 执行全量 `file_sha256`**。
2. **堆内存震荡与 Tokio 异步工作线程阻塞**：
   - `fs::read(path)` 一次性将整个文件读入内存并分配 `Vec<u8>`。
   - 当 `config_revisions.jsonl` 积累至 20MB、`commands.jsonl` 积累至 8MB 时，Primary 与 Standby 节点每 1 秒在堆上分配 28MB 缓冲区、读取 28MB 磁盘数据、进行 SHA-256 哈希计算、然后再释放 28MB。
   - 计算可知：每分钟产生 **1.68 GB**、每小时产生 **~100 GB** 的纯无谓磁盘读与内存分配！
   - 更严重的是：该定时器运行在 Tokio 异步 runtime 的 worker 线程中，同步阻塞的文件 I/O 与哈希计算会霸占 worker 线程数十毫秒，拖慢其他并发的 HTTP API 与 WebSocket 事件处理。

#### 建议优化方案
1. **元数据预检缓存机制（Metadata Fast-Path）**：
   维护一个 `CachedFileHash { mtime: SystemTime, len: u64, hash: String }`。
   在计算前先调用 `fs::metadata(path)`（微秒级元数据操作）。若 `len` 和 `mtime` 与上一秒一致，直接返回已缓存的哈希值，跳过全量读取与 SHA-256。
2. **异步阻塞隔离与流式计算（Streaming Async）**：
   若元数据发生变更，使用 `tokio::task::spawn_blocking` 将 I/O 与哈希移出异步主循环，并通过 `std::io::BufReader` 流式更新 SHA-256，避免单次分配几十兆内存。

---

### 2.2 P-02【中·Hub 实时性】ZMQ 核心路由主线程中的看板快照 JSON 序列化抖动

#### 代码位置
- `hub/src/main.rs:3389-3398`
- `hub/src/api.rs:850-865`

```rust
// hub/src/main.rs:3389-3398
if poke_pending && last_poke.elapsed() >= Duration::from_millis(POKE_MIN_MS) {
    poke_pending = false;
    last_poke = Instant::now();
    if let Some(tx) = &poke_tx {
        if tx.receiver_count() > 0 {
            let body = std::sync::Arc::new(api::snapshot_text(&shared));
            let _ = tx.send(body);
        }
    }
}
```

#### 根因剖析与运行影响
1. **主路由循环的时间预算被侵蚀**：
   ZMQ 主线程是整个 Hub 最核心的事件分发泵，负责在亚毫秒级别转发跟单信号、平仓事件和修改指令。
   在 `main.rs:3395` 中，一旦看板有连接且状态脏标记被置位（每 200ms 最多一次），主线程直接调用 `api::snapshot_text(&shared)`：
   - 遍历并排序所有已注册节点；
   - 深拷贝全量仓位账本（`s.clone_view()`）；
   - 构建多达数十个 serde JSON 对象；
   - 调用 `serde_json::to_string()` 将其格式化为大型字符串。
   在数十个跟单账户和数百个持仓的高压场景下，该操作耗时可达数毫秒，直接导致订单转发线程出现毫秒级延迟抖动。
2. **WebSocket 广播中的重复深拷贝**：
   在 `api.rs:854` 中：
   ```rust
   changed = rx.recv() => {
       match changed {
           Ok(s) => {
               if socket.send(Message::Text((*s).clone())).await.is_err() {
                   break;
               }
           }
   ```
   虽然 `s` 已经封装为 `Arc<String>`，但为了传给 axum/tungstenite 的 `Message::Text`，代码执行了 `(*s).clone()`。当有 20 个运维监控窗口连接时，每一个快照推送都会进行 20 次完整的字符串深拷贝。

#### 建议优化方案
1. **序列化完全剥离出 ZMQ 路由主线程**：
   ZMQ 路由线程仅更新一个 `AtomicU64` 状态版本号，并通过非阻塞 channel 唤醒后台的 Tokio 异步 Worker。由 Worker 负责提取数据并生成快照 JSON。
2. **零拷贝 WebSocket 广播**：
   使用 Axum / Tungstenite 原生支持的 `axum::extract::ws::Utf8Bytes` 或 `Bytes` 接口，使多个 WebSocket 连接共享底层同一份引用计数内存切片，消除多客户端重复分配。

---

### 2.3 L-01【中·Hub 容错】收据去重表超限清退导致集群收据风暴

#### 代码位置
- `hub/src/main.rs:1096-1102`

```rust
// H-01 / H-DOS-01: Hard emergency cap against flood of spurious accounts/senders
if last_rcpt_relayed.len() > MAX_RCPT_RELAYED_KEYS {
    last_rcpt_relayed.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(60));
    if last_rcpt_relayed.len() > MAX_RCPT_RELAYED_KEYS {
        last_rcpt_relayed.clear();
    }
}
```

#### 根因剖析与运行影响
1. **全量 `clear()` 造成去重状态瞬间归零**：
   `last_rcpt_relayed` 用于记录向各个发送端已成功确认的快照哈希和中继时间，避免高频重复中继相同的 `RCPT`。
   当遇到大量异常账号或历史连接残留导致表内条目超过 `MAX_RCPT_RELAYED_KEYS (4096)`，且近 60 秒的活跃条目依然超限时，代码触发紧急兜底：`last_rcpt_relayed.clear()`。
2. **连锁惊群效应（Thundering Herd）**：
   全量清空后，后续所有接收端上报的快照收据在 `last_rcpt_relayed.get(&rcpt_key)` 中均匹配为 `None`。
   按照协议逻辑：
   ```rust
   let should_relay = match last_rcpt_relayed.get(&rcpt_key) {
       Some(...) => ...,
       None => true,
   };
   ```
   **每一个接收端的每一次常规汇报都将被无条件判定为“首次遇到”，从而立即向发送端广播一次 `RCPT`**！
   在数百个接收端连接的集群中，瞬间激增数千个重复的收据控制帧，造成网络带宽和 ZMQ 队列的短期拥塞。
3. **在路由热路径上同步遍历整表**：
   `last_rcpt_relayed.retain(...)` 直接运行在 `relay_receipts_from_stat` 内部（即每个 STAT 报文的处理路径）。一旦超限，每次收到 STAT 都会全量扫描 4096 个元素，进一步拖累单线程吞吐。

#### 建议修复方案
1. **基于最旧时间戳淘汰（LRU / Oldest Eviction）**：
   当容量达到上限时，淘汰最早更新的 25% 条目，或优先淘汰当前未在 `Registry` 中注册的离线账号，坚决不能执行一刀切的 `clear()`。
2. **定时淘汰脱离热路径**：
   将容量校验与修剪完全限制在 `last_rcpt_prune.elapsed() >= 60s` 的定时分支中，不在每个数据包到达时无条件执行全表遍历。

---

### 2.4 A-01【中·Hub 架构】持久化日志缺乏长稳运行 Compaction 机制

#### 代码位置
- `hub/src/config.rs:296-330`（`ConfigStore` 仅有 `replace_all`，无 `compact_journal`）
- `hub/src/commands.rs:244, 1243-1285`（`CommandStore` 的 `compact_journal` 仅在 `open` 时被调用）

#### 根因剖析与运行影响
1. **`ConfigStore` 日志单调无限增长**：
   在 `config.rs` 中，每次运维调用 API 推送配置（`push`）、EA 自动采纳配置（`adopt`）或回滚配置（`rollback`），都会向 `config_revisions.jsonl` 追加完整的 INI 配置文本（数 KB 到数十 KB）。
   代码中虽然预留了 `replace_all` 方法，注释写着：
   > *"Used when Primary performed compaction or local state is ahead of Primary's lines."*
   但纵观整个 Hub 代码，**没有任何地方实现了 Primary 触发配置压缩的逻辑**！该文件将持续单调增长，直至数周或数月后占用数十甚至数百兆磁盘空间。
2. **`CommandStore` 运行时零压缩**：
   `commands.rs` 内部实现了完善的 `compact_journal` 逻辑，能够剔除终态且超出保留期的历史指令。然而，该函数**仅在 Hub 进程启动（`CommandStore::open`）时调用一次**！
   作为设计为 24/7/365 不停机的高可用金融服务基础设施，生产环境下的 Hub 往往连续运行数月而不重启。这意味着在整个运行周期内，`commands.jsonl` 从未在运行时执行过压缩。
3. **连锁反应**：
   日志文件体积膨胀直接导致：
   - 节点冷重启耗时急剧增加；
   - 恶化 **P-01** 中的磁盘 I/O 和 SHA-256 计算耗时；
   - Standby 节点在新加入或网络重连时，拉取全量日志的同步传输开销倍增。

#### 建议架构演进方案
1. **在 `config.rs` 中实现 `compact_journal`**：
   遍历当前配置日志，每个节点仅保留最新版本以及最近 N（例如 5）个历史版本，将废弃的旧版本配置物理剔除。
2. **引入运行时定时维护任务（Scheduled Runtime Compaction）**：
   在集群维护线程（例如每日凌晨低峰期或当文件行数超过阈值如 10,000 行且死条目超过 50% 时），以原子临时文件方式在后台执行 `compact_journal`，并在完成时更新内存状态与文件句柄。

---

### 2.5 P-03【中·MQL 性能】`CopierWaitMs` 忙等自旋锁死 CPU 与云 VPS 限速风险

#### 代码位置
- `src/Experts/CopierReceiver.mq4:3327-3335, 3779, 4227`

```mql4
// OPT-01: Microsecond-precision wait replacement for Sleep(), which is silently ignored in OnTimer()
void CopierWaitMs(const int waitMs)
  {
   if(waitMs<=0) return;
   long start=CopierNowMs();
   while(CopierNowMs()-start<waitMs)
     {
      // busy-wait to provide genuine flow control in timer-driven EA
     }
  }
```

#### 根因剖析与运行影响
1. **MQL 中 `Sleep()` 的限制与忙等权衡**：
   在 MetaTrader 平台中，`Sleep()` 函数在 `OnTimer()` 事件处理函数内部会被底层静默忽略（MQL 官方设计规范）。
   原作者为了对批量平仓或重试扫荡提供流控（如每发 10 笔订单等待 20ms、二次扫荡前等待 30ms），引入了 `CopierWaitMs`。
2. **空循环在云 VPS 上的严重副作用**：
   `while(CopierNowMs()-start < waitMs) {}` 是一个完全不释放 CPU 时间片的纯粹死循环。
   在 20ms~30ms 的持续忙等期间，单个 CPU 核心将被 100% 占满。
   外汇交易通常部署在 1 vCPU 或 2 vCPU 的共享型 VPS（如 AWS t3/t4g、阿里云突发型实例或专属外汇 VPS）上：
   - 持续的 CPU 尖刺会迅速耗尽 VPS 的 CPU 突发积分（Burst Credits），导致虚拟机被宿主机强制物理降频（CPU Throttling）；
   - 在多货币对、多 EA 共用终端的环境中，忙等会阻塞终端的 UI 渲染线程和行情推送线程，反而引起意料之外的成交滑点。

#### 建议优化方案
1. **改用异步事件泵驱动（Non-blocking Pump Re-arm）**：
   当需要暂停 20ms 时，无需在当前循环中硬阻塞，而是：
   - 记录当前执行队列游标；
   - 调用 `g_pump.ArmFast(waitMs)` 激活高精度快速定时器；
   - 立即从当前的 `OnTimer` 回调中返回，释放 CPU 给终端与操作系统；
   - 20ms 后由快速定时器唤醒，无缝继续执行剩余批次。
2. **备选降级方案（Windows API Sleep）**：
   若不改变执行流结构，可通过动态链接库引入 `kernel32.dll` 的原生 `Sleep(DWORD dwMilliseconds)`，在 MQL 定时器中真正挂起线程让出 CPU，彻底消除 100% 空转。

---

### 2.6 L-02【低·Hub 代码】`cluster.rs` Primary 校验中无谓的双重锁获取

#### 代码位置
- `hub/src/cluster.rs:1115-1131`

```rust
let (my_cfg, my_cmd, my_seq, cfg_p, cmd_p, u_p, c_p) = {
    let s = st.lock_or_recover();
    (
        s.cfg.total_lines(),
        s.cmds.sync_stats().0,
        s.cmds.sync_stats().1,
        s.cfg.path().to_path_buf(),
        s.cmds.path().to_path_buf(),
        s.users.path().to_path_buf(),
        s.cluster.curve_clients_path.clone(),
    )
};
let n_p = {
    let s = st.lock_or_recover();
    let x = s.notif_store.lock_or_recover().path().to_path_buf();
    x
};
```

#### 根因剖析与修复
- 在第 1116 行获取 `st` 互斥锁提取了前 7 个字段并在第 1126 行释放；
- 在第 1128 行又紧接着再次获取同一把锁 `st`，仅仅为了读取 `s.notif_store.lock_or_recover().path().to_path_buf()`；
- 两次加锁之间没有任何竞争优势，反而增加了锁竞争概率与互斥体开销。
- **修复方案**：直接在第 1116 行代码块内一并提取 `n_p`，合并为单次锁获取。

---

## 3. 全栈架构不变量与已有机制验证结果

在本次审计中，除了剖析上述优化点外，我们对系统核心机制的不变量与既有实现进行了交叉验证，确认以下关键设计与代码高度稳固：

### 3.1 客户端与协议层验证（MQL4 / MQL5）
1. **反向跟单止损/止盈镜像保真度**（`CopierDefs.mqh: CopierMirrorStopInverted`）：
   代码正确识别了反向跟单时常规绝对价格比较的陷阱。对于反向订单，止损与止盈被严格抽象为**相对点数幅度（Magnitude）**，并根据本端反转后的交易方向（Buy/Sell）重新投影在入场价的亏损侧和盈利侧，完全规避了止损设在盈利侧导致被券商瞬间拒绝的严重隐患。
2. **交易时段与行情时效多级缓存**（`CopierSymbol.mqh`）：
   - `CopierInTradingSession` 接入 30 秒时段跳变防抖缓存，且通过 `TimeToStruct` 与券商本地时钟日历深度对齐；
   - `CopierSymVerdictCache` 提供单次循环内的零分配（Zero-allocation）快速判定，使得上百个持仓的大网格订单在单次遍历中无需重复查询属性。
3. **配置文件写操作崩溃安全性**（`CopierConfig.mqh`）：
   - `CopierIniWriteAll` 采用 `.tmp` 先行写入校验 -> 主文件替换 -> 校验大小的防撕裂机制；
   - `CopierIniReadAll` 显式检测若主文件意外缺失，自动降级读取 `.tmp` 镜像，提供了可靠的异常断电防御能力。
4. **阶梯式流控退避机制**（`CopierState.mqh: CopierBackoff`）：
   严格区分了常规开仓退避（最高 24 小时）、平仓退出退避（上限 60 秒）和参数修改退避（上限 60 秒），确保平仓退出的重试优先级远高于普通指令，防止风控单被长期冻结。

### 3.2 服务端 Hub 核心层验证（Rust）
1. **内存与路由零解码转发**（`envelope.rs`）：
   Hub 仅解析路由必需的 `T=` 类型标签和最小心跳字段，交易报文载荷保持不透明字节流转发。有效杜绝了因服务端格式解析版本不一致而破坏协议 payload 的风险。
2. **高可用集群裂脑防护与锁安全**（`cluster.rs` / `lockx.rs`）：
   - 所有共享互斥锁均通过 `lock_or_recover()` 接入防 Poisoning 兜底，杜绝了单线程 panic 导致全局死锁崩溃；
   - 故障转移（Failover）与接管（Failback）具备严格的 Epoch 周期递增与双向对齐校验，Standby 在未同步完成前坚决不更新 Epoch，从根源上阻止了数据倒退与分叉。
3. **零停机动态 TLS 与 HTTPS 监听**（`tls.rs`）：
   实现了基于 Rustls 的热加载与 ACME HTTP-01 自动证书签发，支持自定义单域名与泛域名自动适配。

---

## 4. 推荐落地演进路线图（分阶段建议）

为保持系统迭代的绝对稳健，建议按照以下优先级分阶段推进上述优化方案，且在每一阶段变更前后完整运行测试套件：

### 第一阶段：零风险轻量优化（建议直接排期）
- **L-02 合并 `cluster.rs` Primary 校验锁作用域**：仅调整局部变量提取位置，单次锁获取，代码纯局部改进。
- **L-01 改进收据清退算法**：将 `last_rcpt_relayed` 的全量 `clear()` 改造为淘汰最旧 25% 条目或针对非活跃发送端的精准淘汰，消除潜在的收据风暴隐患。

### 第二阶段：性能瓶颈解除（建议近期安排）
- **P-01 HA 1 秒定时器文件哈希元数据缓存**：引入 `CachedFileHash`，通过 `(mtime, len)` 快速比对跳过稳态下的磁盘读取与 SHA-256，每小时减少 ~100GB 无谓 I/O，并将其计算放入 `spawn_blocking`。
- **P-02 看板序列化与 ZMQ 核心路由线程解耦**：将 `snapshot_text` 剥离至独立后台异步线程，主线程仅做信号触发；WebSocket 发送使用 `Bytes` 避免深拷贝。
- **P-03 MQL `CopierWaitMs` 消除忙等**：将批量平仓与扫荡流控改造为 `g_pump.ArmFast` 异步唤醒，或接入系统原生 Sleep API，消除 100% CPU 占用。

### 第三阶段：架构长稳演进（建议长期维护计划）
- **A-01 实现 `ConfigStore` 压缩与运行时定期维护**：为 `config.rs` 补充 `compact_journal` 并在 Hub 引入每日或容量触发的运行时 Compaction 机制，确保数月长稳运行期间日志体积严格受控。

---

## 5. 结论

`mt-copier` 全栈工程在经历多轮演进与深度加固后，核心的跟单复制协议、双机热备 HA 架构、订单反向映射与客户端状态管理已具备极高的成熟度与健壮性。当前全套 176 项 Rust 单元测试与 19 项端到端集成测试保持 100% 全绿通过。

本报告指出的优化空间主要集中在**长期高负荷运行下的 CPU 效率提升、磁盘 I/O 降噪、日志生命周期闭环以及核心调度线程的防抖保护**。按照本报告提出的演进路线推进，将进一步巩固系统在高并发、长时间不停机及多节点集群环境下的顶级工业级品质。
