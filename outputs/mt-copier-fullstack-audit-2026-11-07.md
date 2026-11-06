# mt-copier 全栈只读审计（2026-11-07 / 第 110 轮）

> **审计对象**：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
> **代码基线**：`HEAD = bbaa07f`（工作区干净），即 r3 报告（`outputs/mt-copier-fullstack-audit-2026-11-06-r3.md`）之后 8 个提交：`fafedce`（r3 收尾）、`22c76ea` / `de3c78c`（F-19 基准）、`1eedd93`（队列零进展退避）、`c2fc106`（扫描/对账同节拍 + 每趟判定缓存）、`617c75c` / `5e40adf` / `bbaa07f`（自检修复与基线记录）。
> **方式**：单进程整文件顺序通读，未派发子代理。
> **约束**：**只读**。未修改任何源码、配置、服务或测试；本文件是唯一新增文件。
> **定位**：本报告只列**新问题**与**上轮修复的残余**，不重复已闭环项；第 3 节给出 r3 → 现代的逐条复核结论。

---

## 0. 通读范围与方法

**逐文件通读（MQL）**

| 文件 | 规模 |
|---|---|
| `src/Include/Copier/*.mqh`（17 个：Defs / Codec / State / Risk / Sizing / Symbol / Filter / Transport / Config / Model / Peers / Pump / Ignore / Log / Cluster / Panel / CurveKey） | 约 39 万字符 |
| `src/Experts/CopierSender.mq4` | 108 KB，2477 行 |
| `src/Experts/CopierReceiver.mq4` | 420 KB，9256 行 |

**逐文件通读（Rust）**

`envelope.rs`、`positions.rs`、`registry.rs`、`stats.rs`、`lockx.rs`、`config.rs`、`commands.rs`、`cluster.rs`、`main.rs` 全文；`notifications.rs` 的 `resolve_pinned_client` 全段；`api.rs` 的鉴权中间件、`commands_global`、`post_command`、`cluster_sync`、`cluster_failback_now`、`Shared` 结构。

**文档**

`README.md`、`doc/AUDIT-23/24-FINDINGS.md`、`outputs/*2026-11-06-r3.md`、`doc/HANDOFF.md` 第 109 轮全段与章节目录、`doc/PROTOCOL.md` 章节结构、`.workbuddy-ai/memory/MEMORY.md`。

**未逐行覆盖（如实标注）**

- `src/Scripts/CopierSelfTest.mq4`（3222 行）只看了被引用处，未逐条核对断言；
- `hub/src/api.rs` 其余约 3000 行（config PUT/rollback、TLS 端点、用户管理、告警渠道 CRUD、WebSocket 帧循环）、`notifications.rs` 各渠道发送体、`tls.rs`（1740 行）、`users.rs`、`audit.rs`、`alerts.rs`、`curve.rs`、`service.rs`；
- `hub/src/assets/dashboard.html`（453 KB 前端资源）；
- `doc/PROTOCOL.md` 正文、`doc/HANDOFF.md` 第 1–108 轮正文、`CENTRAL-HUB-PLAN` / `PHASE1-DESIGN` / `PILOT*` / `SNAPSHOT-DEMAND-PLAN` / `TLS-HTTPS-SPECIFICATION` 全文。

这些不在本轮结论的举证范围内；凡是引用它们的结论，均已在代码里复核过一遍。

---

## 1. 结论摘要

| 编号 | 端 | 等级 | 一句话 |
|---|---|:---:|---|
| **N-01** | MQL 传输 / 订阅 | **中** | `HubAnnounce` 每 5 秒重复 `Subscribe()`，XPUB 的 `(pipe,prefix)` 引用计数单调累加 → `Unsubscribe()` 实际永远无效，配置里删掉的 sender 仍持续收到数据 |
| **N-02** | API / HA | **中** | F-14 只改了舰队级端点：Standby 上 `reqpos/reqcfg` 返回 202、写进本地命令日志，但 Standby 从不跑命令派发器 → 命令永不执行，82 秒后变 `unknown`；每节点端点仍 409（两端行为还不一致） |
| **N-03** | MQL 持仓/手数 | **中** | `g_uidPeakLots` 容量是 `CP_MAX_POSITIONS`（2048）而不是「每 sender 2048」；多 sender 合计超过 2048 个 UID 后，后加入的 UID 拿不到 peak → FIXED 模式的按比例减仓静默退化为不缩放 |
| **N-04** | MQL 止损覆盖 | **中** | `CP_MAX_STOPS_OV = 512`，而持仓容量是 2048；覆盖表里的活 UID 不会被 `StopsPrune` 回收 → 大账户下超过 512 个 UID 后，新 `MODIFY` 事件被直接丢弃，止损只能等下一次快照（≤15 s） |
| **N-05** | Rust 收据中继 | **中低** | `relay_receipts` 的 receiver 合法性判定与 F-21 修好的 sender 侧不对称：`n_receivers == 0` 是**无时限**放行，任意 `LOGIN` 都能被当作 receiver，并给真实 sender 制造镜像边与单播 `RCPT` |
| **N-06** | MQL 传输 | **中低** | `SendUp` 双发只保证「至少一帧发出」（`sent > 0`），无法区分「两个 Hub 都收到」；一个 pipe 不可写时两份都会落到同一 pipe，而调用方看到成功 → Standby 可能静默漏掉 `REG/ACK/STAT`，节点却已把 `g_announceCount` 推到饱和 |
| **N-07** | MQL 配置序列化 | **低中** | `SerializeCurrentConfigToIni` 仍是「每个 sender 一个 `out` 累加器」的块内 O(n²)：满配 100 senders 每次序列化约 9 MB 复制，而它在每次 CFGRPT / `IH=` 失效后的 REG 上都会跑 |
| **N-08** | 跨端配置校验 | **低中** | 512 KB 上限两端单位不同：Hub 用 UTF-8 **字节数**（`ini.len()`），节点用 **字符数**（`StringLen`）。含中文注释的配置会被 Hub 提前拒绝，「同一决策、两种语言」只对纯 ASCII 成立 |
| **N-09** | Rust 命令日志 | **低** | `CommandStore::ack()` 先改内存、后追加日志，追加失败只打印仍返回 `true`；重启后该命令重新变 `pending` 并被重发（节点按 id 去重，能自愈，但与同文件其他地方的「先落盘再提交」纪律不一致） |
| **N-10** | MQL 命令处理 | **低** | `HandleCmd` 的 `close` 把 `PushAction` 的所有失败原因都报成 `queue_full`；实际最常见的失败是退避窗口（`g_backoff`）或 in-flight 抑制 |
| **N-11** | MQL 去重环 | **低** | `g_everOpened` TTL 设成 12 小时，而它在 OnInit 的注释里写的是「survives long enough to recognise a restore **a day later**」——跨夜后同一 UID 的恢复会被当作首次打开 |
| **N-12** | MQL 日志 | **低** | `CopierLog::Emit` 每写一行都 `FileFlush`；74 单突发的开/平仓各一行，会在一个 tick 里产生 74 次刷新 + 74 次 `Print` |

