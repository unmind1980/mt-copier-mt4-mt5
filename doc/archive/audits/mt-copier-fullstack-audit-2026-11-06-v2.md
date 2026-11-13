# mt-copier 全栈独立通读审计报告（2026-11-06 · 第二遍）

> **审计执行**：WorkBuddy AI（单进程独立通读，未派发子代理，跨模块不变量交叉核验）
> **审计日期**：2026-11-06
> **专案路径**：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
> **通读范围**：
> - 全部 MD 文档（README、PROTOCOL.md、HANDOFF.md 107 轮演进全量、AUDIT-22/23/24、outputs/ 下 4 份历史审计报告）
> - MQL 客户端：`src/Include/Copier/*.mqh` 17 个头文件、`src/Experts/CopierSender.mq4`、`src/Experts/CopierReceiver.mq4`
> - Rust Hub：`hub/src/*.rs` 17 个模块（含内嵌 #[cfg(test)] 测试）
> - Git 历史交叉核验（`git log -p -S` 追溯修复的引入与回退）
> **审计原则**：只读排查，不改任何代码。以「跨模块不变量追消费端实际读值」为主线，每条结论给出 `文件:行号` 与触发路径。

---

## 0. 历史报告核销对照（2026-11-06 全栈审计 C1–C5 / P1–P4）

先对上一份《mt-copier-fullstack-audit-2026-11-06.md》的 9 项发现逐一到现代码核验：

| 编号 | 历史结论 | 现代码核验位置 | 核验结论 |
|---|---|---|---|
| **C1** | 挂单成交宽限期 1.5s 无限重置震荡 | `CopierReceiver.mq4:5326-5332`（超时分支不再 `Forget`，注释明确 C1）；`5350` 在 kinds 对齐后统一清理 | **已修复**，闭环 |
| **C2** | 单播修复同步推进 `g_snapHash` 引发全网误判 BEHIND | `CopierSender.mq4:1402-1418`（注释 `C2: Do NOT mutate global g_snapPayload or g_snapHash on unicast repair!`） | **已修复**，闭环 |
| **C3** | 孤儿单平仓 `senderIdx==-1` 未扣减计数 | `CopierReceiver.mq4:3404-3408`、`3428-3431`（`g_orphanCount--` else 分支）+ `3409` 扣 `g_acctPositions` | **已修复**，闭环 |
| **C4** | 双 Hub 下首个 PONG 即 `Disarm` 事件泵，慢 Hub RTT 虚高 | `CopierSender.mq4:1847-1851`、`2000`；`CopierReceiver.mq4:7198`、`7286` — 任一 `PongBack` 成功即 `g_pump.Disarm()`，无「收齐两份/超时」条件 | **仍未修复**（见 §1.1） |
| **C5** | Standby 增量复制过滤重复行 → 物理行数漂移 → 频繁全量覆盖重同步 | `hub/src/commands.rs:442-448`、`config.rs:276-283`（仅 `should_insert`/`should_advance` 行进 `to_append`） | **仍未修复，且发生过一次修复→无声回退**（见 §1.2，重要） |
| **P1** | 平仓发现硬等 2000ms | `CopierSender.mq4:2178-2180`（0/50~300ms/2000ms 前密后疏阶梯探测 `shouldProbe`） | **已修复**，闭环 |
| **P2** | 通知每次发送重建 `reqwest::Client`，丢失连接池/TLS 复用 | `hub/src/notifications.rs:1292`（每次调用 `reqwest::Client::builder()`，无缓存） | **仍未修复**（见 §2.1） |
| **P3** | `SendUp` 尾帧失败留下 SNDMORE 残局 | `CopierTransport.mqh:517-534`（空帧闭合已改非阻塞 `true`，但若空帧也失败，无 `m_framingCorrupted` 标记、无管道重建） | **部分缓解**（见 §2.2） |
| **P4** | `EncodeSenderPositions` O(2048) 线性查找 | `CopierSender.mq4:1920`、`1952`（仍 `g_prev.Find(g_curScratch[i].uid)`，未复用 `g_prevSlotScratch`） | **仍未修复**（见 §2.3） |

