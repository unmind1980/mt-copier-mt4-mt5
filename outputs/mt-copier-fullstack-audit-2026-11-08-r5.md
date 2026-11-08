# mt-copier 全栈审计（2026-11-08 r5）

> **审计执行模式**：严格只读（Strictly Read-Only），未修改任何生产代码、配置或文档。
> **审计方式**：本人单线整文件顺序通读与跨模块推演，未使用子代理。
> **代码基线**：晚于 `outputs/mt-copier-fullstack-audit-2026-11-08-r4.md` 所记快照（本轮通读期间源码未再变更）。
>
> **审计范围**（全部逐行精读）：
> 1. `doc/` 全部 13 份 MD（PROTOCOL / PHASE1-DESIGN / HA-FINAL-PLAN / SNAPSHOT-DEMAND-PLAN / TLS-SPEC / PILOT×2 / AUDIT-22/23/24）+ `outputs/` 最近 4 轮审计（11-08 comprehensive / r3 / r4 等）；
> 2. `src/Include/Copier/*.mqh` 全部 17 个头文件 + `src/Experts/CopierSender.mq4`（2511 行）+ `src/Experts/CopierReceiver.mq4`（9858 行）逐行；
> 3. `hub/src/*.rs` 全部 17 个模块（main / api / commands / config / cluster / positions / registry / envelope / curve / stats / alerts / audit / users 抽核 / lockx / tls 抽核 / notifications 抽核 / service 未逐行）逐行或重点精读；
> 4. 跨模块不变量复核（沿用 HANDOFF 审计方法：消费端实际读值、上一轮修复回归、锁范围、异步截止时间）。
>
> **本文件**：`mt-copier/outputs/mt-copier-fullstack-audit-2026-11-08-r5.md`

---

## 1. 执行摘要

r4 报告的 5 项问题（N-01 ~ N-05）中，**3 项已在当前代码中修复且有测试锁定，2 项仍未修复**（均为 Hub 侧性能/防御项，不影响交易正确性）。本轮在此基础上新发现 **6 项**（1 项 Hub 防御缺口补充、1 项 Hub 性能、2 项 MQL 一致性、1 项 MQL 性能保留项复认、1 项 Hub 卫生），**未发现任何新的交易安全级（P0/P1-交易）缺陷**。

| 编号 | 严重度 | 一句话 |
|---|---|---|
| r4-N-01 | — | **已修复**：手动平仓 ignore 带 sid 落盘，GC 三分支 + 本地票 TTL 保护 |
| r4-N-02 | — | **已修复**：`due_gated`/`ack` 全部 WAL 化（先落盘后提交内存），带失败注入单测 |
| r4-N-03 | — | **已修复**：`parse_snap` 字段序与 `CopierEncodeRec` 逐位对齐，测试更新 |
| r4-N-04 | 中·Hub | **未修**：收据去重表无容量上限，修剪仍在 ZMQ 路由线程（本轮 H-01，补充攻击面分析） |
| r4-N-05 | 中·Hub | **未修**：看板全量 JSON 仍在路由线程序列化 + WS 逐客户端深拷贝（本轮 H-02） |
| **H-03** | 中·Hub 性能 | Standby 集群 worker 每 1 秒对 5 个持久化文件做**全量 SHA-256**（F-15 移除缓存后无替代节流），commands.jsonl 可达 8 MB |
| **M-01** | 低·MQL | `CopierPayloadModifyParse` 解析 `PEXP=` 仍用 32 位 `StringToInteger`（全库 `CopierParseLong` 纪律的最后漏网处） |
| **M-02** | 低·MQL | Sender `Emit()` 未显式设置 `e.gts`，正确性依赖 MQL 结构体零初始化 + 编码器范围兜底 |
| **M-03** | 低·MQL 性能 | `CopierWaitMs` 忙等自旋（r3 N-04 未修，本轮复认并给出替代方案） |
| **H-04** | 卫生·Hub | `HubState.last_topo_sent` 按账号累积、节点驱逐时不回收 |

