# mt-copier 全栈第二轮只读审计报告

- 审计日期：2026-11-05（第二轮，基于当日第一轮报告核销后的增量复审）
- 审计对象：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
- 范围：`src/Include/Copier/*.mqh` 全部 17 个头文件、`CopierSender.mq4`、`CopierReceiver.mq4`、`hub/src/main.rs`、`envelope.rs`、`positions.rs`、`registry.rs`、`commands.rs`、`users.rs`、`api.rs`（关键路径）与全部 doc/*.md
- 约束：**未修改任何源码；未开子代理；整文件顺序通读。**
- 方法：先通读全部 MD（README/PROTOCOL/HANDOFF 104 轮/AUDIT-24/第一轮报告），再按 MQL Include → Sender → Receiver → Rust Hub 顺序通读，最后以跨模块不变量反查消费端实际读值。

---

## 1. 第一轮报告（2026-11-05）核销对照

第一轮报告的 10 项发现，本轮逐一到现代码复核：

| 编号 | 第一轮结论 | 本轮核验 | 证据 |
|---|---|---|---|
| H1 | `SnapshotSeconds=0` 快照哈希冻结 | **已修复** | `CopierSender.mq4:2238` 按需模式 `g_snapDirty` 250ms 防抖广播已落地；`SnapRepairMaybe` 已改发 `g_latestSnapPayload` 并同步推进 `g_snapHash`（1389-1427 行） |
| H2 | TLS acceptor 缺失回退明文 | **已修复** | `api.rs:1976-1979` fail-closed 分支：acceptor 缺失时直接丢弃连接，不再 `serve_stream_with_router` 明文 |
| H3 | Hub 持仓按 NID 存储、按原始账号查询 | **已修复** | `positions.rs:161-175` `view_for` 已实现 `acc % 1e9` 回退查询 |
| H4 | 复制的用户密码变更不撤销会话 | **仍存在** | `users.rs:325-335` `apply_loaded_users` 只比对 `disabled`/`role`，不比对 `pass` 哈希 |
| M1 | HA 日志逻辑行数可超物理行数 | **已修复** | `commands.rs:442-448` `to_append.push` 已移入 `should_insert` 块，无独立补计数路径；grep 全库无 `parsed_valid_lines` |
| M2 | 配置热重载 CLOSE/TRIM 携带旧 senderIdx | **已修复** | `CopierReceiver.mq4:2871-2892` `RemapQueueSenders()` 按 `beforeSid[]`→新下标重映射保留动作 |
| M3 | `CopierIniWriteAll` 不检查写入返回值 | **已修复** | `CopierConfig.mqh:709-731` `writtenTmp`/`writtenMain` 与 `expectedLen` 比较已落地 |
| M4 | WebSocket 升级后不再校验会话 | **未复核**（本轮时间预算未覆盖 WS 会话续期路径） | — |
| M5 | 配置下发写失败仍返 202 | **未复核** | — |
| M6 | `HELD=0` 时 Hub 清空含手工持仓的明细 | **仍存在** | `registry.rs:512-523` `note_stat_at` 的 else-if 分支仍在：`held==0 && orphaned==0` 即清空 `held_items`，但 receiver 的 `POS=` 明细包含手工单（isManaged=0）与非管理单——手工单明细在两次 60s POS 上报之间最长被清空 59 秒 |

> **建议优先处理 H4 与 M6**（均为第一轮已定位、尚未落地的小改动）。M4/M5 请在下一轮补核。

---

## 2. 本轮新发现问题

### N1【中高】`deviationPoints` 负数下溢防护不一致（N81-03 的同类遗漏）

**位置**
- `CopierModel.mqh:401`（`CopierPlacePending` MT5）：`req.deviation=(ulong)deviationPoints;`
- `CopierModel.mqh:1276`（`CopierClosePartial` MT5）：`req.deviation=(ulong)deviationPoints;`
- `CopierModel.mqh:982`（`CopierClosePosition` MT5）：`trade.SetDeviationInPoints((ulong)deviationPoints);`
- MT4 分支的 `OrderSend`/`OrderClose`/`OrderDelete` slippage 参数同样直接透传。

**机制**

N81-03 只给 `CopierOpenMarket` 的 `trade.SetDeviationInPoints(...)` 加了 `deviationPoints > 0 ? (ulong)deviationPoints : 0` 防护，其余四个交易出口全部裸转型。`InpDeviationPoints` 是 `input int`（默认 30，无输入级钳位），ini 里 `deviationpoints=-5` 这种配置能合法通过 `CopierConfig::GetInt`（`IsValidInteger` 接受负号）。

`(ulong)(-5)` = 18446744073709551611，MT5 立即以 10013 (Invalid Request) 拒绝；MT4 的 slippage 负值行为未定义。受害路径是 **CLOSE / TRIM / DEDUP / PLACE-PENDING 全部执行失败**——开仓反而正常（N81-03 保护的那条），形成"能开不能平"的定向故障，且每次失败爬退避阶梯，平仓被锁定数小时。

**建议**
- 在 `ApplyCommonConfig` / `InitSenderSettings` 读取后统一钳位：`if(DeviationPoints<0) DeviationPoints=0;`（或 `MathMax(0,...)` 写回 `g_senderCfg[si].deviationPoints`）。
- 或在 `CopierModel.mqh` 四个出口入口统一 `int dev=(deviationPoints>0)?deviationPoints:0;`，与 N81-03 同款。
- 补 SelfTest 断言：`deviationpoints=-5` 的 ini 加载后 `g_senderCfg[0].deviationPoints==0`。

### N2【中】快照重建路径的收缩-再扩张 ArrayResize 与"零分配"目标相悖

**位置**：`CopierState.mqh:468-486`（`CopyToWithSlots` 尾部）、`CopierSender.mq4:1636-1677`（`RebuildSnapshotPayload` 的 static 数组）。

**机制**

`CopyToWithSlots` 在导出结束后执行 `if(ArrayIsDynamic(out) && ArraySize(out)!=n) ArrayResize(out,n);`（out 与 slots 各一次）。static 缓冲首次按 `m_n` 扩容后，每次导出又收缩回 `n`，下一 tick 持仓数回升时再次扩容。300 持仓账户上，每次快照重建（变动即触发，250ms 防抖）固定产生 2~4 次 realloc，正是 B19"全栈彻底零 ArrayResize"想消灭的形态。正确性无碍（返回值 n 是唯一有效长度），纯性能回退。

**建议**：删除尾部收缩，改为"只扩不缩"，容量由调用方首次分配决定；或以 `m_n` 峰值水位保留。

### N3【中】混合拓扑（direct + central 同时在线）下收据通道标志抖动

**位置**：`CopierSender.mq4` `SnapTrack()`（1257-1327 行）与 `SnapStaleIndex()`。

**机制**

同一 receiver 既在 direct 通道回 STAT（`SnapTrack(who,sh,false)`，sender 端 `HandleSenderStat`），又经 Hub RCPT 上报（`SnapTrack(who,rh,true)`，`HandleHubSubFrame`）时，两条路径解析出的 `who` 相同（都是 receiver 的 LOGIN/账号），共用同一个 `SnapStaleIndex` 槽位。`g_snapIsHub[idx]` 随后到的一条帧被覆盖，`SnapRepairMaybe` 的 `toHub=(g_hubOn && g_snapIsHub[idx])` 判定随之在"单播"与"全网广播"之间抖动。direct 分支的修复是广播（`Emit(...,false)`），会波及所有 direct receiver；hub 分支是单播。抖动的代价是重复快照发送与错误的通道选择，不丢数据（快照幂等），但在 direct+central 双通道部署（HANDOFF 明确支持）下是真实的浪费与告警噪声。

**建议**：`SnapStaleIndex` 的键拆分为 `(who, isFromHub)` 二元组，或在槽位内记录 direct/hub 各自的最近收据时间，修复时按通道分别限速。

### N4【低中】`UpdatePanel` 行数上界越界：orphan 展开时面板底部行被静默截断

**位置**：`CopierReceiver.mq4:7946-7954`、`CopierPanel.mqh:24`（`CP_PANEL_MAX_ROWS 24`）与 `Begin()` 的 `(rows>CP_PANEL_MAX_ROWS)?CP_PANEL_MAX_ROWS:rows` 钳位。

**机制**

receiver 面板最坏行数：`9(基础) + 1(risk) + 8(peerShow) + 1(peerMore) + 7(orphanRows=1+5+1)` = **26 > 24**。`Begin()` 钳到 24 后，`Row()` 对 `i>=m_rows` 直接 return——孤儿明细行、summary 行和末尾 spacer 被静默吞掉。N78-02 修的是"行数估多导致黑框"，没有覆盖"估少导致截断"；CP_PANEL_MAX_ROWS 也从未随 orphan 展开特性上调。sender 面板（8+8+1=17）安全，仅 receiver 受影响。

**建议**：`CP_PANEL_MAX_ROWS` 提至 28，或 `orphanRows` 展开时压缩 peerShow（同 B28 的"and N more"归并规则）。

### N5【低】`RefreshRisk` 孤儿计数在 fast path 下最多滞后 30 秒

**位置**：`CopierReceiver.mq4:4699`（isOrphan 仅在 slow path 写入）与 `4876`（orphan 计数读 `g_posCache[i].isOrphan`）。

**机制**

`isOrphan`（"magic 不属于任何 sender 但注释带 copier UID"）只在扫描慢路径（行变动或 30s 强制全扫）计算。删除一个 sender 配置后，其遗留仓位的数值字段在 fast path 全部命中缓存——`isOrphan` 沿用旧值 `false`，orphan 计数与 ORPHAN 遥测最长 30 秒内保持 0，直至下一次 30s 强制全扫。仅影响可观测性（面板/Hub 的 ORPHAN 列），不影响交易。可接受，但若希望遥测即时，可在 `LoadConfigForHub`/`reload` 成功后强制 `g_lastFullScanMs=0`（当前已做，见 1115/1773 行——**确认已有**，故此项实际只剩"单 sender 内 magic 改变"的窗口，保留为备忘，无需行动）。

### N6【低】`CopierIniReadAll` 的"残卷判定"会把全注释 ini 误判为损坏

**位置**：`CopierConfig.mqh:668-697`。`isCorrupt=(StringLen(out)==0 || StringFind(out,"[")<0 || StringFind(out,"=")<0)`——一份只有注释行（`# ...`）的合法 ini（或 `[section]` 恰好被截断只剩前缀的场景）会被回退到 `.tmp` 并覆盖主文件。边缘场景（正常配置必含 `[common]`），记录备查，不建议改动——回退方向是安全的（tmp 是更完整的副本才有效）。

### N7【低】`EncodeSenderPositions` / `SendSenderStatusReport` 每记录 O(2048) 线性查表

**位置**：`CopierSender.mq4:1905`、`1937`。按需遥测（reqpos）路径对每条持仓调 `g_prev.Find(uid)` 线性扫 2048 槽。g_prev 已有 ticket→slot 哈希索引与 `CopyToWithSlots` 零查找导出，此处改为复用 `CopyToWithSlots` 的 slots 或在 `BuildCurrent` 后缓存 row→slot 映射即可降为 O(1)。仅按需触发（WebUI 点击），非热路径，列为优化项。

---

## 3. 优化空间清单（非缺陷）

| # | 位置 | 内容 | 收益 |
|---|---|---|---|
| O1 | `CopierModel.mqh:234-270` | `CopierRealizedToday` MT4 分支全量遍历 `OrdersHistoryTotal()`，无下界剪枝（MT5 有 `HistorySelect(from,to)`）。老账户（>5000 历史单）每分钟一次全扫。MT4 历史列表顺序无保证，不能提前 break，属平台限制——建议注释说明并保持每分钟一次的节流现状 | 文档化 |
| O2 | `CopierSymbol.mqh:456-461` / `CopierReceiver.mq4:1112-1124` | 后缀试探 `CopierSymbolExists(cand)` 每次 converge 对未命中符号重复触发 `SymbolSelect`（session 缓存只覆盖 `CopierInTradingSession`，不覆盖 exists）。可对"确认不存在"的候选做一次性负缓存（按 symbol+suffix，TTL 60s） | 减少每 tick 系统调用与 Market Watch 噪声 |
| O3 | `CopierReceiver.mq4:5872-5941` | ManualClosed GC 每 sender 每 tick O(M×D)。可在 GC 前先判断 `g_manualClosed.Count()==0` 短路（已有）基础上，再把"按 mSid 分桶"从每 tick 线性查找改为 MapAdd 时的 sender 索引数组 | 手动平仓表大时消除 10Hz 扫描 |
| O4 | `CopierSender.mq4:1168` `g_announceCount` 无上界回绕 | `g_announceCount++` 永不回绕，int 溢出理论窗口约 68 年（5s 间隔）。加一行 `if(g_announceCount>CP_REG_REPEATS) g_announceCount=CP_REG_REPEATS;` 即零成本防御 | 防御性 |
| O5 | `hub/src/api.rs:1921` | `let _ = tls_mgr.reload_from_disk();` 返回值仍被丢弃。per-connection fail-closed 已兜底（H2 已修），但启动时证书损坏的原因只留在 tls 内部状态；建议 reload 失败时打一行启动 WARN，与横幅 `http://` 提示互补 | 运维可诊断性 |
| O6 | `hub/src/envelope.rs:110-128` | `decompress_field` 对 `1:<pad>:<z85>` 的判别依赖长度同余 + 单字符探测，逻辑正确（与 MQL 端 R58-05 对称），但建议把 `(flen-2)%5==0 → legacy` 这条不变量补进两端的单元测试注释，防止未来有人单侧"优化"掉 | 防回归 |

---

## 4. 已确认无问题（本轮重点排查、无需改动）

以下跨模块不变量经逐一反查消费端读值，确认闭合：

1. **`CopierDecodeSnapshot` ↔ `CopierValidateSnapshot` ↔ `HandleSnapshot` 的三方计数一致性**：`sent=min(N, CP_MAX_POSITIONS*10)`、`expected=min(sent, maxOut)`、decoded==expected 才放行；`CopierLotEncodable` 咽喉校验保证 sender 端 N 与 receiver 可解码数一致（N67-02/N70-01/N72-01 链条完整）。
2. **`CopierSeenRing` 的 m_occ 紧凑索引与 DropAt 交换删除**：Forget/ForgetPrefix/ForgetUidActions/PruneExpired 四个消费端都不在删除后前进下标，符合 DropAt 契约。
3. **`CopierBackoff` 的开放寻址**：`m_slot`/`m_h` 与数据槽的双向校验、`EraseHashSlot` backward-shift、`Note` 的"先清槽再 EraseHash"顺序、探测 256 上限——无死循环、无孤儿键。
4. **动作队列 head 偏移**：`PushAction` 的 CompactQueue 触发、`RotateQueue` 满载就地轮转、`ShiftQueue` 清字符串、`skipped<=g_qn` 硬上界——出队/轮转/压缩三路径的 `g_qHead+g_qn` 边界全部一致。
5. **ExecuteQueue 出队复核链（A86-03/N87-04）**：sender ready/stale 检查 → desired 复核（side/kind/lots 三元组 + inverttrades 换算）→ 账户与 per-sender 双风控重检 → 队列 pending 归零，与 `g_risk.AllowOpen(held+pending)` 的语义严格对齐。
6. **`QueueModifyIfNeeded` 签名缓存**：13 字段签名覆盖 desired/local 双侧几何 + `g_stOvEpoch` 失效链（ApplyCommonConfig/InitSenderSettings/SSID 变更/StopsForget/StopsPrune/MODIFY 事件/改单失败 `StopSigInvalidate`）完整；clamped 与 emergencyMissing 双出口都拒绝写入签名。
7. **Hub 转发安全（F-01/F-02/H-02）**：数据主题拒 `SID=hub`/CFG/CMD、拒 topic≠SID（SNAP 例外）、receiver 端 `CopierIsTopicTarget` 严格主题校验 + `s_errs=-999` 前缀碰撞丢弃——双侧闭合。
8. **Snap-worker 异步解析**：`last_known_receipt` 无锁前置对比 + 队列满不推进回执（F-07）+ `catch_unwind` 隔离 + 200ms poke 合并，主路由线程零解压。
9. **命令 journal 单调性**：`apply_delta_lines` 的 `(ts, rank, attempts)` 三级序 + `should_insert` 内追加（N75-01/N84-01）+ 两阶段先落盘后提交（F-01/97 轮）+ `--commands none` 的 `(0,0)` 口径（N87-03）——备机行数虚增与 1Hz 全量同步死循环的所有已知入口均已关闭。
10. **`due_gated_with`**：writes 门禁只冻结写命令、不可达 2s defer 不烧阶梯、1800s 绝对超时刷新 ts（N78-01）、阶梯耗尽刷新 ts（N82-01）——与 `recent_unknown(3600)` 告警窗口对齐。

---

## 5. 复现与验证建议

1. **N1**：ini 写 `deviationpoints=-5`，触发一次 sender 平仓，观察 MT5 日志 10013/MT4 非 0 错误码与 `trade failed ... err=` 行。
2. **N2**：300 持仓账户连续部分平仓，perf 计数器对比 `RebuildSnapshotPayload` 内 ArrayResize 次数（修复前 2-4 次/次，修复后 0）。
3. **N3**：双通道部署（HubEndpoint 与 direct 同时配置），观察 sender 日志同一条收据先 `re-sent the snapshot to receiver`（单播）后 `re-sent ... broadcast`（广播）交替出现。
4. **N4**：`ShowOrphanedList=true` 且制造 6+ 孤儿单，检查面板底部 spacer 是否消失、peer 行是否被吞。
5. **H4/M6**：按第一轮报告第 2/3 节的测试建议执行（分别补 `pass` 指纹比对与 held=0 不清明细的条件）。

---

*报告完毕。本轮所有条目均为只读排查结论，未修改任何源码。M4（WS 会话续期）与 M5（post_command 写失败语义）为下一轮待补核项。*