---

## 2. 新发现详解

### N-01【中 · 订阅】周期性重复 `Subscribe()` 让 XPUB 引用计数单调增长，退订永久失效

**位置**

- `src/Include/Copier/CopierTransport.mqh:448-462`（`Subscribe` 无条件 `send("\x01"+prefix)`，即使该前缀已在 `m_subPrefixes` 里）
- `src/Include/Copier/CopierTransport.mqh:464-477`（`Unsubscribe` 只发**一次** `"\x00"+prefix`）
- `src/Experts/CopierReceiver.mq4:7312-7320`（`HubAnnounce` 末尾**每次都**重新订阅 `@<nid>`、`@<rawAcc>`、`@all`）
- `src/Experts/CopierReceiver.mq4:6505-6535`（`ResubscribeSenders` 在 CFG/reload 后对移除的 sender 调 `Unsubscribe`）

**推导**

1. `HubAnnounce` 由 `OnTimer` 每 `CP_HBT2_MS = 5000` 调用一次（`CopierReceiver.mq4:8686-8695`），另外每次收到 `WHO` 也会调（`RouteMessage` 的 `CP_T_WHO` 分支）。函数末尾无条件执行 2–3 次 `g_tp.Subscribe(...)`。
2. `Subscribe` 里的 `found` 只用于「是否记入重放表」，**不阻止发送**：

```mql4
if(!found && m_nSubPrefixes<CP_MAX_XSUB_SUBS)
  { m_subPrefixes[m_nSubPrefixes++]=prefix; }
return m_sub.send("\x01"+prefix,true);   // ← 每次调用都发
```

3. libzmq 的 XPUB 把订阅存进 `mtrie`，**同一个 pipe 上重复 `0x01<prefix>` 只是把该节点的 refcnt 加 1**（`xpub_t::xread_activated` → `_subscriptions.add()`；`mtrie` 在路径已存在时 `refcnt++`）。`0x00` 只减 1，减到 0 才真正移除。

后果：

- 一个 receiver 启动后 5 秒内就会把 `@<nid>` 的计数推到 ≥2；跑一天约 5 万个计数。**之后任何一次 `Unsubscribe` 都只是把计数从 N 减到 N-1，XPUB 仍然继续把该前缀投递给这个 pipe。**
- 于是「从 copier.ini 删掉一个 sender」的语义变成：receiver 不再镜像它（`SenderIndexById` 返回 -1，`RouteMessage` 直接 `return false`），但**它每个快照仍然全网投递到这台 receiver**（100 sender / 15 s 周期下是一条持续的无效下行）。
- Hub 侧 `st.subs` 是同一个计数的镜像：`-sub ... (N subscriber(s) remaining)` 会打印出远大于真实订阅者的数字，`/api/v1/topology` 的订阅视图随之失真。
- `ConnectExtraHub`（`CopierTransport.mqh:427-443`）还会在新 pipe 上把 `m_subPrefixes` 全部重放一次；libzmq 的 `xsub_t::xattach_pipe` **本身就会把订阅 trie 重放到新 pipe**，这次重放是重复的，把新 pipe 的计数直接推到 2。

**建议**

1. `Subscribe` 里 `found == true` 时直接 `return true`（不发帧）；只有 `ConnectExtraHub` / 重连才需要重放，而那条路径应当**只重放一次**并记录「已重放」；
2. 或者把 `m_subPrefixes` 改成 `prefix -> 已发送次数`，`Unsubscribe` 发同样次数的 `0x00`；
3. `HubAnnounce` 的「周期性重新订阅」（N73-06 的意图是对的：初次订阅帧可能丢）改成**只在 `m_nSubPrefixes` 不包含该前缀时**订阅，或改成每 N 次心跳最多重订阅一次并在重连时清零。

这一条不会造成错误交易，但它让「退订」这个安全阀长期处于关闭状态，且症状（带宽、Hub 统计、看板订阅数）都不指向根因。

---

### N-02【中 · HA / API】Standby 上的只读命令被接受，但永远没有派发者

**位置**

- `hub/src/api.rs:2829-2839`（F-14 的改动：`if !is_primary && !is_read_only { 409 }`）
- `hub/src/api.rs:2594-2600`（每节点端点：`if !is_primary { 409 }`，在 `is_read_only` 判断之前）
- `hub/src/main.rs:3223-3231`（命令阶梯派发：`if is_prim { ... due_gated ... }`）
- `hub/src/commands.rs:838-842`（`--writes off` 时只读 op 会继续走阶梯）