修复 r4 三项的质量整体很高（成对双端修复 + 单测锁定），未发现修复引入的回归；本轮第 5 节的回归核对记录可作下轮基线。

---

## 2. r4 五项逐一核实

### 2.1 r4-N-01 手动平仓 ignore 被提前 GC —— ✅ 已修复

**修复证据**（三处，缺一不可）：

1. **单笔 close 现在写入真实 sid**：`CopierReceiver.mq4` HandleCmd `op=="close"` 分支中
   `g_manualClosed.Add(uid, targetPos.ticket, sname)`（约 7443 行），`sname` 为 `MagicToSender` 解析出的
   `g_sid[si]`（仅 `si>=0` 时入环，纯手动单不入环 —— 注释明确）。r4 指出的"`Add(uid, ticket, "")` 空 sid"
   已不存在。
2. **GC 规则重写**（`ConvergeSender` 尾部，约 6545-6638）：三类条目分别处理——
   - `#t<ticket>` 占位 / 无 UID 条目：本地票仍开且未超 `CP_MANUAL_CLOSED_TTL_MS`(15min) 则保留，
     否则按"本地票消失或超 TTL"回收；
   - **带 sid 条目**：仅当 `mSid==curSid` 时处理；本地票仍开且 TTL 内 → 保留；随后检查
     `g_desired[base+d].uid == mUid` —— **按 UID 与 desired 比较，不是与空的 `cmt` 比较**，
     r4 指出的"`CopierDecodeRec` 把 `cmt` 写空导致 `anySenderHolds` 永假"的根因已消除。
     sender 不再持有才删除，操作员平仓而发送端仍持仓的场景不会再被重新开回。
   - 空 sid 遗留条目：`allSendersReady` 门 + 任意 sender 的 desired 命中即保留 + 本地票 TTL 保护，
     兜底方向安全。
3. **持久化闭环**：GC 删除即 `CmdStateSave()`（`gcChanged` 分支），单笔 close 入环即落盘；
   `CmdStateLoad` 重建 `uid|ticket|sid` 三元组。

**结论**：r4-N-01 描述的两条坏路径（空 sid 过早清除、desired 用 cmt 比较）均已闭合。

### 2.2 r4-N-02 `due_gated` 先改内存后写盘 —— ✅ 已修复

`hub/src/commands.rs` 全部写入点已统一为 WAL 顺序（锁内组候选 → `append_many` 成功 → 才提交内存/`in_flight`）：

- `due_gated_with`（约 817-928）：候选收集进 `changed`，`append_many` 失败则**返回空 Vec**，
  `attempts`/`state`/`in_flight` 全部不变；
- `ack`（约 933-985）：候选 `updated` 先 append，失败返回 false 且保持 pending；
- `issue_op` / `issue_cfg_at` / `supersede` / `apply_delta_lines`：同为先落盘。

**测试锁定**：`test_due_gated_with_append_failure_keeps_memory_intact`（替换只读 fd 注入写失败，断言
attempts 不前进、state 仍 pending、in_flight 保留）与 `test_ack_propagates_journal_error_and_keeps_the_command_pending`。
r4 引用的"`ack()` 注释声称先落盘而 `due_gated` 不是"的注释-实现不一致，现在注释与实现一致。

### 2.3 r4-N-03 Hub 快照明细字段错位 —— ✅ 已修复

`hub/src/positions.rs::parse_snap`（283-387 行）现在按
`f0=uid, f1=ticket, f2=symbol, side, lots, open_px, sl, tp, magic, open_time, kind, ptype, pprice, pstop, pexpire`
逐位对应 MQL `CopierEncodeRec` 的 10+5 字段序；单遍 `,` 迭代（HUB-08）替代旧 15 次扫描；
`effective_open_px` 对挂单用 `pprice` 兜底。测试 `reads_count_lots_symbols_and_receipt` 等的 fixture
已是真实 10 字段格式（`AAAA,9918271,EURUSD,1,0.50,...`），不再是错位时代的旧 fixture。

### 2.4 r4-N-04 收据去重表 —— ❌ 仍未修复（本轮 H-01 详述）

