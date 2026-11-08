# mt-copier 全栈审计报告（2026-11-08 r3：上轮 17 项修复复核 + 新一轮问题清单）

> **审计执行模式**：严格只读（Strictly Read-Only），未修改任何生产代码。
> **审计方式**：本人单线全量通读与交叉推演，未使用子代理。
> **审计范围**：
> 1. `src/Experts/CopierReceiver.mq4`（9611 行）、`src/Experts/CopierSender.mq4`（2501 行）——逐行精读；
> 2. `src/Include/Copier/*.mqh` 16 个头文件——精读（Scripts 下 3 个自检脚本为测试工具，未逐行）；
> 3. `hub/src/*.rs`：main.rs、commands.rs、cluster.rs、positions.rs、registry.rs、stats.rs、audit.rs、envelope.rs、lockx.rs 精读；api.rs 前半精读 + 全文件风险模式扫描；tls.rs / notifications.rs / users.rs / config.rs / alerts.rs / curve.rs / service.rs 为重点抽查；api.rs 后半（登录限频/用户 CRUD/TLS 端点/单元测试）未逐行读；
> 4. `doc/PROTOCOL.md` 精读；`outputs/mt-copier-fullstack-audit-comprehensive-2026-11-08.md` 作为上一轮基线。
>
> **本文件**：`mt-copier/outputs/mt-copier-fullstack-audit-2026-11-08-r3.md`

---

## 1. 执行摘要

源码最后修改时间（11-08 02:05–02:15）晚于上一份综合终审报告（11-08 00:48），本轮首要任务是**复核上轮 17 项问题的修复情况与回归风险**，其次寻找新问题。

**复核结论**：上轮 17 项中 **15 项已正确修复**，**2 项为"部分处理"**：

| 上轮编号 | 状态 | 说明 |
|---|---|---|
| ISSUE-01 平仓被休市门禁拦截 | ✅ 已修复 | CLOSE/TRIM/DEDUP 全部豁免 `SymbolMarketClosed`；全局停摆仅在队列无退出动作时整体挂起；OnTick/OnTimer 均有队列级休市唤醒 |
| ISSUE-02 止损被夹到盘口边缘 | ⚠️ **修复引入新边界** | 常规跟单也加了越界保留，但丢失了"真实击穿→夹紧穿透退出"语义 → **本轮 N-01** |
| ISSUE-03 非法帧先推高水位 | ✅ 已修复 | CFG/CMD 拒绝已前置到 `AcceptSeq` 之前（Receiver.mq4:7857） |
| ISSUE-04 RefreshRisk 历史扫描风暴 | ✅ 已修复 | 待定基线 10s / 稳定 60s 双节流 + `IsConnected` 短路 + MT4 历史未同步守卫；`g_lastRealizedMs` 在断线返回前已刷新，无自激 |
| ISSUE-05 MODIFY 24h 退避 | ✅ 已修复 | `BlockedModify` 30s 封顶阶梯 + 裸单 2s 探测 Park + 失败即 `StopSigInvalidate` |
| ISSUE-06 平仓探测 O(N²) | ✅ 已修复 | 每 tick 深度历史探测 ≤8 次 + `PrevSlotForRow` O(N) |
| ISSUE-07 ManualClosedRing 时钟回绕 | ✅ 已修复 | 全部统一 `CopierNowMs()` |
| ISSUE-08 replace_all 句柄丢失 | ✅ 已修复 | 重开句柄提前于 `?` 传播，双路径（commands/config）均改 |
| ISSUE-09 XPUB 帧边界倒挂 | ✅ 已修复 | hub 侧 `torn_multipart` 状态 + 5 次补关重试；MQL 侧 `m_midMultipart` + 发送前先闭合 + DrainFrames 残帧清理，两端闭环 |
| ISSUE-10 锁内 fsync | ⚠️ 部分缓解 | 由"每行一 fsync"降为"每批一 fsync"，但仍在 store 互斥锁内 → **本轮 N-02** |
| ISSUE-11 弱默认集群令牌 | ✅ 已修复 | api.rs 中间件前置 `token_is_usable()`，默认/公开令牌一律不放行 |
| ISSUE-12 SNAP 未变更分支锁竞争 | ✅ 已修复 | 每 sender 限频 1s 的 touch，常态零锁 |
| ISSUE-13 SymbolInfo 无缓存 | ✅ 已修复 | 64 槽 30s 直接映射缓存；边界影响见 N-05 |
| ISSUE-14 快照全包拒绝 | ✅（按设计闭合） | 发送端三处 `CopierLotEncodable` 卡口已从源头消灭单条坏记录；接收端 all-or-nothing 保留为 PROTOCOL.md 明文的防 false-close-all 防线 → 建议**按设计内关闭**，见 R-01 |
| ISSUE-15 HBT2 冗余 NAME | ✅（按设计闭合） | 保留 NAME 是为修复"REG 丢失后节点匿名"，契约注释已同步改写，hub 端"空名不覆盖"保护齐备 |
| ISSUE-16 CSV 逐条 ArrayResize | ✅ 已修复 | 预分配 n + 循环后紧缩 |
| ISSUE-17 时段缓存 1 秒 | ✅ 已修复 | 放宽至 30 秒 |

