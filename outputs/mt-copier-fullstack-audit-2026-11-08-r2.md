# mt-copier 全栈代码审计与优化评估（2026-11-08 / r2 独立复核轮）

> **审计模式**：严格只读。未修改任何源码、配置或运行环境。
> **审计方式**：单进程整文件顺序通读（不使用子代理），以便跨模块串联同一不变量。
> **基线**：工作区当前源码（含第 112 轮及 11-08 报告之后的改动）。
> **输出**：本文件 `mt-copier/outputs/mt-copier-fullstack-audit-2026-11-08-r2.md`。

---

## 0. 覆盖声明（先说清楚读了什么、没读什么）

**已逐行通读**

| 范围 | 文件 |
|---|---|
| MQL 核心库 | `CopierDefs.mqh`、`CopierCodec.mqh`、`CopierState.mqh`、`CopierTransport.mqh`、`CopierConfig.mqh`、`CopierModel.mqh`、`CopierSizing.mqh`、`CopierRisk.mqh`、`CopierPeers.mqh`、`CopierSymbol.mqh`、`CopierFilter.mqh`、`CopierIgnore.mqh`、`CopierPump.mqh` |
| MQL 程序 | `CopierSender.mq4`（全量 2494 行）、`CopierReceiver.mq4` 的全部热路径（配置装载、账号扫描、`ConvergeSender`、`ExecuteQueue`、`PushAction`、`QueueModify/Trim`、`DedupLocal`、`RefreshRisk`、`HandleSnapshot`、`AcceptSeq/RouteMessage`、`OnTimer`、`OnTick`）以及面板/锁/状态文件段落 |
| Rust Hub | `main.rs` 的 ZMQ 事件循环与转发段、`commands.rs`（`ack`/`due_gated`/`replace_all`/`append_many`/`load`）、`cluster.rs` 的 token 与角色判定、`config.rs` 的 `validate_ini`、`api.rs` 的鉴权中间件/路由表/WS/locales、`positions.rs` 的解析与视图 |
| 文档 | PROTOCOL 摘要、HANDOFF/HA-FINAL-PLAN 约束、11-07-r3 与 11-08 两份上一轮审计（用于排除已修项） |

**未逐行通读（仅结构级/抽样）**：`tls.rs`(1745)、`notifications.rs`(2229)、`users.rs`(1309)、`audit.rs`(1244)、`registry.rs`(1013)、`alerts.rs`、`curve.rs`、`stats.rs`、`CopierSelfTest.mq4`(3345)。这些模块的结论仅限我实际读到的片段，下文不会对未读部分下判断。

---

## 1. 结论摘要

本轮共 14 项发现（**新发现 11 项**，含 2 项高危；3 项为对既有设计的健壮性/性能意见）。同时复核确认上一轮报告中的 6 个高危缺陷**在当前代码中已修复**（见第 5 节），不再重复计入。

### 1.1 新发现