`main.rs` `relay_receipts`（1091-1094）仍是：
```rust
if last_rcpt_prune.elapsed() >= Duration::from_secs(60) {
    *last_rcpt_prune = Instant::now();
    last_rcpt_relayed.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(600));
}
```
无容量上限、retain 在 ZMQ 路由线程。详见第 3 节 H-01。

### 2.5 r4-N-05 看板序列化在路由线程 —— ❌ 仍未修复（本轮 H-02 详述）

`main.rs` 3378-3388：`poke_pending` 到期时路由线程调用 `api::snapshot_text(&shared)`；
snap-worker（1952-1964）同样。仅有的缓解是 `receiver_count()>0` 门 + 200ms 节流 +
`Arc<String>` 广播共享（一次序列化多端复用）。api.rs `handle_socket` 854 行
`Message::Text((*s).clone())` 的逐客户端深拷贝同样在。详见第 3 节 H-02。

---

## 3. 本轮发现清单

### H-01【中·Hub 防御】收据去重表仍无硬上限，且修剪跑在 ZMQ 路由线程上（r4-N-04 未修，补充攻击面）

**位置**
- `hub/src/main.rs:1091-1094`（60s retain / 600s 过期，无容量上限）
- `hub/src/main.rs:1105-1123`（每 pair `last_rcpt_relayed.insert`）
- `hub/src/main.rs:1863`（声明处，`HashMap<(String,String),(String,Instant)>`）

**现状与 r4 一致**：修剪只按时间（600s），无条数上限，`retain` 全表扫描跑在与 OPEN/CLOSE
转发同一条线程上。

**本轮补充的攻击面分析**（r4 只说了"伪造或配错的 STAT"，这里给出具体路径与量级）：

1. `receiver_ok` 门（`relay_receipts` 1042-1043）要求 `login` 是**已注册 receiver**（或 warm 60s 内放行）。
   因此键空间的宽度 = 已注册 receiver 数 × SID 形状空间。
2. SID 的形状校验在 `parse_rh_pairs`（970-976）：`sid` 只要求 **≤11 位纯数字**，不要求是已注册 sender
   —— sender 合法性由 `sender_ok` 判定，而 `sender_ok` 在 `warm`（启动后 60s）或 `n_senders==0` 时**对任意数字 SID 放行**。
3. 一个**已注册** receiver 每 1s 发一帧 STAT，`RH=` 最多携带 512 pair（MAX_PAIRS=512）。
   即 warm 窗口外的稳定速率是 `512 × receiver 数` 个新键/秒；600s TTL 内单 receiver 即可累积
   **~30 万键**（每键两个 String + 一个 Instant ≈ 100+ B，约 30 MB+）。
4. 每 60 秒的 `retain` 在最坏情况下做 30 万次 `Instant` 比较 + 持锁（锁是本地的 `&mut HashMap`，
   不碰 SharedState——这点比 r4 描述的轻），但**发生在线程转发 OPEN/CLOSE 的同时**，表越大停顿越可见。
5. `sender_ok` 的 `warm` 分支只在启动后 60s 内放行（F-21 已收紧过 `n_senders==0` 的永久放行），
   所以稳态下键积累要求攻击者已是注册 receiver —— 防御意义是"防止一个合法但被攻破/错配的
   receiver 把表撑爆"，而不是防陌生人。

**建议修法**（与 r4 相同方向，落地代价很小）：
- 插入时硬上限（如 4096）：满则先跑一次时间修剪，仍满则丢最旧（可用 `Instant` 最小值线性找，
  或换成带 LRU 序的小结构）；超限 pair 直接丢弃并按 60s 限频打一行 WARN；
- 修剪移出路由线程：把 `(login, sid, h, at)` 事件投递给已有的 snap-worker 或独立 1s 节拍线程，
  路由线程只做 O(1) 插入 + 内存内 3s 去重判定。

---

### H-02【中·Hub 实时性】看板全量 JSON 仍在 ZMQ 路由线程序列化；WS 推送逐客户端深拷贝（r4-N-05 / r3-N-03 未修）