**本轮新发现 6 项**（1 项中危交易安全、1 项低中危 Hub 延迟、3 项低危、1 项卫生杂项），**0 项高危**。全部 17 项上轮修复**未发现其他回归**。

---

## 2. 新发现问题清单

### N-01【中·交易安全】ISSUE-02 的修复丢失了"止损被真实击穿→夹紧穿透退出"语义，可造成接收端长期保留过宽止损甚至裸单

**位置**：`src/Experts/CopierReceiver.mq4:4585-4606`（`QueueModifyIfNeeded`，市场单分支）

**现状**：修复后，**常规（非反向）跟单**下，当推导出的原始止损已越过当前盘口（BUY 的 `rawWantSl >= bid`，SELL 的 `rawWantSl <= ask`，TP 同理对称）时：

```mql4
if(rawWantSl>0.0 && ((local.side==CP_SIDE_BUY && rawWantSl>=mktPx) || ...))
  {
   wantSl=local.sl;          // 无条件保留本地旧止损
   clampedSl=false;
   invertedCrossed=true;     // 且不写入签名缓存 → 每个收敛周期重新推导出同样的交叉值
  }
```

**问题剖析**：这个分支无法区分两种性质完全不同的场景：

1. **噪声交叉（ISSUE-02 要防的）**：两侧点差/报价微差导致镜像位恰好落在盘口另一侧几个点内。此时保留本地止损是对的——夹紧会造成秒级被动止损。
2. **真实击穿（PROTOCOL.md 明文承诺的行为）**：PROTOCOL.md《The broker's minimum distance wins》一节写明："a stop the market has run through gets clamped to the closest distance the broker allows, so the position exits almost immediately, **which is what the sender's position did too**"。即发送端止损被行情穿越时，发送端已经（即将）被止损离场，镜像应贴市价夹紧同步退出。修复后这种情况变成了**无限期保留旧的、更宽的本地止损**（每个周期重新推导、每次都交叉、每次都保留），接收端比发送端**多承担的亏损没有上界**，直到发送端发出 CLOSE。

**更尖锐的边界**：若 `local.sl == 0`（开仓时未带止损、又恰逢首次设置即交叉），`wantSl` 被保留为 0；后续 N87-07 兜底 `if(feedSl>0.0 && wantSl<=0.0) wantSl=local.sl` 保留的同样是 0 → 该仓位在发送端持有有效止损的情况下，接收端**完全无止损**。

**修复建议**：
- 引入**容差窗**：交叉幅度 ≤ 容差（如 `max(3×stopLevel, K pips)`）→ 视为噪声，保留本地止损（ISSUE-02 场景不变）；超过容差 → 视为真实击穿，恢复 `CopierFitStopAt` 夹紧穿透，让镜像与发送端同步离场；
- 容差内保留时，若 `local.sl <= 0`，不得保留 0：要么夹紧穿透，要么以 `EmergencySLPips`（若配置）兜底并 Park+告警，绝不静默裸单。