| 编号 | 级别 | 模块 | 一句话 |
|---|---|---|---|
| **N-01** | **高** | Receiver `ExecuteQueue:3327` | `SymbolMarketClosed()` 对 **CLOSE/TRIM/DEDUP 同样生效**，与"平仓永不被拦"的既定原则直接冲突；叠加 15 分钟队列休眠后，退出动作最长可被推迟约 15 分钟 |
| **N-02** | **高** | Receiver `RefreshRisk:5363` | 当日内权益基线无法建立（终端断线、历史不可读）时，`else if(g_riskDayStartEquity<=0.0 \|\| …)` 使**每 100ms 重走一遍全部交易历史**，形成自伤式 CPU 风暴 |
| **N-03** | 中 | `CopierDefs.mqh:1317` + `CopierSizing.mqh:224` | A86-02 取消了对"发送端 SL 在错误一侧"的拒绝；配合 `CopierFitStop` 的夹紧逻辑，畸形 SL 会被**夹到市价附近 → 立即止损**，而非"拒绝并保留原止损" |
| **N-04** | 中 | Receiver `PushAction:2984` / `ExecuteQueue:3910` | MODIFY 失败走的是**完整 1m→24h 阶梯**，被券商持续拒绝的止损更新可把镜像"无止损"状态保持数小时，且不会回退到 `EmergencySLPips` |
| **N-05** | 中 | Hub `commands.rs:485` | `replace_all()` 在 `inner` 锁内置 `file=None` 后用 `?` 传播错误；一旦 `atomic_replace_file`/重新 `open` 失败，**命令日志永久进入 NotConnected 状态**，只有重启进程才能恢复 |
| **N-06** | 中 | Hub `commands.rs:1042` | `append_many()` 的 `write_all + sync_data()` 在**全局 `inner` 锁内**执行；每条 ACK/due/issue 都在持锁期间 fsync，直接阻塞同锁的 ZMQ 转发线程 |
| **N-07** | 中 | Receiver `RouteMessage:7843` | `CFG`/`CMD` 的类型拒绝被放在 `AcceptSeq()` **之后**，伪造帧会推进该发送端的 event 水位，可用一个超大 SEQ 让其后续真实事件全部被丢弃 |
| **N-08** | 中 | Sender `CopierModel.mqh:1348` | `CopierIsTicketClosedInHistory()` 每次探测都 `PositionsTotal()` 全表扫 + `HistorySelectByPosition()`；平仓风暴时对 N 个消失槽位各探测一次，是 O(N²) 且每次重置历史选区 |
| **N-09** | 中低 | `CopierTransport.mqh:584` | `SendUp()` 在 HA 下对**数据帧也双发**，每个接收端的下行带宽翻倍（最坏 380KB → 760KB/次），而双发并不能解决它声称要解决的跨管道乱序 |
| **N-10** | 低 | `CopierState.mqh:1646` | `CopierManualClosedRing` 用 `GetTickCount()`（32 位、49.7 天回绕）存时间，与全项目 `CopierNowMs()` 混用；回绕后 `ageMs` 变负，TTL 失效 |
| **N-11** | 低 | `CopierCodec.mqh:858` | `CopierPayloadHbt2()` 仍完整打包 `NAME=`，与同文件 827 行"REG 与 HBT2 唯一差别是不带 NAME"的契约相反 |

### 1.2 优化建议（非缺陷）

| 编号 | 收益 | 内容 |
|---|---|---|
| **O-01** | 中 | `CopierGetSymbolInfo()` 无缓存。`ConvergeSender` 每个已匹配持仓每轮要取 ~3–4 次（`ComputeTargetLotsForMirror`、`QueueModifyIfNeeded`、`QueueTrimIfNeeded`），MT5 每次 9 个终端 API 调用。300 持仓 × 4 轮/s ≈ 4.3 万次调用/s，粗估占单核 3–6% |
| **O-02** | 中 | `HandleSnapshot` 采用"全包拒绝"：只要 `N` 与实际可解码条数不等（哪怕 2048 条里 1 条 lots 非法），整个快照被丢弃，且发送端字节省略不变 → 除非那条持仓变化，否则**收敛永久停摆**，日志只有一行被限流的 `CRITICAL` |
| **O-03** | 低 | `ConvergeSender` 每轮为每行 `CopierPos d=g_desired[base+i]` 做整结构拷贝（含 3 个 string 的引用计数） |
| **O-04** | 低 | `N-05` 同一函数把磁盘替换放进了锁内，与项目自定的"集群锁内禁止磁盘 I/O"相悖；建议改为锁外替换 + 锁内换句柄的两段式 |

---

## 2. 高危项详述

### N-01【高·交易安全】平仓/减仓被"休市门禁"拦住，并被 15 分钟队列休眠放大

**位置**
- `src/Experts/CopierReceiver.mq4:3326-3336`（`ExecuteQueue` 的统一休市检查）
- `src/Include/Copier/CopierState.mqh:1546-1570`（`CopierQueueNotePass` 的 15 分钟挂起）
- `src/Experts/CopierReceiver.mq4:4169`（`allMktClosed` 的判定）
- `src/Experts/CopierReceiver.mq4:9519-9543`（`OnTick` 的唤醒）

**代码现状**

```mql4
// 3318: 全局 feed stall —— 明确豁免退出动作
if(globalStall && a.kind!=CP_ACT_CLOSE && a.kind!=CP_ACT_TRIM && a.kind!=CP_ACT_DEDUP)
  { RotateQueue(); skipped++; continue; }

// 3326: 紧接着的休市门禁 —— 不区分动作类型
if(SymbolMarketClosed(a.sym))
  {
   RotateQueue();
   skipped++;
   mktClosedHeld++;      // ← 退出动作也被计为"休市持有"
   continue;
  }
```