**位置**
- `hub/src/main.rs:3375-3388`（路由线程 `poke_pending` → `api::snapshot_text(&shared)`）
- `hub/src/main.rs:1952-1964`（snap-worker 同型——该处在自己线程上，位置正确）
- `hub/src/api.rs:854`（`Message::Text((*s).clone())`）

**现状**：有看板连接时，每次状态变化（STAT/REG/ACK/快照收据边/告警，最密 1s 多次）在 200ms
合并窗后由**ZMQ 转发线程**执行 `snapshot_text`：克隆全部 Node（held_items/wait_items 为 Arc，
O(1) 浅拷贝——这部分已优化）+ Positions clone + 两套 JSON AST 构建。集群大、STAT 频繁时，
这是转发主循环上的周期性毫秒级抖动源。随后 N 个 WS 客户端各把整串 `Arc<String>` **深拷贝**一次
（axum `Message::Text` 需要 `String` 所有权），N 个看板 = 每次推送 N 份全量拷贝，全部发生在
tokio worker 上。

**建议修法**（分两步，互不依赖）：
1. 路由线程只投递"脏标记/版本号"：`poke_tx` 已是 `broadcast::Sender<Arc<String>>`，可再引入一个
   `broadcast::Sender<u64>`（版本号）或在 snap-worker 侧增加一个由路由线程触发的
   `mpsc::Sender<()>` 唤醒信号，把 `snapshot_text` 完全搬到 snap-worker / API 任务；
2. WS 推送改 `Message::Binary(Bytes)`（axum 支持 `Bytes` 零拷贝持有，`Arc<String>` → `Bytes`
   可用 `Bytes::from_owner(arc)`（bytes 1.x）或直接把快照缓存为 `Bytes`），彻底去掉逐客户端深拷贝。
   前端 `ws.onmessage` 对 text/binary 均可解码（需要 dashboard 一行适配）。

---

### H-03【中·Hub 性能】Standby 集群 worker 每 1 秒对 5 个持久化文件全量 SHA-256

**位置**
- `hub/src/api.rs:1976`（`spawn_cluster_worker(st, Duration::from_millis(1000))` —— 节拍 1s）
- `hub/src/cluster.rs:634-650`（Standby 分支：`users_h/notif_h/curve_h/cfg_h/cmd_h = file_sha256(...)`）
- `hub/src/cluster.rs:1106-1133`（Primary 分支同样每 tick 计算自身 5 个哈希用于 `hashes_ok` 判定）
- `hub/src/cluster.rs:175-180`（F-15：刻意移除了 `(mtime,len)` 缓存，理由是同秒同长度重写会漏复制 —— 该理由本身成立）

**问题**：F-15 移除缓存后没有任何替代节流。现在**两个方向的每一跳（1s）**都对
`users.json / alert_channels.json / curve_clients.txt / config_revisions.jsonl / commands.jsonl`
五个文件做整文件读取 + SHA-256：

- `commands.jsonl` 在触发 `COMMAND_JOURNAL_COMPACT_BYTES`(8 MB) 之前可以长到 8 MB；
- `config_revisions.jsonl` 是 append-only 且**永不压缩**（config.rs 没有 compact——每个 CFG 推送
  都追加一整份 ini，100-sender 部署单条 ~270 KB，50 次修订 ≈ 13 MB）；
- 于是 Standby（及配置了 peer 的 Primary）稳定消耗 ≈ (8+13+…) MB/s 的读盘 + 哈希 ≈ 数十 ms CPU，
  且全部发生在 tokio worker 里同步执行（会占 worker 线程时间片）。

这不含 peer 失联时的重试路径——失联分支在 `resp` 处 `continue`，不走到哈希；真正持续的消耗在
**peer 正常在线**的稳态，恰好是生产环境的常态。

**建议修法**（保持 F-15 的正确性语义）：
1. **先比廉价水位**：`needs_sync` 的前三个比较（`cfg_lines`/`cmd_lines`/`max_cmd_seq`）是 O(1)
   内存读，已经有；把**文件哈希比较降级为二级判定**——只有当行数/水位相等且"上次全量哈希
   校验距今 ≥ N 秒（如 15-30s）"时才重算哈希，否则沿用上次结果并认为 diff=false；