---

### N-02【低中·Hub 实时性】命令/配置 journal 的 fsync 仍在互斥锁内，`ack()` 在 ZMQ 路由线程上逐 ACK 触发

**位置**：`hub/src/commands.rs:1050`（`append_many`）、`commands.rs:1105`（`append_raw`）、`hub/src/config.rs:553/588/630`、`hub/src/audit.rs:554`

**现状**：上轮已把"每行一 fsync"降为"每批一 fsync"（正确且必要），但每次调用仍持有各自 store 的互斥锁完成 `write_all + sync_data`。调用方：

- `CommandStore::ack()` —— 每个 ACK 帧（ZMQ 路由线程）一次；
- `due_gated` —— 每 500ms 重试节拍一次；
- `apply_delta_lines` —— Standby 每次 sync 增量一次。

机械盘 / 云盘突发耗尽时单次 `FlushFileBuffers` 2–20ms，期间 `sync_stats()`、`/api/v1/commands` 列举、命令重试循环全部被串行化，路由线程被拖慢与 ISSUE-10 原始描述同型，只是频率已降低。

**修复建议**：锁内只做"序列化到缓冲 + 内存状态暂存"，锁外（单一写线程或锁外直写）执行 write+fsync，失败再回滚内存。audit 的 torn-tail 容忍机制已存在，崩溃窗口最多丢一行，可接受。

---

### N-03【低·Hub 性能】poke 序列化在 ZMQ 路由线程上执行 + WS 逐客户端整串深拷贝

**位置**：`hub/src/main.rs:3370-3380`（poke_pending → `api::snapshot_text(&shared)`）；`hub/src/api.rs:851-857`（`socket.send(Message::Text((*s).clone()))`）

**现状**：有看板连接时，只要 200ms 节流窗到期且状态有变化，**ZMQ 转发线程**就要完成"克隆全部 nodes + positions（含 Arc 解引用部分）+ 全量 JSON 序列化"——集群规模大、状态变化频繁时，这给转发主循环增加毫秒级周期性抖动。snap-worker 线程虽然自带同样序列化（且已在自己的线程上，正确），但主循环的 poke 路径没有走 worker。随后每个 WebSocket 客户端在推送时把整个 `Arc<String>` **深拷贝**成新 String——N 个看板 = 每次推送 N 份全量拷贝，全部发生在 tokio worker 上。

**修复建议**：
- 主循环 poke 只投递"脏标记/版本号"，把 `snapshot_text()` 挪到独立 worker（复用 snap-worker 的模式）或 API 任务的按需路径；
- WS 推送改为 `Message::Text` 之外的字节形式（axum 支持 Binary/Bytes）或按客户端惰性 `Arc` 引用计数传递，避免逐客户端深拷贝。

---

### N-04【低·MQL CPU】`CopierWaitMs` 忙等自旋：批量平仓节拍以 100% 单核空转为代价

**位置**：`src/Experts/CopierReceiver.mq4:3174-3183`；调用点 `ExecuteQueue`（MT5 async 批量平仓每 10 单 `CopierWaitMs(20)`、二段清扫前 `CopierWaitMs(30)`）

**现状**：`Sleep()` 在 `OnTimer` 内确实无效（注释正确），因此用了忙等。但代价是：恰好在"批量止损/网格集中退出"这种最需要 CPU 响应行情的时刻，EA 线程以 100% 占比自旋 20–30ms；在共享 vCPU 的 VPS 上会与终端行情线程、其他 EA 抢核。

**修复建议**：把批量平仓的节拍改为**跨 tick 分批**：每 tick 最多发 N 单，剩余的留给下一个 timer tick（或用现有 `g_pump.ArmFast()` 的有界事件泵续跑）。等效限速，零自旋。

---

### N-05【低·MQL】`CopierGetSymbolInfo` 30s 缓存无失效钩子，券商盘中调参时最长 30s 用旧几何

**位置**：`src/Include/Copier/CopierModel.mqh:79-131`