```mql4
// CopierState.mqh:1557
if(allMarketClosed)
  {
   backoffMs=900000;                 // 15 分钟
   retryAtMs=nowMs+backoffMs;
   ...
  }
```

```mql4
// OnTick: 只有"图表品种"匹配队列中的品种才醒
if(g_qRetryAtMs>0 && g_qn>0 && g_qBackoffMs>=900000)
   ... if(g_q[idx].sym==_Symbol) ...
```

**机制**

1. `SymbolMarketClosed()` 由三部分构成：券商 132/10018 缓存（60s）、交易时段、**本品种报价停更 > 60s**（`CP_SYM_STALL_MS`）。
2. 第三项是这里的关键：一个流动性差的品种在正常开盘时段也可能 60–120 秒没有 tick。此时一条本该立即执行的 CLOSE 被 `RotateQueue()` 推回队尾。
3. 如果队列里**全部**动作都被这一条拦住（周末、节假日、或整组持仓集中在同一个安静品种），`allMktClosed` 为真，`CopierQueueNotePass` 把周期性出队挂起 **15 分钟**。
4. 15 分钟后或 `OnTick()` 唤醒——但 `OnTick()` 只在 `_Symbol`（EA 所在图表的品种）恰好等于某个排队动作的品种时才清退避。接收端通常挂在 EURUSD 图上、而持仓在 XAUUSD/指数上时，**这个唤醒永远不会发生**，只能等 15 分钟自然到期。
5. 结果：一条本应毫秒级执行的平仓，最坏被推迟约 15 分钟。这与 `CopierRisk.mqh` 头部"blocking a CLOSE would be actively dangerous"的自我约束、以及 3318 行对退出动作的显式豁免，形成同一函数内的自相矛盾。

**建议**
- 退出动作（`CP_ACT_CLOSE`/`CP_ACT_TRIM`/`CP_ACT_DEDUP`）**不参与** `SymbolMarketClosed()` 门禁：券商拒绝会立刻返回 132/10018，那是可观测、可退避的事实；而"我们推断它关着"不应该阻止释放风险。
- 若保留门禁（担心刷单），则把 `CP_MKTCLOSED_MS`（60s）作为退出动作的唯一上限，并在 `allMktClosed` 判定中排除退出动作，使 15 分钟休眠只作用于纯开仓队列。
- `OnTick()` 的唤醒条件应从"图表品种"放宽为"队列中任一行情品种在最近 N 秒内出现过报价"（`g_sfChangedMs` 已有该信息）。

---

### N-02【高·自伤负载】日内基线无法建立时，每 100ms 重走一遍全部交易历史

**位置**：`src/Experts/CopierReceiver.mq4:5363-5412`

```mql4
else if(g_riskDayStartEquity<=0.0 || now-g_lastRealizedMs>60000)
  {
   g_lastRealizedMs=now;
   bool rOk=false;
   double realized=CopierRealizedToday(dayStart,rOk);   // ← 遍历 OrdersHistoryTotal()
   ...
   if(rOk) { ...只有 derivedBase>0 才写入基线... }
  }
```

**机制**

- 条件用 `||`：只要 `g_riskDayStartEquity<=0.0` 成立，`g_lastRealizedMs` 的 60 秒节流**完全失效**。
- 基线在两种情况下会长期保持 0：
  1. `CopierRealizedToday()` 返回 `rOk=false`。MT4 分支是 `if(!IsConnected()) { outOk=false; }` —— **终端断线期间恒为 false**；MT5 分支是 `HistorySelect()` 失败。
  2. `derivedBase = curBal - realized <= 0`（当日有出金，或 realized 尚未就绪时读到一个异常的余额）。
- 该分支位于慢车道（`now-s_lastSlowMs<100` 即 return），即**每 100 毫秒执行一次**。
- MT4 的 `CopierRealizedToday()` 会 `OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)` 逐单遍历。一个跑了几个月、历史数万单的账户，在 VPS 断线（周末/券商维护）时就是 **10 次/秒 × 数万次 OrderSelect**，等于把一个核持续打满，并且正好抢在与下单同一条主线程上。

**建议**
- 把条件改为严格节流：`if(g_riskDayStartEquity<=0.0 && now-g_lastRealizedMs>60000) || now-g_lastRealizedMs>60000` —— 即无论如何 60 秒最多一次。
- 或在 `!IsConnected()` 时直接跳过整段（不重试、不清零、保留上次基线），并在恢复连接后强制一次重算。
- 更彻底：`CopierRealizedToday()` 按 `dayStart` 缓存结果，仅在余额变化或日切时失效。