**推导**

F-14 的修复本身是对的：`commands_global` 现在允许 Standby 上执行 `reqpos` / `reqcfg`。但派发器只在 Primary 上运行（`main.rs:3229`，F-02 的注释解释了为什么 Standby 不能跑 `due_gated`——它会把 Primary 复制过来的只读命令再发一遍、并推进自己的 attempts）。

于是 Standby 上 `POST /api/v1/commands {"op":"reqpos"}` 的完整生命周期是：

1. `issue_op` 把命令写进 **Standby 自己的** `commands.jsonl`（多了一行，Primary 没有）；
2. 返回 202 + `command_id`；
3. 没有任何线程会发送它 —— `due_gated` 在 Standby 上不跑；
4. 82 秒后（`RETRY_LADDER_SECS` 走完）它仍是 `pending`，但 **attempts 永远停在 0**，所以连 `unknown` 都不会变（`unknown` 是 `due_gated` 判定的）；
5. 下一次与 Primary 同步时，`cmd_lines_count > remote_st.cmd_lines` → `full_cmd_resync` → `replace_all` 把这一行抹掉。

**净效果**：接口说「已受理」，节点什么也没做，日志里既没有失败也没有超时，运维看到的是「点了几次刷新，看板还是旧的」。

同时两个端点的行为不一致：舰队级允许、每节点 409。一个按节点刷新的按钮（看板的单节点「刷新持仓」用的正是 `POST /api/v1/nodes/{id}/commands`）在 Standby 上仍然被 409。

**建议**（二选一，别停在中间态）

- **A（最小改动）**：`commands_global` 也改回「Standby 一律 409」，并在响应里写清「只读查询请在 Primary 上执行」——诚实，但功能没有增加；
- **B（符合 F-14 的本意）**：Standby 收到只读 op 时**转发给 Primary**（`POST {peer_url}/api/v1/nodes/{id}/commands`，带 cluster token），把 Primary 返回的 `command_id` 透传给调用方；本机不写 journal。这需要在 `post_command` 与 `commands_global` 两处都实现，并处理「切主过程中 peer 恰好不可达」的回退（返回 409 + 原因）。
- 无论选哪个，`post_command` 与 `commands_global` 的 Standby 判定必须抽成同一个函数，否则下一次还会漂。

---

### N-03【中 · 手数】峰值手数表按「全局 UID 数」计容，超过 2048 后 FIXED 模式的按比例减仓静默退化

**位置**

- `src/Experts/CopierReceiver.mq4:1030-1037`（`g_uidPeakLots[CP_MAX_POSITIONS]`，**一个全局表**）
- `src/Experts/CopierReceiver.mq4:1114-1135`（`GetOrUpdateSenderPeakLots`：表满 → `return curLots`，不记录）
- `src/Experts/CopierReceiver.mq4:1065-1112`（`PruneSenderPeakLots`：只回收「既不在 desired、也不在账户」的 UID）
- `src/Experts/CopierReceiver.mq4:4086-4108`（`ComputeTargetLotsForMirror` 的 FIXED 分支用 `desired.lots / origLots` 做比例）

**推导**

`g_uidPeakLots` 是 receiver 级别的单表，容量 2048 —— 这正好等于**一个** sender 的持仓上限（`CP_MAX_POSITIONS`），而不是 `CP_MAX_SENDERS × CP_MAX_POSITIONS`。注释里对 `g_desired` 的解释（「每个 sender 一片 2048，只为实际配置的 sender 分配」）在这里没有对应的结构。

触发条件很普通：**两个 sender 各持 1200 个仓位**（合计 2400 > 2048），或一个 100-sender 的配置里合计超过 2048 个活跃 UID。

表满时：

- `GetOrUpdateSenderPeakLots` 调 `PruneSenderPeakLots()`，而后者把「在 desired 里」和「在账户里」的 UID 全部标记为 alive —— 表里全是活的，**一个都删不掉**；
- 于是 `g_uidPeakLotsCount` 停在 2048，新 UID 走 `return curLots`；
- `ComputeTargetLotsForMirror` 的 FIXED 分支拿到 `origLots == desired.lots`（因为每次快照都会用当前 lots 更新「峰值」），`desired.lots < origLots` 永远为假 → **targetLots = baseLots**，不再按发送端的减仓比例缩放。

结果：发送端把 2.00 手减到 1.00 手，接收端的 FIXED 0.50 手**不会**跟着减到 0.25，而是保持 0.50 —— 接收端比发送端重一倍，且没有任何日志。这与 N57-10 修掉的那个 bug 同一类，只是触发条件是「UID 总数」而不是「固定手数模式」。

**建议**

- 结构上：把 peak 存进 `g_desired` 的行里（`CopierPos` 已经有一个未被 wire 使用的 `profit/swap` 槽位习惯，但更干净的是新增一个 `initLots` 字段，或复用 `g_openLots` 那套按 slot 保存并在状态文件里持久化 `ILOT:`）；
- 或者把表按 `si` 分片：`g_uidPeakLots[si * CP_MAX_POSITIONS + i]`，容量与 `g_desired` 同构；
- 无论哪种，`GetOrUpdateSenderPeakLots` 在「表满且无法回收」时必须 `Error` 一次（当前是静默返回），否则这个退化永远只能靠对账发现。

---

### N-04【中 · 止损】`CP_MAX_STOPS_OV = 512` 小于持仓容量 2048，表满后 `MODIFY` 事件被直接丢弃

**位置**