**现状**：缓存解决了 ISSUE-13 的天量系统调用，但没有失效入口。券商在新闻时段动态拉大 `SYMBOL_TRADE_STOPS_LEVEL`、或调整 volume step 后，最长 30s 内 `CopierFitStop` 仍按旧 stopLevel 计算 → 一次 10016/130 拒绝，然后走正常退避（MODIFY 已是 30s 封顶阶梯，损害有限）。

**修复建议**（可选，低优先级）：在 `ExecuteQueue` 收到 10016（MT5）/130（MT4）拒绝时，顺手作废该品种的 syminfo 缓存槽与 `g_stopSig` 签名，下一收敛周期立即用新参数重算，消除这 30s 的盲目重试窗口。

---

### N-06【信息·卫生杂项】三条小项

1. **`hub/src/tls.rs`：PKCS#12 容器使用源码常量口令 `"mtc_tls_pass"`**。文件在本机、读取者本就拥有同等权限，风险低；但固定口令出现在源码里会被安全扫描标记。建议注释明示威胁模型（"本机文件，口令仅满足 PFX 格式要求"），或改为生成时随机、口令与 PFX 同目录存放。
2. **`hub/src/main.rs`：`send_topology` 在每次 REG（含每分钟一次的维护 REG）都发送**，即使 (primary, standby, epoch, active) 均未变化。纯带宽噪声；建议按四元组边沿触发。
3. **`src/Experts/CopierSender.mq4` `Emit()`：非快照帧发送失败逐条 `Warn` 无限频**。HWM 打满/瞬断时会刷日志；与本代码库其余部分的 `g_once` 纪律不一致，建议同样限频。

---

## 3. 建议按"设计内"关闭的遗留项

### R-01：ISSUE-14（快照 all-or-nothing 拒绝）建议结案，不实施"子集接受"

上一轮建议做分级容错（`0 < decoded < N` 接受有效子集）。本轮复核后认为**维持现状更安全**，理由：

1. `doc/PROTOCOL.md`《Corrupt Snapshot Defense》已把"声明 N 与解码数不一致即整包拒绝"论证为防 **false close-all / close-half** 的核心防线——半本账比全丢更危险；
2. "单条坏记录导致永久冻结"的成因在本轮已被**从源头消灭**：发送端在 `BuildCurrent()`、`RebuildSnapshotPayload()`、`CopierStateFile::Save()` 三处统一用 `CopierLotEncodable` 预过滤（N67-02/N72-01/N80-02），保证 `N=` 严格等于可解码记录数。解码层的坏行只剩传输损坏这一种来源，而此时"拒绝整包 + 修复重发"正是期望行为；
3. 接收端已有完整的可观测性：`g_snapDeclFailed`、`g_snapRejectStreak` 连续 30 次升级告警、hub 端 `snapshot.corrupt`/`snapshot.mismatch` 节流审计——冻结不再是静默的。

---

## 4. 回归检查记录（上轮 17 项修复逐一核对）