---

## 3. 中危项详述

### N-03【中·交易安全】畸形/反向止损会被"夹到市价"从而立即止损，而不是被拒绝

**位置**
- `src/Include/Copier/CopierDefs.mqh:1317-1356`（`CopierMirrorStop`，A86-02 改动）
- `src/Include/Copier/CopierSizing.mqh:224-249`（`CopierFitStopAt`）
- `src/Experts/CopierReceiver.mq4:4566-4597`（仅 inverted 分支有 `invertedCrossed` 保护）

**机制**

A86-02 把 SL 从"必须位于开仓价亏损侧"改成了有符号偏移：

```mql4
if(isSl) {
  if(side==CP_SIDE_BUY) { double offset=senderStop-senderOpen; return localOpen+offset; }
  ...
}
```

这个改动本身对移动止损/保本止损是必要的。但原始注释里那条"a wrong stop is worse than no stop"的守卫被完全去掉了，而下游的 `CopierFitStopAt()` 会把任何落到最小距离以内的止损**朝市价方向夹紧**：

```mql4
double minPx=marketPx-si.stopLevel;
if(out>minPx) { out=minPx; clamped=true; }   // ← 买方止损被"夹"到市价下方一点
```

于是当发送端 SL 落在**当前市价的盈利侧**（发送端报价源不同、时区/点差差异、或操作员手工改错）时，接收端会算出一个高于市价的止损，被夹到 `市价 - stopLevel`，**立即触发止损**。同一个文件里 `actualInverted` 分支（4574-4592）对此有专门保护，非 inverted 分支没有。

**建议**
在非 inverted 路径加入对称保护：若 `wantSl` 相对**当前平仓价**位于错误一侧（买方 `wantSl>=marketPx`，卖方反之），保留 `local.sl` 并记录一次告警，而不是交给夹紧逻辑。同理对 TP 做反向检查。

---

### N-04【中·交易安全】MODIFY 失败走完整 24 小时阶梯，镜像可能长时间无止损

**位置**
- `src/Experts/CopierReceiver.mq4:2984-2988`（`PushAction` 的非退出分支）
- `src/Experts/CopierReceiver.mq4:3909-3953`（失败后 `g_backoff.Note(boKey)`）
- `src/Include/Copier/CopierState.mqh:991-1001`（`CopierBackoffMs` 至 24h）

**机制**

- CLOSE/TRIM/DEDUP 用 `BlockedExit()`，阶梯封顶 60 秒——这是本轮之前专门为交易安全加的。
- MODIFY 与 OPEN 共用 `Blocked(boKey)`，即 `CopierBackoffMs(n)`：1m → 5m → 15m → 1h → 6h → 12h → **24h**。
- `QueueModifyIfNeeded()` 每一轮都会重新推导目标止损并 `PushAction`，但因为 `boKey` 是 `sender:5:#t<ticket>`（防尾随止损刷键），**同一个订单的所有后续 MODIFY 都会被这个 24 小时窗挡住**。
- 也就是说：一个因为券商 `STOPS_LEVEL` 或跳空而反复被拒的止损更新，会让该持仓在数小时到一天内**没有任何新增保护**，而 `EmergencySLPips` 只在 `wantSl<=0` 时才接管，这里不会触发。

**建议**
- MODIFY 使用独立的、封顶 60–300 秒的阶梯（与退出动作同类，因为它是风险收敛动作）。
- 或对"该 ticket 已有本地止损缺失"的情形直接 `Park(boKey, 2000)`，避免把无保护状态锁死。
- 同时在连续 3 次 MODIFY 失败后升级一次告警（现有日志只在 `fails>=2` 时限流打印一次，容易被淹没）。

---

### N-05【中·可用性】`replace_all()` 失败后命令日志永久不可用

**位置**：`hub/src/commands.rs:485-524`

```rust
{
    let mut inner = self.inner.lock_or_recover();
    inner.file = None;                                    // 句柄已丢
    crate::cluster::atomic_replace_file(Path::new(&tmp), &self.path)?;   // ← 失败即 return
    let file = OpenOptions::new().create(true).append(true).open(&self.path)?;  // ← 失败即 return
    inner.file = Some(file);
    ...
}
```

**机制**