另核验 2026-11-05 r2 报告的 N2/N4：`CopyToWithSlots` 尾部不再收缩（`CopierState.mqh:483-486`，已闭环）；`CP_PANEL_MAX_ROWS=28`（`CopierPanel.mqh:26`，已闭环）。N1（负数 deviation）确认全部出口钳位（`CopierModel.mqh:401/440/872/884/982/1004/1276/1309` 均 `MathMax(0,deviationPoints)`，已闭环）。

---

## 1. 严重与高危逻辑缺陷

---

### 🚨 V1【高危·回归缺陷】HA 水位补偿逻辑被后续提交无声移除，C5 的「物理行数漂移 → 1Hz 全量重同步死循环」重新复活

#### 1. 缺陷定位
- **源码位置**：`hub/src/commands.rs:442-448`、`hub/src/config.rs:276-283`
- **引入回归的提交**：`b1cf505`（2026-11-05 19:35）删除了 `2bfaf14`（同日 17:22）加入的补偿块

#### 2. 机制推导（跨模块不变量追消费端读值）

journal 行数语义在**三个消费端**必须一致：

| 位置 | 计数规则 |
|---|---|
| `load()`（`commands.rs:1125-1131`） | 每条**合法可解析且 id/node 非空**的行 `line_count += 1`，**不论** `should_insert` |
| `read_lines_from_path()`（`commands.rs:340-351`） | 同上，`total += 1`，且 `total >= from_line` 才返回该行 |
| `apply_delta_lines()`（`commands.rs:442-448`） | **仅** `should_insert==true` 的行进 `to_append` → `append_many` 里 `line_count += cs.len()` |

Primary 上三者自洽（每条状态迁移都写一行、都计数）。但 Standby 的 `apply_delta_lines` 过滤掉「已存在/低 rank/同 attempts 重复行」时，这些行**不写入本地 journal、不计入 line_count**。此时：

1. Standby 的 `sync_stats()` 汇报 `cmd_lines_count` 小于 Primary 的 `remote_st.cmd_lines`；
2. `cluster.rs:690` 的 `req_from_cmd_line = cmd_lines_count` 使 Standby 用**自身落后的行号**去 Primary 拉取 —— 拉回来的窗口起点落在**它已经过滤掉的行**之前，重复行再次被过滤，`applied` 可能为 0；
3. `cluster.rs:774-776`：`if applied == 0 && cmd_lines_count < remote_st.cmd_lines { FORCE_FULL_CMD_RESYNC = true }` → 触发全量 `replace_all`（整文件重写 + fsync）；
4. 全量重同步后行数对齐，直到下一次增量里再出现一条被过滤的行，1Hz 循环再来一遍。

这正是 2026-11-06 报告 C5 描述的病灶。

#### 3. 回归经过（git 考古）

- `2bfaf14`（fix: … HA replication line count …）在 `apply_delta_lines` 末尾追加了补偿块：
  ```rust
  // HUB-01: Advance line_count by the number of received valid lines if append didn't advance it
  let parsed_valid_lines = raw_lines.iter().filter(...).count();
  if parsed_valid_lines > to_append.len() {
      inner.line_count += parsed_valid_lines - to_append.len();
  }
  ```
  该写法**只推进内存水位、不写盘**——内存 `line_count` 会超过物理文件行数，重启后 `load()` 按物理行重算导致水位回落，是**有缺陷的补丁**。
- `b1cf505`（fix: resolve fullstack review findings across orphan close gate…）**整块删除**了该补偿（`git log -p -S parsed_valid_lines` 证实），但其提交信息**只字未提**删除原因。同提交对 `config.rs` 的等价补偿块也一并删除。
- 结果：一个已知 P0 级同步死循环的修复被无声回退，且没有代之以正确实现（物理行全量镜像）。

#### 4. 修复建议（与 2026-11-06 报告 C5 一致，此处给出落地形态）

**日志物理复制与内存状态机彻底分离**：
- `apply_delta_lines` 中，所有解析成功（id/node 非空）的行**无条件**写入 Standby 本地 journal 并 `line_count += 1`；
- `should_insert`/`state_rank` 的比对**仅**决定是否更新内存中的 `commands` map；
- config.rs 的 `count` 同理。
- 补一条单测：Primary journal 含一条重复行（同 ts、同 rank、同 attempts），Standby `apply_delta_lines` 后 `sync_stats().0` 等于 Primary 的 `read_lines_from_path(0).1`，且 `applied` 不必大于 0。