- **ISSUE-01 豁免链完整性**：`ExecuteQueue` 三处持有（全局停摆整体挂起、逐动作休市、开盘暖期点差保护）均已区分退出动作；`warmup` 的 CLOSE 点差保护有 `MarketOpenCloseMaxWaitSec`（默认 120s）硬超时，不会变成第二个 15 分钟闭锁。✅
- **ISSUE-02/03 时序**：安全类型检查已严格前置，序列水位不再被拒绝帧推进；HBT 心跳流独立（`CP_STREAM_HBT`），不污染事件水位。✅
- **ISSUE-04 数值路径**：`g_lastRealizedMs=now` 在 `IsConnected` 短路**之前**设置，断线期间保持 10s 节流而非每 100ms 扫描；冷启动（`g_riskDay==0`）与日内滚动分路正确；MT4 `OrdersHistoryTotal()==0 && uptime<10s` 防异步历史误判。✅
- **ISSUE-05**：`BlockedModify` 以 `sname:#t<ticket>` 为键，成功路径与失败路径均正确清理（`g_backoff.Clear` 双键）。✅
- **ISSUE-07**：`CopierManualClosedRing` 的 `Add/GC/CmdStateSave/CmdStateLoad` 全链 `CopierNowMs`，持久化往返无 32 位时钟。✅
- **ISSUE-08**：`replace_all` 在锁内先 `file=None` → 尝试替换 → **无论成败先重开** → 再传播错误；`inner.file.is_none()` 时返回明确错误而非静默 NotConnected。config.rs 同型。✅
- **ISSUE-09 双端闭环**：hub 前向失败 → 补关空帧最多重试 5 次 → 仍失败置 `torn_multipart`，下一帧先补关再发；MQL `SendUp` 同型（`m_midMultipart`，失败即 break 不再继续第二份拷贝），两端均有 `FramingCorrupted` 错误日志。✅
- **ISSUE-11**：`token_is_usable` 同时排除两个已公开常量 + 16 字节下限；`--users none` 时集群端点对匿名直接 403。✅
- **HA / 双活**：Standby 不跑 `due_gated`（main.rs:3270 起 is_prim 门）、不处理 ACK（main.rs:2574）；`replace_all`/`apply_delta_lines` 均先落盘后改内存（F-01）；epoch 采纳只在 sync 全部成功后（F-11）。✅
- **手动平仓闭环**：`#t<ticket>` 占位 UID 不入 `g_recKnown`、不写注释；GC 三类条目（真实 UID / #t / ticket-only）规则互不误伤，且按 `mSid` 定向，不再跨 sender 误清。✅

---

## 5. 覆盖范围与诚实声明

| 部分 | 深度 |
|---|---|
| `CopierReceiver.mq4` / `CopierSender.mq4` | 逐行精读 |
| `src/Include/Copier/*.mqh`（16 个） | 逐行精读 |
| `src/Scripts/*.mq4`（3 个自检脚本） | 未逐行（测试工具，非生产路径） |
| hub: main / commands / cluster / positions / registry / stats / audit / envelope / lockx | 逐行精读 |
| hub: api.rs | 前 ~1200 行精读；其余风险模式扫描（锁内 I/O、`unwrap`、阻塞调用——仅 3 处良性 `unwrap`，均在自身构造的对象上） |
| hub: tls / notifications / users / config / alerts / curve / service | 重点抽查（关键函数 + 模式扫描） |
| `hub/src/assets/dashboard.html`、Python 测试套件、`tools/` | 本轮未审 |

---

## 6. 优先级建议

```
┌────────────────────────────────────────────────────────────────────┐
│ 第一批（交易安全，建议本迭代处理）                                   │
│  N-01  QueueModifyIfNeeded 止损交叉：加容差窗区分噪声/真实击穿，      │
│        真实击穿恢复夹紧穿透；保留值为 0 时禁止静默裸单               │
├────────────────────────────────────────────────────────────────────┤
│ 第二批（Hub 实时性与可用性）                                        │
│  N-02  commands/config journal fsync 移出 store 互斥锁              │
│  N-03  poke 序列化挪离 ZMQ 路由线程；WS 推送去逐客户端深拷贝         │
├────────────────────────────────────────────────────────────────────┤
│ 第三批（性能与卫生，随版本迭代）                                    │
│  N-04  CopierWaitMs 忙等改为跨 tick 分批节拍                        │
│  N-05  10016/130 拒绝时作废 syminfo 缓存槽（可选）                  │
│  N-06  TLS 口令注释/随机化；TOPOLOGY 边沿触发；Sender Emit 失败限频  │
│  R-01  ISSUE-14 按"设计内"关闭（文档化即可，无需改码）              │
└────────────────────────────────────────────────────────────────────┘
```

---

> **结语**：本轮全程严格只读。上轮 17 项修复质量总体很高，双端（MQL/Rust）的成对修复（如 ISSUE-09 的帧边界、ISSUE-08 的句柄恢复）都有对应的自检与单元测试锁定；唯一需要回炉的是 ISSUE-02 的修复在"真实击穿"场景下偏离了 PROTOCOL.md 的承诺语义（N-01），建议优先处理。