2. 或者**文件级 mtime+len 预检、内容哈希兜底**：`(mtime,len)` 不变时沿用旧哈希（F-15 揭示的
   同秒同长度重写窗口由"每 15-30s 强制全量重算一次"兜底），这样 F-15 的正确性缺口在最多一个
   周期内闭合，而稳态成本趋近于零；
3. `config_revisions.jsonl` 缺乏 compaction 值得作为独立项跟进（本轮未列入发现正文，仅在此附带：
   commands 侧有 `compact_journal`，config 侧没有，长期运行下它才是增长最快的一个）。

---

### M-01【低·MQL 一致性】`CopierPayloadModifyParse` 的 `PEXP=` 用 32 位 `StringToInteger`

**位置**：`src/Include/Copier/CopierCodec.mqh:788`
```mql4
if(CopierKvGet(payload,"PEXP",expStr))    p.pexpire=(long)StringToInteger(expStr);
```

**问题**：全库在 audit-17/22/23 中已把 wire 上的所有数值解析统一到 `CopierParseLong`/
`CopierParseLongRange`（ticket/magic/seq/ts/MS/OTS/REV...），这里是**最后一处仍用
`StringToInteger` 的 wire 解析**。MQL4 的 `StringToInteger` 是 32 位，`PEXP` 是 broker server
time 的 unix 秒 —— 2038-01-19 之后超过 2^31 会回绕为负，随后挂单过期时间错乱。
现实中距离溢出还有十余年，且挂单 `pexpire` 很少非零；这是一个**纪律一致性**缺口而非近期故障源
（与第 24 轮 F-04 `Magic=StringToInteger` 完全同型，那次修复时这一处漏掉了）。

**建议修法**：一行 —— `p.pexpire=CopierParseLong(expStr);`（同编译单元可见）。顺带自查
`CopierPayloadOpenParse`（707-711 行的 KIND/PTYPE/SIDE 走 `CopierKvGetInt`→`StringToInteger`）
—— 这三处值域本身 ≤ 8 位数字，32 位足够，**无需改**，但建议在注释里写明"值域受控"以免
后人误当作同类遗漏再修一遍。

---

### M-02【低·MQL 健壮性】Sender `Emit()` 未显式设置 `e.gts`

**位置**：`src/Experts/CopierSender.mq4:545-558`（`Emit`）——对照同文件 `HubAnnounce`（515）与
`EmitToNode`（620）均有 `e.gts=(long)TimeGMT();`。

**问题**：`CopierEnv` 是含 string 成员的局部结构体，MQL 保证简单类型成员零初始化，因此
`e.gts` 为 0 → `CopierEncodeEnv` 的范围检查（2020..2100 之外回退 `TimeGMT()`）会兜底，**当前行为
正确**。但正确性依赖两层的隐式假设：① MQL 结构体零初始化（未在语言规范中作为契约引用过）；
② 未来若有人在 EncodeEnv 里改动范围检查，一个未初始化的 long 若恰好落进合法区间（概率极低但
非零），会发出错误 GTS 并在 hub 端造成一次 `node.clock.drift` 误告警。三条发送路径里只有
`Emit()` 漏了显式赋值，属于同一事件三个出口的一致性裂缝。

**建议修法**：一行 —— `Emit()` 内补 `e.gts=(long)TimeGMT();`（与另两个出口对齐；代价每帧一次
`TimeGMT()` 调用，`Emit` 的调用频率为每秒几次事件 + 15s 快照，可忽略）。

---

### M-03【低·MQL 性能】`CopierWaitMs` 忙等自旋（r3-N-04 未修，复认）

**位置**：`src/Experts/CopierReceiver.mq4:3307-3315`（`CopierWaitMs`，`while(CopierNowMs()-start<waitMs){}`）；
调用点：`ExecuteQueue` MT5 async 批量平仓每 10 单 `CopierWaitMs(20)`、二段清扫前 `CopierWaitMs(30)`。