**风险等级：高**（HA 主备自动回切会被反复的全量 `replace_all` 阻塞；磁盘写放大；`sync_err` 窗口拉长）。

---

### 🚨 V2【中高·逻辑缺陷】`CopierRisk::ObserveAt` 的 `equity<=0` 爆仓短路不看限额是否配置，且只武装不放行——净值读到 0 的瞬时观测会永久闩锁日内熔断

#### 1. 缺陷定位
- **源码位置**：`src/Include/Copier/CopierRisk.mqh:188-194`（`equity<=0` 分支）、`196-202`（`!m_armed` 武装分支）

#### 2. 机制推导

```cpp
if(equity<=0.0)
  {
   if(!m_dailyTripped) { m_dailyTripped=true; m_justTripped=true; }
   if(!m_ddTripped)    { m_ddTripped=true;    m_justTripped=true; }
   return;                                   // ← 早退
  }
if(!m_armed)
  {
   m_day=serverDay; m_dayStartEquity=dayStartEquity;
   if(dayStartEquity>0.0) m_armed=true;
   ...
  }
```

问题链：

1. **触发面过宽**：`equity<=0` 一律双闩，与 `m_lim.dailyLossPct/maxDrawdownPct` 是否 >0 无关。`AllowOpen()`（`326-345`）会先查 `m_dailyTripped`/`m_ddTripped` 再看限额——所以**未配置任何百分比风控**的账户也会被拒开仓。这违背该文件自身「0 = switch off, everywhere」的契约（`30-36` 注释）。
2. **何时读到 0**：账户切换瞬间、断线重连后 `AccountInfoDouble(ACCOUNT_EQUITY)` 短暂返回 0、以及真实爆仓。前两者是瞬态，却产生与爆仓同等效力的闩锁。
3. **日闩可自愈（跨日清除），回撤闩不能**：`m_ddTripped` 的唯一出口是 `Configure()` 发现限额变更（`158-167`）或重挂 EA。`!m_armed` 分支只设置基准并 `return` 之外的后续观测会继续，但**没有任何路径**在 `equity` 恢复 >0 时拆掉因瞬态 0 上的闩。
4. 一个具体序列：EA 启动 → 首次 `ObserveAt(0.0, …)`（账户数据未就绪）→ 双闩上锁 → 此后净值 10 万也照旧拒单，日志每分钟报 drawdown limit（`TripReason()` 引用 `DrawdownWhy`，其中 `m_peakEquity=0` 时文案还缺基准）。

#### 3. 修复建议
- `equity<=0` 短路前增加 `Enabled()` 守卫（全 0 限额时直接 `return`，不做闩锁）；
- 或将「爆仓闩」与「百分比闩」拆成两个独立标志，爆仓闩允许在 `equity>0` 连续 N 次观测后释放（真正的爆仓账户净值不会回来）；
- 至少补 `SelfTest` 断言：限额全 0 时 `ObserveAt(0,…) → AllowOpen` 仍放行。

**风险等级：中高**（静默停止开仓、误报 drawdown、运维只能重挂 EA 恢复）。

---

### ⚠️ V3【中·时序缺陷】双 Hub 模式下首个 PONG 即 `Disarm` 事件泵（2026-11-06 报告 C4 复核确认仍在）

#### 1. 缺陷定位
- **源码位置**：`CopierSender.mq4:1847-1851` 与 `1998-2004`；`CopierReceiver.mq4:7196-7199` 与 `7284-7287`

#### 2. 机制复述
`PING` 向 `@hub` 双发（`SendUp` 的 `copies=2`），Primary/Standby 各回一份 `PONG`。快者（如 1.2ms）到达即 `g_pump.Disarm()`，慢者的帧滞留套接字缓冲直到下一次 `OnTimer` 慢通道（当前默认 `PollMs=5ms`，但 38/39 轮把事件泵做成 15ms 突发的意义就在于 sub-ms 采样）。`PongBack` 内 `m_rtt[i]=CopierNowMs()-ms` 用的是**处理时刻**而非到达时刻，慢 Hub 的 RTT 因此被夸大至 5~100ms，看板 `hub:standby` 长期黄/红，掩盖真实网络劣化。