- `src/Experts/CopierReceiver.mq4:407`（`#define CP_MAX_STOPS_OV 512`）
- `src/Experts/CopierReceiver.mq4:6376-6405`（`StopsOvIndex(uid, true)`：满 → `StopsPrune` → 仍满 → 返回 -1）
- `src/Experts/CopierReceiver.mq4:7126-7147`（`HandleModifyEvent`：`idx < 0` → 打一条 WARN 并 `return`，**事件丢弃**）
- `src/Experts/CopierReceiver.mq4:6414-6475`（`StopsPrune`：带 override 的条目只要 UID 还活着就**永不回收**）

**推导**

`StopsPrune` 的规则是：`g_stHasOv[i] == true` 且该 UID 仍在 desired 或账户里 → 保留。而 `HandleModifyEvent` 对**每一个**收到过 MODIFY 的 UID 都会把 `g_stHasOv` 置 true。于是：

- 一个持有 2000 个仓位、且发送端设了移动止损的账户，会在第一次触及第 513 个 UID 时把表填满；
- 之后每一个新的 MODIFY（哪怕是已有 UID 的）都走 `StopsOvIndex(uid,true)`：`StopsPrune` 删不掉任何东西 → 返回 -1 → 事件丢弃；
- 止损只能等下一次快照（`SnapshotSeconds` 默认 15 s）才生效。

正常情况下 15 秒是可接受的（`PROTOCOL.md` 的「MODIFY 不是必需，只是延迟优化」）。但这里有两个额外代价：

1. 表满期间 `HandleModifyEvent` 每个事件都会尝试一次 `StopsPrune`（`PruneSenderPeakLots` + 全量 alive 标记 + 重建哈希索引），在 2000 仓位下这是每个事件 O(desired + acct) 的工作，而事件率最高可达 4 Hz/仓位；
2. 日志只有一条限频 WARN（`stopsovfull`），运维无法从面板看出「止损事件正在被丢」。

**建议**

- 把容量提到 `CP_MAX_POSITIONS`（2 KB × 512 → 8 KB × 2048 的结构体开销可接受：string 引用 + 5 个 double + 2 个 long ≈ 80 B，2048 条约 160 KB，与 `g_desired` 的 30 MB 相比可忽略）；
- 或者按 `si` 分片（与 N-03 同一处方）；
- `StopsPrune` 增加「无 override 且超过 maxThrottle 窗口」的快速淘汰（现在这部分逻辑是对的，只是对有 override 的条目无能为力），并在表满持续超过 N 分钟时升级为 Error 并把计数上报到 STAT（`WAIT`/`BLOCKED` 旁再加一个即可）。

---

### N-05【中低 · 安全】收据中继的 receiver 判定与 sender 侧不对称

**位置**：`hub/src/main.rs:1031-1048`

```rust
let receiver_valid = login_is_receiver || warm || n_receivers == 0;
...
let sender_ok = sender_valid && (sid_is_sender || warm);
```

F-21 把 sender 侧收紧成「注册表为空时只有前 60 秒可以猜」，但 receiver 侧保留了 `n_receivers == 0` 的**无时限**分支。于是：

- 一个只注册了 sender、还没有任何 receiver 在线（新集群、或全 fleet 重启后的头几秒）的 Hub，会接受**任意** `LOGIN` 的 STAT，把它当作合法 receiver；
- 对每个这样的 `LOGIN`，`s.mirrors[sid].insert(login, now)` 都会新增一条镜像边（`main.rs:1051-1060`），并给它发一条 `RCPT` 单播；
- 攻击者不需要任何凭据：只要能把两帧消息发到 Hub 的 ZMQ 端口（CURVE 只证明「有密钥」，不证明「是 receiver」），就能让真实 sender 对一个不存在的 NID 反复发送快照修复。

影响是有界的（只影响 sender 的 `SnapTrack` 计数与单播流量，不改变任何交易），但这个不对称本身就是 F-21 想消除的那类「空集合 ⇒ 永久放行」。

**建议**：`receiver_valid = login_is_receiver || (warm && n_receivers == 0)`，与 sender 侧完全同构；另外 `login` 也顺手约束形状（纯数字 ≤ 11 位），非法 `LOGIN` 在进入状态锁之前就丢掉。

---

### N-06【中低 · 传输】`SendUp` 的双发只保证「至少一帧发出」

**位置**：`src/Include/Copier/CopierTransport.mqh:535-563`

```mql4
int copies=(m_connectedHubs>1) ? 2 : 1;
int sent=0;
for(int i=0;i<copies;i++){ ... if(!m_sub.send(payload,true)){...continue;} sent++; }
return (sent>0);
```

**推导**

注释（R60-18 / ADR-02）的假设是「XSUB 的 round-robin 会把两份分别落到两个 pipe」。这只在**两个 pipe 都可写**时成立：如果其中一个 pipe 满/断开，`sendMore` 或 `send` 返回 EAGAIN，那一份被跳过，另一份仍然落到**同一个** pipe。函数返回 `true`，调用方（`HubAnnounce`、`SendCfgAck`、`CopierSendStatus`）都认为「两个 Hub 都收到了」。

后果集中在 `REG`：

- Hub A 收到、Hub B 没收到；
- `g_announceCount`（receiver）/ `g_announceCount`（sender）仍然自增并在 `CP_REG_REPEATS` 处饱和，**之后永远只发 HBT2**；
- Hub B 只能靠自己的 `WHO` 60 秒 sweep 把节点找回来。在此期间 B 的 `/nodes` 里该节点是「匿名」或缺失，而 A 的看板一切正常——这种「一半 Hub 看不见」的故障最难定位。

**建议**