**现状**：r3 已指出——`Sleep()` 在 `OnTimer` 内无效（注释正确），于是用了忙等；代价是恰好在
"批量止损/网格集中退出"这个最需要 CPU 响应行情的时刻，EA 线程以 100% 占比空转 20-30ms，
在共享 vCPU 的 VPS 上与终端行情线程、其他 EA 抢核。r4 未列，本轮复认：**仍在代码里，且注释
已自证知道 `Sleep()` 无效，说明作者清楚这是权衡而非疏忽**。

**建议修法**（r3 建议仍有效，补充一个更小的改动选项）：
- 方案 A（r3 原案）：跨 tick 分批——每 tick 最多发 N 单，剩余留给下一个 timer tick，等效限速、零自旋；
- 方案 B（更小改动，本轮补充）：保留现有结构，把 `CopierWaitMs(20/30)` 改为
  `g_pump.ArmFast(10)` + 提前 `return`（不执行二段清扫），把剩余单据留给下一个 pump tick——
  pump 的 15ms 窗口本来就是为这种"马上再来一遍"设计的，且上限 `CP_PUMP_BURST_MAX` 保证不会失控。

---

### H-04【卫生·Hub】`HubState.last_topo_sent` 按账号累积、节点驱逐时不回收

**位置**：`hub/src/main.rs:707`（声明）、`2231-2247`（REG 分支写入）、3129-3148（registry sweep
的驱逐回收块——回收了 `node_rev`/`node_current_ini`/`alerts`/`mirrors`/`last_liveness`/
`last_cfg_pull`/`last_cfgr_print`/`last_known_receipt`，**没有** `state.last_topo_sent`）。

**问题**：每个曾 REG 过的账号在该 map 留一条 `(String,(String,String,u64,String))`（四个小串）。
节点是有限集合、增长极慢，实际风险是内存卫生与"evicted 节点复活时旧四元组命中 → 不发 TOPOLOGY"
的边界（实际无害：四元组含 epoch/role，role 翻转必不匹配，旧条目不会压制新拓扑）。与
`last_rcpt_relayed`（H-01）同类但小一个量级。

**建议修法**：registry sweep 的驱逐块里按 acc 移除 `state.last_topo_sent` 键（与 `last_known_receipt`
同一位置两行代码）。

---

## 4. 本轮已核实无问题的项（避免下轮重复排查）

以下均在本轮逐行核对范围内，确认当前实现正确，**不需要动**：

**MQL 侧**
1. **`CopierSeenRing::Add` 的 F-03 时间戳保护**（`now<=0 → 1`）在位，`GetTime` 0 值语义已唯一。
2. **`queuedCloseOrTrim` 静态数组**入口按 `queuedPrevCount` 清引用（audit-24 F-02 修复在位）；
   `BuildFromStrings` 严格按 count 边界遍历，无越界读。
3. **`PruneSenderPeakLots`** 已是 O(Desired+Acct) 标记 + 单趟压缩，压缩后 `g_peakLookup` 全清并
   立即重建（audit-24 F-04 修复在位），`moved` 变量残留已随重写消失。
4. **`CopierTradingTimes::DayOfWeek7/SecOfDay`** 已改 `TimeToStruct`（audit-24 F-05 修复在位），
   `Allows()` 的跨午夜 + 显式闭市日 + prev-day spillover 三分支自洽。
5. **止损交叉容差**（r3-N-01 修复）：`noiseTol = max(3×stopLevel, 10×point)` 区分噪声/真实击穿，
   真实击穿恢复 `CopierFitStop` 夹紧；`invertedCrossed`/`clamped`/`emergencyMissing` 三种情况
   都不写 `g_stopSig`（N70-06/BUG-12 修复在位），不会缓存交叉态。
6. **`ExecuteQueue` 退出豁免链**（r3 ISSUE-01 修复）：全局停摆、休市门禁、开盘暖期点差保护
   三处都区分 CLOSE/TRIM/DEDUP；`allMktClosed` 判定 `mktClosedHeld>=g_qn || (mktClosedHeld>0 &&
   mktClosedHeld==skipped)` 与 NotePass 的 15 分钟挂起只作用于"队列全部被休市拦"的场景；
   OnTick（9809-9842）与 5s recheck（9453-9488）双路唤醒在位。