#### 3. 修复建议
- 以「本轮 PING 发出的探测对象数」为期望值：`Disarm` 前判断 `g_peers` 中本轮所有 `m_ping[i]!=0` 的目标是否都已 `PongBack`，或 15ms 超时兜底；
- 或改为收到 PONG 时仅 `m_burstCount--`（预算耗尽才停泵），而非全量 `Disarm`。

**风险等级：中**（仅观测面失真，不影响交易；但在 HA 验收/故障演练时会造成误判）。

---

## 2. 性能优化空间

---

### ⚡ P-1【性能】通知发送路径每次构建 `reqwest::Client`（2026-11-06 报告 P2 复核确认仍在）

- **位置**：`hub/src/notifications.rs:1255-1302`（`resolve_pinned_client`）
- **现状**：每条通知做 DNS 解析 → `Client::builder().resolve_to_addrs(…).build()`，丢弃 TCP 连接池与 TLS session。突发告警（节点批量断线）时握手风暴且易触发微信/钉钉单 IP 建连频控。
- **建议**：`(host, resolved_addrs)` 为键的 TTL=300s 客户端缓存（地址变化或到期重建），SSRF 校验仍每次执行；`send_wecom/send_dingtalk/send_wechat/send_telegram` 共享。

### ⚡ P-2【性能】`EncodeSenderPositions`/`SendSenderStatusReport` 重复 O(N×2048) 线性查找（2026-11-06 报告 P4 复核确认仍在）

- **位置**：`CopierSender.mq4:1920`、`1952`
- **现状**：reqpos 触发时对每笔持仓 `g_prev.Find(uid)` 扫全表，`SendSenderStatusReport` 又独立扫一遍算 lotsSum（同一批 uid 双倍查找）。
- **建议**：`BuildCurrent` 已产出 `g_prevSlotScratch[i]`（`747`），两处直接复用；或合并为一次遍历同时产出 POS 串与 lotsSum。

### ⚡ P-3【健壮/性能】`SendUp` 双发循环里的第二份帧闭合失败无状态（2026-11-06 报告 P3 部分缓解，残余风险在）

- **位置**：`CopierTransport.mqh:517-534`
- **现状**：`sendMore(topic)` 成功而 `send(payload)` 失败时补 `send("",true)` 闭合；若**空帧也失败**，多帧事务悬挂，下一条消息首帧被拼进残包 → 解码错位。现有 `DrainFrames` 只排空「消息内多余帧」，不感知「发送侧残包」。
- **建议**：补 `m_framingCorrupted` 标志，置位后跳过后续 `sendMore` 直到重建 socket（`ConnectHub` 已有整套重建逻辑可复用）。

### ⚡ P-4【性能】`PruneSenderPeakLots` 遍历中读 `g_desired` 的双层循环写法可再省一层

- **位置**：`CopierReceiver.mq4:959-972`
- **现状**：DEF-61-04 已降维为 O(Desired+Acct)，但每 60s 一次的 `StopsPrune` 里对每个 desired uid 调 `PeakFind`（含兜底线性扫）。表内 2048 项 × 快照 2048 desired 时，`isAlive` 标记虽 O(1) 摊还，仍占 60s 周期的一次全量哈希。
- **建议**：与 `PruneTo` 同款——`m_n==0`/`desiredCount==0` 快速路径已存在；若再加 `g_uidPeakLotsCount==0` 于入口短路（当前已有 `if(g_uidPeakLotsCount<=0) return;`，已足够）。**此项确认已达标，列为"复核无问题"**。

---

## 3. 其他复核确认项（本轮重点排查，无需改动）