- `enabled==true` 而 `inner.file==None` 时，`append_many()` 走的是"fail-closed"分支，返回 `NotConnected`（commands.rs:1009）。
- 任一 `?` 提前返回，就留下 `file=None` 且没有任何恢复路径：此后 `ack()` 全部返回 false（命令永远 pending，阶梯空转）、`issue_op()` 无法落盘、`in_flight` 不再重建。只有重启 Hub 能恢复。
- 触发条件在 Windows 上并不罕见：目标文件被杀毒/索引器/另一个进程短暂持有，`atomic_replace_file` 的 `MoveFileEx` 会失败。

**建议**
把替换段改成不可失败的收尾：

```rust
inner.file = None;
let replace_res = crate::cluster::atomic_replace_file(Path::new(&tmp), &self.path);
let reopened = OpenOptions::new().create(true).append(true).open(&self.path);
inner.file = reopened.ok();     // 无论替换是否成功，都尽力恢复句柄
replace_res?;                   // 句柄恢复后再传播错误
```
并在 `replace_res` 失败时删除 `tmp`、保留旧文件与旧内存状态。

---

### N-06【中·延迟】每次命令落盘都在全局 `inner` 锁内 fsync

**位置**：`hub/src/commands.rs:996-1051`

```rust
match f.write_all(buf.as_bytes()).and_then(|_| f.sync_data()) { ... }
```

调用者（`ack`、`issue_op`、`due_gated_with`）都是先取 `self.inner.lock_or_recover()` 再调用 `append*`。也就是说：**持锁期间做了一次 fsync**。

**影响**

- ZMQ 转发线程、HTTP 线程、告警/审计线程都要取同一把 `Mutex<HubState>`。一次 `sync_data` 在普通 VPS 盘上是 0.5–5ms（机械盘或网络盘更高），每次 ACK 都会把转发线程卡这么久。
- 在 100 个节点、closeall 之类会同时 ack 的场景下，这是可观测的抖动来源，而且发生在 OPEN/CLOSE 转发路径的同一进程里。
- `lockx.rs` 的注释（正确地把锁定位为"缓存而非账本"）与这里"持锁 fsync"的严格性并不一致。

**建议**
- 把 journal 拆成独立写线程 + `mpsc`：内存状态在锁内更新并生成待写行，锁外/异线程负责 `write_all + sync_data`，`ack` 返回"已入队"。
- 最小改动：`append_many` 返回拼好的 `buf`，由调用者在**释放锁之后**执行写入与 fsync；写失败时再取锁回滚状态（已有 `line_count` 回滚逻辑可复用）。

---

### N-07【中·健壮性】`CFG`/`CMD` 的拒绝在 `AcceptSeq` 之后

**位置**：`src/Experts/CopierReceiver.mq4:7835-7847`

```mql4
if(!AcceptSeq(si,e,effectiveStream,topic)) { g_dropped[si]++; return false; }   // ← 先推进水位

if(e.type==CP_T_CFG || e.type==CP_T_CMD)
  {
   g_log.Warn("SECURITY: rejected ...");
   return false;                                                                 // ← 后拒绝
  }
```

**机制**：一个冒充某发送端的 `CFG` 帧（或配置错乱的发送端）会先把 `g_lastSeq[si][CP_STREAM_EVENTS]` 推到该帧的 SEQ，然后才被丢弃。若该 SEQ 很大，这个发送端**之后所有真实事件**都会因 `e.seq<=g_lastSeq` 被判为过期而丢弃，直到它重启（新 SSID）为止。日志里只会看到"discarded by the sequence guard"，指向错误方向。

**建议**：把 `CP_T_CFG`/`CP_T_CMD` 的类型检查提到 `AcceptSeq` 之前（与 `PING`/`PONG` 同级），因为它们本来就不该出现在数据流上。

---

### N-08【中·性能】平仓探测是 O(N²) 且每次重置历史选区

**位置**：`src/Include/Copier/CopierModel.mqh:1348-1399`，调用点 `CopierSender.mq4:2264`

**机制**

- `shouldProbe` 在 `g_slotMissCount[k]<=1`（每个槽位第一次丢失）时为真，于是**同一 tick 内对每个消失的订单各探测一次**。
- 每次探测：`PositionsTotal()` 全表扫（比对 `POSITION_IDENTIFIER`）+ `HistorySelectByPosition(p)`（重置整个历史选区）+ 逐 deal 汇总。
- 一次 74 单的批量平仓就是 74 × 74 次持仓比对 + 74 次 `HistorySelectByPosition`，集中在 5ms 的一个 tick 内；随后 50–300ms 的微步探测还会重复。
- 这正好发生在券商端最忙、EA 最需要响应的时刻。