7. **`BlockedModify` 30s 封顶阶梯**（r3 ISSUE-05 修复）+ 裸单（`CopierTicketSL<=0 && a.sl>0`）
   2s Park；MODIFY 成功双键清理（`a.key` + `#t<ticket>` 键）在位。
8. **`RefreshRisk` 双节流**（10s 未建立 / 60s 稳定）+ `IsConnected` 短路 + MT4 历史未同步守卫
   （`OrdersHistoryTotal()==0 && uptime<10s`）——`g_lastRealizedMs=now` 在短路前设置，无自激风暴。
9. **N-06 维护 REG**（`CP_REG_REFRESH_HBTS=12` ≈ 1/min）在 sender/receiver 两侧均在位；
   `Subscribe()` 幂等（`m_subSent[]` 引用计数）+ `ConnectExtraHub` 重放订阅并同步计数（N-01 在位）。
10. **XPUB 帧边界**（r3 ISSUE-09）：hub 侧 `torn_multipart` + 5 次补关重试；MQL 侧 `m_midMultipart`
    + 发送前先闭合 + `DrainFrames` 多余帧排干（L6/N57-05/F-18/L-01 全链在位）。
11. **`CopierIniValidate` 与 hub `validate_ini` 同构**（空 section、前导 k=v、空白键、section/line 上限、
    UTF-8 字节数），双端常量对齐由 `hub_config_test.py` 钉住。
12. **快照 all-or-nothing**（PROTOCOL 防线）：`CopierValidateSnapshot`（N 声明 + H= 锚定尾部重算 +
    decoded==min(sent,cap)）+ hub snap-worker 的 `N>0 && carried==0` 保留旧视图，两端一致。
13. **manualClosed 环的 L2 back-fill**（`Add` 对同 ticket/UID 复合键补齐缺失半边）在位，
    `CmdStateSave/Load` 往返完整。
14. **`CopierNid` 0 号规避**（`account<=0→999999998`、`%1e9==0→999999999`）与 Rust `copier_nid`
    逐位一致（有 `copier_nid_matches_the_mql_rule` 测试）。
15. **`StopsOvIndex` 增量插入**（`InsertString`，失败回退全重建）替代旧 O(N²) `BuildFromStrings`
    追加路径（N-04 修复在位）。

**Hub 侧**
16. **`commands.rs` 全部写入点 WAL 化**（除 r4-N-02 修复外，`apply_delta_lines`/`replace_all`/
    `issue_*`/`supersede` 同序），`prune_terminal` 的 H2 watermark 行（每 node 保留最高 seq 一条）
    防止重启后命令 ID 碰撞。
17. **`replace_all` 的 ISSUE-08 句柄恢复**：先 `file=None` → replace → **无论成败先重开** → 再传播
    错误；`inner.file.is_none()` 返回明确 `NotConnected`（commands/config 两处同型）。
18. **集群 epoch 状态机**：`next_epoch` checked_add + 拒绝 `u64::MAX` 状态文件；`demote` 不推进
    epoch（P0-2）；Standby 仅在 sync 全部成功后采纳 peer epoch（F-11）；双 Standby 决胜
    （configured-primary 优先，否则 hub_id 字典序小者胜）；split-brain 双 Primary 决胜同规则。
19. **两阶段 handover**（`cluster_handover_request`）：`is_configured_primary` 校验（N56-04）、
    `from_epoch >= local`、`from_hub_id` 非/自、peer 身份核对；退位不推进 epoch（R58-06），
    请求方 promote 到 `max(peer,local)+1`，epoch 严格单向。
20. **`require_session` 鉴权矩阵**：cluster 路径强制 `token_is_usable`（ISSUE-11 修复在位）+ 常量时间
    比较；`--users none` 时 cluster 路径对匿名直接 403（P0-2）；session 5s 复检踢除吊销会话。