- 让 `SendUp` 返回实际成功的帧数，或至少返回 `sent >= min(copies, 可写pipe数)`；调用方在控制帧上「成功但不确定」时可以退化为「下一拍再 REG 一次」（把 `g_announceCount` 的回退条件从「次数」改成「最近一次 REG 之后是否收到过 Hub 的任何回帧」）；
- 或者更简单：`HubAnnounce` 不依赖 `SendUp` 的返回值，而是**每 N 次心跳补发一次 REG**（例如每 12 次 HBT2 补一次 REG），代价是每节点每分钟多 1 条 ~120 B 的控制帧，换来「任一 Hub 最多 60 秒内一定知道这个节点」。

---

### N-07【低中 · 性能】`SerializeCurrentConfigToIni` 的块内 O(n²) 仍在

**位置**：`src/Experts/CopierReceiver.mq4:1662-1777`

函数头注释正确地指出了 `out += ...` 在 270 KB 上是 O(n²)，并把结果 flush 进 `CopierStrBuilder`。但 flush 的粒度是**每个 sender 块**（`sb.Add(out); out="";`），块内仍是 74 次 `out += "key=value\n"`：

- 单块最终约 2.5 KB，74 次追加的平均复制量约 1.2 KB → 单块约 90 KB，100 senders ≈ **9 MB 复制**；
- 这段代码在 `CurrentIniHash()`（`IH=` 失效后的第一次 REG）和 `SendCurrentConfigReport()`（每次 CFG 应用、每次 `reqcfg`）上运行，都在 EA 主线程。

对比：`CopierIniEscape`（`.mqh:516-545`）用的是 128 字符 run 缓冲，才是真正的线性。这里只是把 1 GB 降到 9 MB，没有降到 O(n log n)。

**建议**：块内改成每行直接 `sb.Add("key=" + value + "\n")`（单行很短，`+` 的临时量在 100 B 量级），或者保留 128 字符 run 缓冲。改动机械、语义不变（输出字节完全相同，`IH=` 不受影响），可用现有 `SelfTest` 的配置哈希断言回归。

---

### N-08【低中 · 跨端】512 KB 上限两端单位不同：Hub 按字节，节点按字符

**位置**

- `hub/src/config.rs:947`：`if ini.len() > MAX_INI_BYTES`（UTF-8 字节数）
- `src/Include/Copier/CopierConfig.mqh:609-615`：`int len=StringLen(ini); if(len>CP_INI_MAX_BYTES)`（UTF-16 码元数）
- 两处注释都写着「one decision, two languages」「`hub_config_test.py` asserts the two are equal」

**推导**

对纯 ASCII 配置，两者相等，测试也是用 ASCII 配置跑的。但对**含中文注释**的配置（`CONFIG` 注释里专门讨论过的那类用户）：

- 一个中文字符在 UTF-8 里 3 字节、在 MQL 的 `StringLen` 里 1；
- 于是 Hub 在约 512 KB / 3 ≈ 17 万字符时拒绝，而节点要到 512 K 字符才拒绝。

方向是**保守**的（Hub 更严），不会出现「Hub 推了、节点拒绝」的死循环，所以不是 HUB-03 那类问题。但「同一份 ini 两端判定不同」这个不变量已经不成立了，而它正是 F-06 花了一整轮去对齐的东西。

**建议**：MQL 侧改成按 UTF-8 字节数计量（`StringToCharArray(s, buf, 0, -1, CP_UTF8)` 的长度，去掉尾部 0），与 `CopierCfgHash` 已经在做的字节化保持一致；或者在 `hub_config_test.py` 里补一条「含非 ASCII 的大配置两端必须同时接受/拒绝」的用例，把差异显式化。

---

### N-09【低 · 命令日志】`ack()` 先改内存、后写盘，写失败仍返回 `true`

**位置**：`hub/src/commands.rs:904-941`

```rust
c.state = new_state.to_string();  // 内存先变
...
if !inner.append(&updated) { eprintln!(...); }   // 只打印
true
```

`issue_cfg` / `issue_op` / `due_gated` 都遵守「先落盘，失败就不提交内存」；只有 `ack()` 反着来。

影响有限：重启后该命令在日志里仍是 `pending`，会被重发；节点按 id 去重、把同一个 ACK 再回一次，第二次 `ack()` 就会落盘成功。所以这是**可自愈**的。但一个「内存说 acked、磁盘说 pending」的窗口，与 `commands.rs` 顶部对「journal 是唯一真相」的论证相矛盾；也会让 `prune_terminal` 在重启前误判（内存里 terminal、日志里 pending → `in_flight` 重建时又把它当 pending）。

**建议**：与 `issue_*` 对齐 —— 先 `append`，成功后再改内存；失败返回 `false` 并保留 `pending`（让阶梯继续走）。

---

### N-10【低 · 日志语义】`HandleCmd` 的 `close` 把所有 `PushAction` 失败都报成 `queue_full`

**位置**：`src/Experts/CopierReceiver.mq4:6998-7027`

```mql4
queued=PushAction(...);
...
else { g_cmdAck="ID="+id+";OK=0;ERR=queue_full;..."; }
```

`PushAction` 返回 false 的原因至少有五种：seen-ring 命中、in-flight 抑制、退避窗口（`g_backoff.BlockedCapped`）、unsupported 表、队列满。只有最后一种才是 `queue_full`。

实际的常见场景：同一次 `close` 被 WebUI 重试（用户连点），第二次落入 1 秒的 CLOSE 退避 → 回 `OK=0 queue_full` → Hub 的审计记录 `command.rejected`，而实际上第一条已经排队。

**建议**：`PushAction` 增加一个 out 参数（或返回枚举），至少区分 `already_queued`（当前 `ActionQueued` 已经单独判过一次）、`backoff`、`queue_full`。ACK 文案跟着分，Hub 的 `command.rejected` 才不会误报。

---

### N-11【低】`g_everOpened` TTL 12 小时 vs 注释里的「a day later」

**位置**：`src/Experts/CopierReceiver.mq4:7699`（`g_everOpened.SetTtlMs(12*60*60*1000)`）与其上方注释。