**建议**
- 每个 tick 最多做 **一次** `HistorySelect(now-86400, now)`，把已平仓的 position id 收进一个局部集合，然后对整批丢失槽位做集合查询；把 `g_slotMissMs` 的微步探测保留给"历史里查不到"的少数残留。
- 或对探测做全局节流（例如每 200ms 最多一次批量探测），用 2s 的 debounce 兜底（现有逻辑已具备）。

---

### N-09【中低·带宽】HA 下数据帧双发使每个接收端下行翻倍

**位置**：`src/Include/Copier/CopierTransport.mqh:584`

```mql4
int copies=(m_connectedHubs>1) ? 2 : 1;
```

注释给出的理由是"XSUB 在两条管道间轮转，单发会让 seq 交错，接收端可能先看到 seq3 再看到 seq2，从而永久丢弃 seq2"。这个担心是真实的，但**双发并不能解决它**：两条管道各自保序，跨管道依然可能乱序；双发只是保证"每条管道都有每一帧"。而代价是：

- Hub 侧：每帧被转发两次（`note_forward` 计数也翻倍）。
- 每个接收端：每个 SNAP 收到两份。最坏 380KB 的快照 → **760KB/次/接收端**，100 个接收端就是 76MB 一次广播。第二份在 `AcceptSeq` 里按 SEQ 丢弃，纯属浪费。

**建议**
- 只对 `@` 控制帧（REG/ACK/STAT/RCPT/PING）双发，数据帧单发；Hub 侧已经用 `SEQ` 做过期判定（`main.rs` 的 `env_sid`/topic 校验），可以在 Hub 转发前对同 `(SID,SEQ)` 去重，避免双份下发给订阅者。
- 若必须双发，则在 Hub 侧按 `(sid, seq)` 做 1–2 秒的转发去重窗口，把下行恢复为单份。

---

## 4. 低危项

### N-10 `CopierManualClosedRing` 使用 `GetTickCount()`

`CopierState.mqh:1646/1655/1670` 写入，`CopierReceiver.mq4:6347` 读取比较。`CopierNowMs()`（`GetMicrosecondCount()/1000`）是全项目其余地方的单调时钟，两者起点不同；`GetTickCount()` 是 32 位、49.7 天回绕。回绕后 `gcNow - m_at` 为负，`ageMs>CP_MANUAL_CLOSED_TTL_MS` 恒假，凡是"仅凭 ticket 记录"的条目将永久驻留（虽然有 `LocalTicketStillOpen` 兜底，但那正是这张 TTL 要覆盖的注释被券商改写的情形）。

**建议**：统一改用 `CopierNowMs()`。

### N-11 `CopierPayloadHbt2` 仍带 `NAME=`

`CopierCodec.mqh:858-862` 与同文件 827-833 行的契约注释直接矛盾，也与 `CopierSender.mq4:496` 的设计说明矛盾。每 5 秒、每节点、每个终端名（最长 24 字符）。纯带宽问题，但属于"文档与实现不一致"这一类会误导后来者的缺陷。

**建议**：按契约去掉 NAME，或修改注释承认现状（二者选一，不要长期并存）。

### O-02 `HandleSnapshot` 的全包拒绝会冻结收敛

`CopierReceiver.mq4:6454`：`CopierValidateSnapshot()` 要求 `decodedCount == min(N, cap)`。只要有一条记录解码失败（例如某个持仓的 lots 恰好落在 `CopierFmtDouble` 输出 `"0"` 的阈值以下，或 symbol 被截断成空），整个快照被拒绝，`g_ready` 保持旧值，接收端继续对着**上一份** desired 集合收敛——既不报警也不自愈，因为发送端每次发的字节完全一样。

这一点与 `BuildCurrent()`/`RebuildSnapshotPayload()` 里的"发送前逐条 chokepoint 校验"（`CopierSender.mq4:1727-1739`）是互补的，但校验和发送之间仍存在窗口（例如持仓在快照构建后、发送前被修改）。