21. **`logout` 免鉴权无害**：仅注销请求者自身 token，攻击者持有 token 本身即已攻破，注销反而是收敛。
22. **SSRF 防线**（notifications）：pinned client + 每次复用重验地址（F-17 TTL）、link-local/云元数据
    169.254.x/100.100.100.200/IMDS 域名无条件拒、loopback/私网按 `allow_local` 门控、
    `redirect::Policy::none()` + 显式拒绝 3xx 响应，四条渠道（TG/WeCom/DingTalk/Webhook）同构。
23. **audit.rs**：10MB 轮转 + 后台 gz 压缩（`active_worker` 互斥防并发 shift）、torn 计数、
    读路径 `Arc` 克隆后锁外 I/O（api audit_log 的锁外读取在位）。
24. **`AlertEngine`**：`risk.blocked` 不再 rearm（audit-22 A6 修复在位），`risk.tripped` 升级
    （daily→drawdown）先 rearm 再判窗口（BUG-04 在位）；`fired` map 有 `MAX_FIRED_KEYS=2048`
    上限 + 最旧驱逐；节点驱逐 `forget()` 全量回收（含 `fired.retain`）。
25. **`lockx` 毒锁恢复**哲学与 `Shared` 锁纪律：抽扫 api.rs/cluster.rs 未发现锁内磁盘 I/O
    （`save_state_to_file`/`file_sha256` 均在 `drop(s)` 之后；N72-03 模式贯彻）。

---

## 5. 建议修复批次

| 批次 | 项 | 预计改动量 | 风险 |
|---|---|---|---|
| 第 1 批（Hub 防御/实时性） | H-01（收据表硬上限 + 修剪移线程）、H-02（snapshot_text 搬离路由线程 + WS Bytes） | ~80 行 | 低-中（涉及主循环结构，建议配 chaos 测试） |
| 第 2 批（Hub 性能） | H-03（集群哈希二级判定/降频）、H-04（last_topo_sent 回收） | ~30 行 | 低 |
| 第 3 批（MQL 一致性/性能） | M-01（PEXP→CopierParseLong）、M-02（Emit 补 gts）、M-03（CopierWaitMs 方案 B） | ~15 行 | 低（MQL 侧须过 deploy→compile→selftest 门禁，条数只增不减） |

---

## 6. 覆盖范围与诚实声明

| 部分 | 深度 |
|---|---|
| `src/Include/Copier/*.mqh`（17 个） | 逐行精读 |
| `src/Experts/CopierSender.mq4` | 逐行精读 |
| `src/Experts/CopierReceiver.mq4`（9858 行） | 逐行精读 |
| `src/Scripts/*.mq4`（3 个自检脚本） | 未逐行（测试工具；selftest 门禁由 `tools/selftest_run.sh` 基线守护，未改动） |
| hub: main / commands / cluster / positions / registry / envelope / stats / curve / lockx / alerts / config | 逐行精读 |
| hub: api.rs（4625 行） | 前 ~1200 行 + 鉴权中间件 + cluster handover/promote/failback 逐行；其余（users CRUD/TLS 端点/单测）风险模式扫描（锁内 I/O、`unwrap`、免鉴权路径——未发现新问题） |
| hub: users.rs | hash/verify/session/nonce 抽核（SHA-256 迭代轮次、存储轮次随哈希走、nonce 512 槽上限） |
| hub: notifications.rs | SSRF/发送路径抽核；各渠道消息文案未逐行 |
| hub: tls.rs | 关键路径抽核（原子落盘、in_progress 失败清理、`mtc_tls_pass` 威胁模型注释——r3 N-06 已按建议落地） |
| hub: service.rs | 未逐行（Windows SCM 包装，README 有多实例说明） |
| `hub/src/assets/dashboard.html`、`tools/*.py|*.sh` | 本轮未审（r4 同；前端由 `dash_check.py`/`i18n_check.py` 门禁） |

> **结语**：本轮全程严格只读。r4 的三个正确性修复（N-01/N-02/N-03）质量很高，均带回归测试；
> 剩余两项（N-04/N-05）连续两轮未修，且 H-01 在 r4 基础上补齐了具体攻击路径与量级，建议与
> H-03 一起作为下一迭代的第一批处理。