`ReopenClosedMirrors=false` 的语义是「这个镜像曾经被本接收端打开过，操作员手工平掉后不要再自动恢复」。12 小时后该 UID 的记录过期，同一 UID（发送端仍持有、接收端被手工平掉）会再次满足 `!reopenclosedmirrors && g_everOpened.Has(...) == false` → 被当成**首次打开**恢复。

跨夜（比如周五手工平掉、周一开盘）恰好超过 12 小时，是最常见的场景。

**建议**：改成 7 天或与 `g_fillDropped` 一致的 24 小时以上；或者干脆不设 TTL，让 `PruneExpired` 之外的淘汰交给「sender 不再持有该 UID」（状态文件重建时自然消失）。

---

### N-12【低 · 性能】`CopierLog::Emit` 每行一次 `FileFlush`

**位置**：`src/Include/Copier/CopierLog.mqh:245-274`

```mql4
FileWrite(m_handle,line);
FileFlush(m_handle);
Print("[Copier] "+line);
```

正常情况一天几十行，无所谓。但两个场景会撞上：

- 74 单突发的开仓/平仓各打一行 Info（sender 的 `open`/`close`、receiver 的 `exec open`/`exec close`），一个 tick 内 74 次 flush + 74 次 `Print`；
- `--verbose` 或 `LogLevel=3` 下的心跳/对账行。

MQL 的 `FileFlush` 会把 CRT 缓冲写回内核（不是 fsync），但在 GDI/Print 也参与的情况下，一个 tick 内的累积延迟足以让下一次 `OnTimer` 延后。

**建议**：把 `FileFlush` 从 `Emit` 移到 `Tick()`（`OnTimer` 末尾已经每拍调用一次），或在 `Emit` 里按「距上次 flush ≥ 200 ms 或行数 ≥ 20」再刷。崩溃时最多丢 200 ms 的日志，对这个用途完全够。

---

## 3. r3 修复的逐条复核（现代码）

| r3 项 | 结论 | 证据 |
|---|---|---|
| **F-01** `CopierIniCmpNormalize` O(n²) | **已修，且实现正确** | `CopierConfig.mqh:836-866`：`CopierIniEffEnd` + `CopierIniCmpDiff` 双游标，零分配 O(n)；`\r` 在两侧都忽略、尾部换行归一。`CopierIniWriteAtomic` 只在 `ReadAll` 成功后比较一次。 |
| **F-02** bat `%VAR%` 延迟展开 | **已修（脚本侧）** | 见 HANDOFF 第 109 轮；`--instance` 在块外定义并改用 `!VAR!`。本轮未逐行复核 5 个 bat（不在代码审范围内）。 |
| **F-03** `CP_STAT_RH_CHUNK` 与分块收据 | **已修，且有 Rust 单测锁算术** | `CopierDefs.mqh:252` = 4096；`CopierReceiver.mq4:9140-9174` 每个 chunk 都带 `SID=`/`H=`（不只第一块）；`main.rs` 的 `a_full_configuration_fits_in_one_receipt_frame` 断言 100×21 < 4096。 |
| **F-04/F-16** 批量收据的锁与全表扫描 | **已修** | `main.rs:993-1066`：一次 `shared` 锁、一次 `reg.nodes()` 快照（`HashSet`）、一次 primary 判定，锁外只做去重与 `send_receipt`。 |
| **F-05** 只配日内限额时零净值闩死 | **已修** | `CopierRisk.mqh:214-251`：`m_zeroDaily` / `m_zeroDd` 双标志，恢复计数不依赖 `m_zeroDd`；`Configure()` 变化时四个标志一并清零。 |
| **F-06** 两端 ini 形状校验 | **已修，两端同构** | `CopierConfig.mqh:606-682` 与 `config.rs:917-1003` 规则一致（首节前 key、空节名、空白 key、节数/行数、行数按 `lines()` 口径）。**残余只有 N-08 的字节/字符口径**。 |
| **F-07** B3 只警告不阻断 | **维持原状（记录在案）** | `CopierIniWriteAtomic` 仍是 WARN + `return true`。现在的代价已经小（F-01 修好），但「磁盘上是 `?` 版本、内存是对的」这个窗口仍在。等 `FILE_UNICODE` 或纯 ASCII 转义。 |
| **F-08** `RH=` 字段无形状校验 | **已修** | `main.rs:948-978`：`sid` 纯数字 ≤11、`h` 空或 8 位 hex；`MAX_PAIRS=512`。单测覆盖分隔符注入。 |
| **F-10** B1 空 hash 跳过比较 | **已修，且对称** | `ClusterStatusResponse` 新增 `notif_enabled` / `curve_clients_enabled`（`#[serde(default)]`），`cluster.rs:675-684` 按**路径**判 enabled，旧对端回退到「hash 非空」。 |
| **F-11** 同步失败仍采纳 epoch | **已修** | `cluster.rs:940-946`：`sync_clean = file_sync_err.is_none()`，只有干净才提代并落盘。 |
| **F-13** 压缩字段失败语义 | **已修** | `envelope.rs:189-191` 返回空串；snap-worker（`main.rs:1890-1908`）增加「`N>0` 且 carried==0」的整帧忽略 + 保留上一视图。 |
| **F-14** Standby 只读查询 409 | **只修了一半** | `commands_global` 放开（`api.rs:2833`），但派发器只在 Primary 跑（`main.rs:3229`），且 `post_command` 仍 409 → **N-02**。 |
| **F-15** `file_sha256` 的 (mtime,len) 缓存 | **已修** | `cluster.rs:163-168` 每次全量读 + SHA-256，缓存删除。 |
| **F-17** 通知连接池 | **已修** | `notifications.rs:1286-1387`：`(host:port)` 缓存、TTL 300s、上限 64、命中时**重新校验** IP 是否仍允许、`redirect(none)`、`resolve_to_addrs`。 |
| **F-18** 尾帧残局 | **已修** | `CopierTransport.mqh:526-534` 先补空帧闭合，失败则本次不发；`m_midMultipart` 两端各有一条 Error 日志。 |
| **F-19** 报价年龄哈希 | **维持不做（有实测依据）** | HANDOFF 第 109 轮记录：16 符号 0.75 µs、100 符号 3.1 µs；真正成本在「休市时队列每 tick 全走一遍」，已由队列退避 + memo 256 + 4 Hz 对账解决。**本轮认同不做**。 |
| **F-20** `receipts_seen` 口径 | **确认无需改** | 现在每 pair 一次，与改造前「每帧恰一个 pair」的总数等价；`main.rs:1087-1095` 注释已写明。 |
| **F-21** 冷启动反射面 | **sender 侧已修；receiver 侧仍有缺口** | `main.rs:1048` 的 `sender_ok` 正确；`receiver_valid` 仍是 `... || n_receivers == 0` → **N-05**。 |