**建议**：在 `handleSnapshot` 里区分两种不一致——
1. `decoded > 0 && decoded < N`：接受已解码的子集，**但跳过本轮的"发送端已平仓"判定**（在 desired 里给未解码的 UID 打一个"未知"标记或直接保留旧行），并把这个状态通过 STAT 的 `RISK=`/新增字段上报给 Hub；
2. `decoded == 0 && N > 0`：仍然全包拒绝（这才是真正的坏包）。
现有实现把 1 也当成 2 处理，代价是一整轮收敛停摆。

### O-01 `CopierGetSymbolInfo()` 无缓存

调用密度（每个"已匹配持仓"每轮 converge）：
- `ConvergeSender:5731` → `ComputeTargetLotsForMirror` → 1 次
- `QueueModifyIfNeeded:4429` → 1 次；内部 `CopierFitStop` 还会 2 次 `CopierGetClosePrice`
- `QueueTrimIfNeeded:4281` → 1 次（仅当有超额手数）

MT5 每次 `CopierGetSymbolInfo` 是 8 个 `SymbolInfoDouble`/`SymbolInfoInteger`。300 持仓 × 4 轮/s ≈ 4.3 万次终端调用/s。这些值（point/digits/minLot/maxLot/lotStep/stopLevel/tickSize/contractSize）基本只在券商改合约规格时变化。

**建议**：加一个 256 槽的直连映射缓存（键 `symbol`，TTL 60s 或按 `SessionStart` 失效），与已有的 `CP_SYMFRESH_CACHE` 同构。预期把这条路径的终端调用降一个数量级。

### O-03 `ConvergeSender` 的整结构拷贝

`CopierReceiver.mq4:5703` 每行 `CopierPos d=g_desired[base+i]`（3 个 string 的引用计数增减）。300 持仓 × 4/s = 1200 次/s。单独看很小，但它与 `LocalForSender` 的整结构拷贝（每轮把所有本地持仓复制进 `g_locScratch`）叠加后，是收敛热点里最容易被忽略的固定成本。若要动，优先改 `LocalForSender` 为"只记录槽位索引"的变体。

---

## 5. 复核：上一轮高危项在当前代码中的状态

已逐条对照代码确认**已修复**，本节仅为避免下一轮重复劳动：

| 上轮编号 | 内容 | 当前状态 |
|---|---|---|
| BUG-01（11-08） | `OnTick()` 任意 tick 清空退避阶梯 | **已修**：`9523` 要求 `g_qBackoffMs>=900000` 且 `g_q[idx].sym==_Symbol` |
| BUG-02（11-08） | `boKey` 误用 `:2:`(CLOSE) 污染平仓键 | **已修**：`2986`/`3777`/`3910` 均改为 `":"+(string)CP_ACT_MODIFY+":#t"` |
| BUG-03（11-08） | 多 Sender 冷启动 `g_manualClosed` 误 GC | **已修**：`6390-6401` 新增 `allSendersReady` 守卫 |
| BUG-01（11-07-r3） | `HandleSnapshot` 原地覆写破哈希探测 | **已修**：`6514-6538` 改成"先算 carry 写 `g_scratch`，再批量赋值" |
| BUG-02（11-07-r3） | 事件不置 `g_convergeDirty` | **已修**：`HandleOpenEvent:7388/7402`、`HandleCloseEvent:7420`、`HandleModifyEvent:7371` 均置位 |
| BUG-03（11-07-r3） | `ack()` 落盘前剔除 `in_flight` | **已修**：`commands.rs:939-948` 移到 `append` 成功之后 |
| BUG-04（11-08） | 数据转发阻塞 `send` | **已修**：`main.rs:2902/2906/2911` 全部 `DONTWAIT` |
| BUG-04（11-07-r3） | `0.0001` 手数容差 | **已修**：改用 `CP_LOT_EPS`（1e-9） |
| BUG-05（11-07-r3） | `ppriceDiff` 并入 `otherDiff` 引发快照风暴 | **已修**：`CopierState.mqh:267-273` 已剥离 |
| BUG-07（11-07-r3） | MT4 `CopierRealizedToday` 冷启动虚报 `outOk` | **已修**：`RefreshRisk:5322-5326/5370-5374` 增加 `OrdersHistoryTotal()==0 && uptime<10s` 判定（但见 N-02 的残留问题） |
| BUG-08（11-07-r3） | WS `Lagged` 不补发快照 | **已修**：`api.rs:842-847` 补发 `snapshot_text` |
| OPT-04（11-07-r3） | XSUB 订阅表满仍发包 | **已修**：`245` 行 `if(!found && slot<0) return false` |