1. **BlockedCapped 不拦平仓**：`CopierReceiver.mq4:2750-2757` — CLOSE/TRIM/DEDUP 走 `BlockedCapped(key,1000)`（1s 上限），其余走全阶梯 `Blocked`。与 PROTOCOL「only OPEN is gated」一致。
2. **`parse_snap` 单趟扫描**：`hub/src/positions.rs:286-390` — N74-07 单遍 `;` 分隔解析 + HUB-08 迭代器字段切分，无重复全扫。
3. **集群同步锁外 I/O**：`cluster.rs:616-629` 提取路径后 `file_sha256` 在锁外；`622` 的 `s.notif_store.lock_or_recover().path()` 是锁内**取句柄路径**而非磁盘 I/O，`814` 起的写盘在 `st` 锁外。`main.rs` `due_gated` 闭包拿的是预制 `HashSet`（`3008-3032`），无反向取锁。
4. **`g_manualClosed` GC/原子写**：GC 后 `CmdStateSave()`（`5965`）、写入点 `6700-6701` 即时持久化，`MC=<uid>|<ticket>|<sid>` 三元组格式与 N84-02 定向 GC 一致。
5. **老版本缺 `H=` 与坏 hash 区分**：`CopierCodec.mqh:542-586`（`CopierValidateSnapshot`）—— `hasH==false` 时仅校验 N/decoded 计数（兼容老版）；`hasH==true` 时先校验 8 位长度、尾部锚定、再全量重算比对，语义已解耦。
6. **`g_stopSig` 13 字段签名 + 4 步探测 + `StopSigInvalidate`**：`QueueModifyIfNeeded` 的 clamped/emergencyMissing/`invertedCrossed` 三出口均拒绝写缓存，104/107 轮修复均在位。
7. **快照漏斗**：`CopierValidateSnapshot`（`N` 上界 ×10、decoded==expected、`N=0` 空 R、尾部锚定 `H=`）+ `HandleSnapshot` 的 reject streak 与 30 次升级告警，防假全平链条闭合。
8. **`CopierStrBuilder` 成对合并**：`CopierDefs.mqh` 的 `Result()` 自 R60-01 起用临时 `merged`，SelfTest 有 10,000 字节多块回归。
9. **命令 journal 单调性**：`apply_delta_lines`(ts → rank → attempts) 与 `load()` 对称（`1158-1183`），`test_retry_delta_replication_…`（`1628`）与 `test_load_and_read_lines_skip_torn_and_align_line_count`（`1720`）覆盖；**唯 V1 所述物理行计数与之不齐**。
10. **`CopierManualClosedRing` 定向 GC 门禁**：`5898` 仅在 `g_ready[si]` 时回收、`m_sid` 归属校验，未 ready 不误删。
11. **交易时段 F-05**：`CopierFilter.mqh:300-311` 已改 `TimeToStruct`，与 R48-05/07 同构（62 轮已闭环，复核无回归）。
12. **`SendUp` 双发语义**：`copies=(m_connectedHubs>1)?2:1`（`513`），与 ADR-02/H1 一致，XSUB 轮询劈 SEQ 的对策正确。

---

## 4. 测试缺口

1. **V1 回归测试**：`commands.rs`/`config.rs` 各补一条「增量含重复/低 rank 行 → `sync_stats` 行数 == Primary `read_lines_from_path` 行数」的单测——这正是 `2bfaf14` 被回退后无人发现的原因：当时没有测试锁住该不变量。
2. **V2**：SelfTest `TestRisk()` 补「限额全 0 + equity 0 → 不闩锁」「瞬态 0 后净值恢复 → 日闩可释放」断言。
3. **V3**：Python 侧 `ha_probe_test.py` 补「双 PONG 间隔 3ms 时慢方 RTT < 5ms」断言。

---

## 5. 汇总与优先级

| 编号 | 所属端 | 等级 | 核心影响 | 建议动作 |
|---|---|:---:|---|---|
| **V1** | Rust Hub（commands/config） | **高** | HA 增量同步行数漂移 → 1Hz 全量 `replace_all` 死循环回归；且修复曾存在被无声回退 | 物理行全量镜像 + 单测锁不变量；追查 `b1cf505` 删除动机 |
| **V2** | MQL Risk | **中高** | 瞬态 equity=0 永久闩锁熔断、未配置风控也拒单、仅重挂 EA 可解 | `Enabled()` 守卫或爆仓闩独立化 |
| **V3** | MQL Sender/Receiver | **中** | 双 Hub RTT 观测失真 | 收齐期望 PONG 数或超时再 Disarm |
| **P-1** | Rust notifications | 优化 | 通知握手风暴、频控风险 | 300s TTL 客户端缓存 |
| **P-2** | MQL Sender | 优化 | reqpos 大持仓 O(N×2048) 卡顿 | 复用 `g_prevSlotScratch` |
| **P-3** | MQL Transport | 健壮 | 发送侧残包导致后续解码错位 | `m_framingCorrupted` + socket 重建 |

---

*报告完毕。所有条目均为只读排查结论，未修改任何源码；C1/C2/C3/P1 及 N1/N2/N4 已现场核验闭环。*