**r3 之后新增的三处改动（`1eedd93` / `c2fc106`）复核结论**：队列零进展退避（`CopierState.mqh:1470-1489`）的「只周期调用点查截止时间、事件驱动不查、`PushAction` 清零」三条不变量在 `ExecuteQueue` 与 `OnTimer` 里都对得上；`CopierConvergeDue` 的「dirty 优先、sweep 兜底、0=旧行为」正确，`g_convergeDirtyAll` 在 `HandleCfg`/`HandleCmd reload`/`ExecuteQueue(done>0)` 三处置位齐全；`SaveReceiverMap` 的 `didScan` 前置避免了「用空缓存覆盖状态文件」。未发现回归。

---

## 4. 优化空间（低风险、可不做）

| 编号 | 位置 | 内容 |
|---|---|---|
| **O-01** | `CopierDefs.mqh:780-811` `CopierKvGet` | 每次从 payload 头开始 `StringFind`。receiver 处理一条 STAT 要取 ~20 个 key（`main.rs` 侧同构），1 KB payload × 20 次 ≈ 20 KB 字符扫描/帧。100 sender × 1 Hz 约 2 M 字符操作/秒。可改成一次 `;` 分割后按 key 查（注意保留「key 必须是完整段」的语义，别退回 `LOTS`/`OTS` 那个坑）。 |
| **O-02** | `CopierReceiver.mq4:5048-5060` `EncodeReceiverPositions` | 每条记录 12 次 `+`，产生 11 个中间字符串。2048 条 × 每分钟一次 ≈ 2 万次临时分配。可改成 `sb.Add` 逐字段（builder 已在用），或至少把 `CopierFmtDouble` 的 5 次调用结果先落到局部变量。 |
| **O-03** | `CopierReceiver.mq4:1105-1111` `PruneSenderPeakLots` 重建 `g_peakLookup` | 重建时 `g_peakLookup[h]=k+1` 是**直接覆盖**，碰撞时后写者赢，前者只能靠 `PeakFind` 的线性回退。正确性没问题（命中前比对 uid），但碰撞率高时 `PeakFind` 退化为 O(n)。可改成带探测的写入（与 `CopierUidIndex::Build` 同构）。 |
| **O-04** | `CopierReceiver.mq4:9043-9055` | `dueSummary` 每 5 秒发一次 `HELD/LOTS/ORPHAN/WAIT/.../EQ/BL`，其中 `EQ`/`BL` 变化最频繁。看板需要 5 秒新鲜度，但 `ORPHAN`/`WAIT` 这类计数可以降到 30 秒（它们的来源 `RefreshRisk` 本身是 4 Hz）。收益是每条 STAT 少 ~60 B × 100 sender × 12 次/分钟。 |
| **O-05** | `CopierSymbol.mqh:238` `CP_SYMVERDICT_SLOTS 8` | 8 槽的每趟判定缓存对「一 symbol 一仓位」的网格没有命中率（每个 symbol 在 pass 内只问 1–2 次）。它不会变慢（miss 落到原谓词），但注释里「hit is one compare」的收益描述与实际工作集不符；要么把注释改成「只对同一 symbol 的重复提问有效」，要么按 `CP_SYMFRESH_CACHE` 那样做直接映射。 |

---

## 5. 测试缺口（按优先级）

1. **订阅计数**（N-01）：`tools/` 里加一个 XSUB/XPUB 计数用例 —— 同一 pipe 发 3 次 `\x01X`、1 次 `\x00X`，断言 Hub 仍向它投递 `X`（复现），修好后断言停止投递。这一条用现有 `zmq_bidir_test.py` 的骨架就能写。
2. **Standby 只读命令**（N-02）：`hub_cluster_test.py` 加一条 —— Standby 上 `POST /api/v1/commands {"op":"reqpos"}`，断言要么 409（方案 A）、要么 Primary 的 `commands.jsonl` 多一条且 Standby 的没多（方案 B）。当前实现会「202 但两边都没派发」。
3. **FIXED 模式超 2048 UID 的比例减仓**（N-03）：`CopierSelfTest` 目前的比例减仓用例是单 sender、少量 UID。构造「两个 sender 各 1200 个 UID + 其中一个 sender 把 2.00 减到 1.00」，断言 FIXED 目标从 0.50 变 0.25。这条用例在现有实现上会失败，正好锁住 N-03。
4. **止损覆盖表满**（N-04）：构造 513 个 UID 各发一次 MODIFY，断言第 513 个之后的事件是否被丢（当前会丢），以及表满时是否只打一条 WARN。
5. **收据的未知 LOGIN**（N-05）：`hub_stat_path_test.py` 加一条 —— 注册一个 sender、不注册 receiver，用任意 `LOGIN` 发 `STAT`，断言不产生镜像边/`RCPT`（修好后）。
6. **双 Hub 单 pipe 可写**（N-06）：`zmq_bidir_test.py` 已有「uplink round-robin」用例；补一条「其中一个 pipe 的 HWM 被占满」的场景，断言 `SendUp` 的返回值能反映「只有一份发出」。
7. **INI 上限两端一致**（N-08）：`hub_config_test.py` 用含中文注释的 ini 恰好卡在 512 KB 边界，断言两端同时接受/拒绝。