---

## 6. 测试套件盲区（为什么这些还能漏过）

现有门禁（MQL 自检 + Rust 单测）在"纯函数 / 单线程 / 理想网络 / 全部 Sender 已 ready"的假设下非常扎实，但下列盲区使本轮 11 项新发现中的多数无法被捕获：

1. **N-01**：自检里没有任何用例构造"队列中只有 CLOSE，且该品种的 quote age > 60s"。建议新增：`TestExitNotBlockedByStaleFeed` —— 断言 `allMktClosed` 不因退出动作而置位，且 `CopierQueueNotePass` 在"仅退出动作 + 休市"时不产生 900000ms。
2. **N-02**：没有任何用例模拟 `IsConnected()==false` 或 `HistorySelect` 失败。建议给 `RefreshRisk` 抽出"是否应当重算基线"的纯函数并断言调用节流。
3. **N-03**：`CopierMirrorStop` 的单测只覆盖合法 SL/TP，未覆盖"senderStop 位于市价的盈利侧"这一夹紧退化路径。
4. **N-04**：缺少"MODIFY 连续失败 5 次后，阶梯时长不超过 X"的断言。
5. **N-05/N-06**：Rust 侧没有"`replace_all` 过程中 `atomic_replace_file` 返回 Err"的注入测试；也没有"`ack` 期间 fsync 耗时"的并发压测。
6. **N-07**：缺少"伪造 CFG 帧不得推进 event 水位"的断言。
7. **N-09**：`tools/zmq_bidir_test.py` 只验证"两条管道都能收到"，未统计"每个订阅者收到的帧数"。

另外，`SelfTest` 的条数门禁（当前基线 MT5 715 / MT4 708）只增不减，加断言时记得同步调高 `tools/selftest_run.sh` 里的 `BASELINE`，否则会变成"加了测试但没生效"。

---

## 7. 优先级建议

**第一优先（本轮应修，交易安全 / 可用性）**
1. **N-01**：退出动作豁免 `SymbolMarketClosed()`；`allMktClosed` 只统计开仓类动作；`OnTick()` 唤醒条件从 `_Symbol` 放宽。
2. **N-02**：`RefreshRisk` 基线重算改为严格 60 秒节流 + 断线即跳过。
3. **N-05**：`replace_all()` 错误路径必须恢复文件句柄（这是"一次失败即永久失效"的可用性缺陷）。
4. **N-04**：MODIFY 阶梯封顶，或对"无本地止损"的 ticket 回退到 2 秒 park。

**第二优先（正确性 / 延迟）**
5. **N-03**：非 inverted 分支补上"止损相对市价方向"的守卫。
6. **N-07**：`CFG`/`CMD` 类型检查前置。
7. **N-06**：journal fsync 移出全局锁。
8. **N-08**：平仓探测改为每 tick 一次批量 `HistorySelect`。

**第三优先（带宽 / 卫生，可随版本）
9. **N-09**：HA 数据帧改单发 + Hub 侧去重。
10. **N-10**：统一时钟源。
11. **N-11**：`HBT2` 去掉 `NAME=`（或改注释）。
12. **O-01 / O-02 / O-03**：symbol-info 缓存、快照子集接受、拷贝精简。

---

## 8. 结语

本轮最值得警惕的不是某一行写错，而是**两条"保护机制"各自演化后互相矛盾**：

- 「休市就不发单」是为了不打券商，但它被套用到了平仓上，与「平仓永不拦」这条更早、更强的不变量冲突（N-01）。
- 「反复被拒就退避到 24 小时」是为了不刷单，但它被套用到了止损更新上，与「止损是保护手段」冲突（N-04）。
- 「失败即上报，不提交内存」是为了日志与内存一致，但 `replace_all` 的失败路径没有恢复句柄，把一次可恢复的 I/O 错误升级成了永久失效（N-05）。

这类问题的共同特征是：**单看某个模块的取舍都正确，组合起来方向相反**。建议后续把这几条不变量写成显式断言（"任何 gate 的出口处，若 `kind` 属于退出类，则必须放行" / "任何 backoff 的上限若作用于保护性动作，不得超过 X"），放进自检门禁，而不是继续靠代码注释约束。

*(报告完，未改动任何代码。)*