---

## 6. 结论

- **交易正确性路径**（快照校验、序列水位、seen-ring、去重、止损重锚、反向映射、MT5 10016 降级、手工平仓环）本轮**未发现新的逻辑错误**；r3 的 14 项修复经逐条复核，除 F-07（有意保留）与 F-14（只修一半）外均已正确落地，且新增的单测/断言覆盖了对应的算术边界。
- 真正值得排期的三件事是 **N-01（退订失效）**、**N-02（Standby 只读命令空转）**、**N-03 / N-04（大账户下的两个 512/2048 容量错配）**。前两个是行为/运维层面的「说了但没做到」，后两个只在满配账户上暴露，但一旦暴露就是「接收端比发送端重」或「止损晚 15 秒」。
- 其余为低风险清理项，可随下一次性能专项一起做。

---

## 7. 本轮修复状态（同日落地）

审计结束后按「能改就改、大改先确认」处理，结果如下。

| 编号 | 状态 | 落地内容 |
|---|:---:|---|
| **N-01** | **已修** | `Subscribe` 幂等 + `m_subSent[]` 计数，`Unsubscribe` 按实际发出的帧数补 `0x00`；`ConnectExtraHub` 的重放同步计数。 |
| **N-02** | **已修（方案 A）** | `commands_global` 与 `post_command` 统一：Standby 对**所有**命令（含只读）返回 409，响应带 `primary` 地址。方案 B（转发到 Primary）需要新增 cluster-token 端点，留待确认。 |
| **N-03** | **已修** | `CopierPos` 增加 `initLots`（接收端本地字段，不上线），快照/开仓事件维护「该 UID 见过的最大手数」，`ComputeTargetLotsForMirror` 用它做 FIXED 比例基数；容量随 `g_desired` 变成每 sender 2048 行。全局表保留为 `ClearDesired()` 后的兜底（保住重启前已减仓的峰值）。规则抽成可测的 `CopierNextInitLots()`。 |
| **N-04** | **已修** | `CP_MAX_STOPS_OV` → `CP_MAX_POSITIONS`；新增 `CopierUidIndex::InsertString()` 消除插入时的整表重建（O(n²)→O(1) 摊销）。 |
| **N-05** | **已修** | `receiver_ok = login_is_receiver \|\| warm`，与 F-21 的 sender 侧同构。 |
| **N-06** | **已修** | `CP_REG_REFRESH_HBTS = 12`：初始 burst 之后每分钟补一次 REG，双 Hub 单边丢失可在心跳节拍内自愈。 |
| **N-07** | **已修** | 86 处 `out +=` 机械改造成 `sb.Add(...)`（脚本变换 + 逐行核对），输出**逐字节不变**，块内 O(n²) 变成每行一次有界追加。 |
| **N-08** | **已修（节点侧）** | 新增 `CopierUtf8Bytes()`，`CopierIniValidate` 改按 UTF-8 字节比较。`hub_config_test.py` 的非 ASCII 边界用例仍未补。 |
| **N-09** | **已修** | `ack()` 改为先 append 再提交内存；写失败返回 false 并保留 pending。新增单测。 |
| **N-10** | **已修** | `PushAction` 新增 `g_pushReject`，close 的 ACK 按真实原因回 `ERR=`。 |
| **N-11** | **已修** | `g_everOpened` TTL 12 h → 7 天，并提为 `CP_EVEROPENED_TTL_MS`（自检可断言）。 |
| **N-12** | **已修** | 日志改为每 tick 一次 flush，ERROR 仍立即 flush；`Open()` 重置 `m_dirty`。 |

**验证**

- MT4 / MT5 × Sender / Receiver / SelfTest = **6 个目标 0 错误 0 警告**；全量 `tools/compile.sh` 对 5 个终端 **ALL GREEN**。
- **MQL 自检：715 条断言 / 0 失败**（708 → 715；新增 7 条：UTF-8 字节计数 ×3、`everOpened` TTL 下限、峰值手数规则 ×3），`BASELINE` 已提到 715。
- Rust 单测 **172/172**（新增 `test_ack_propagates_journal_error_and_keeps_the_command_pending`）。
- `hub_cluster_test.py` 新增两条「Standby 只读命令必须 409」断言 —— **未执行**：6380–6383 端口空闲，但 `hub/target/release/copier-hub.exe` 被在线的两个 Hub 占用，无法重建 release 二进制。

**N-03 为什么没有简单地「把表调大」**

`g_uidPeakLots` 的问题是它**全局共享**一个 `CP_MAX_POSITIONS` 预算，而 `PruneSenderPeakLots` 无法回收仍在 desired 里的 UID —— 调大只是把临界点往后推。改到 `g_desired` 行上以后，容量天然随 sender 分片，且不需要改协议（`initLots` 不上线）。保留全局表只为一件事：`ClearDesired()`（sender 重启 / 新 SSID）之后的第一份快照没有「上一行」可继承，而重启前的峰值正好存在表里，否则一条已经减过仓的持仓会被重新放大。

---

*报告完毕。第 1–6 节是审计时的只读结论（基线 `bbaa07f`），第 7 节记录同日的修复；所有改动均可按 `文件:行号` 核对。*
