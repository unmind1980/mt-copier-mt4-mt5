# 快照按需补发（Snapshot on Demand）设计计划书

> 状态：**已落地实现并验证（纳入协议 v1 与双端代码）**  
> 范围：快照按需补发与投递收据规范  
> 前置阅读：`doc/PROTOCOL.md`（协议 v1）、`doc/CENTRAL-HUB-PLAN.md`
>
> 起源：流量优化 —— 将高频全量快照广播改为「**心跳带收据，缺失才补发**」。

---

## 0. 你的方案（我的理解，请核对）

1. **sender 发出快照时，附带一个 hash**（快照内容的指纹）
2. **receiver 把收到的 hash 存起来**（它**不自己算**，只是记住「我收到的是这一版」）
3. **receiver 在心跳里把这个 hash 报回去**
4. **sender 发现某个 receiver 的 hash 缺失或过期** → 只给**这一个** receiver 重发快照
5. `SnapshotSeconds` 默认从 **2 改成 10**
6. receiver 端**新增一个心跳时长 input**（现在没有）

### 这个设计比我上一轮担心的好得多 —— 关键区别

我原本担心的是「**sender 算的 hash vs receiver 算的 hash**」：两边持仓天生不等  
（滑点、部分成交、拒单、receiver 侧风控拦截），hash 永远不相等 → 永久误报。

**你的方案完全避开了这一点**：receiver **不算 hash，只存 hash**。  
它报回去的是「**我上次收到的那个快照的指纹**」，是一张**收据**，不是一次比对。

|              | 我担心的版本              | 你的版本                  |
| ------------ | ------------------- | --------------------- |
| receiver 做什么 | 自己算 hash，和 sender 比 | **存下 sender 给的 hash** |
| hash 不等意味着   | 状态分歧（无法判定谁对）        | **receiver 没收到最新快照**  |
| 误报可能         | 高（本地拦截必然触发）         | **无** —— 收据不存在「误报」    |
| 检测能力         | 「我们不一致」             | 「**你还没收到这一版**」        |

**结论：你的 hash 是「投递收据」（delivery receipt），不是「状态校验」（state check）。**  
语义干净，可以放心实现。

---

## 1. 一个决定性技术事实：两种拓扑下「定向发送」能力不同

这是本计划书最重要的一节。我在代码里核实过，**不是推测**。

### 1.1 直连模式（Direct）：**sender 无法定向发送**

`CopierSender.mq4` `Emit()` 290–292 行：

```mq4
//--- DIRECT channel: identity is the PORT, one frame.
e.sid=SenderId();
bool ok=g_tp.Send(CopierEncodeEnv(e));
```

直连通道的数据走 **单帧**（`g_tp.Send`），**没有 topic frame**。  
socket 是 **XPUB**（`CopierTransport.mqh:201`）。

**XPUB 只能按「订阅前缀」分发，不能按「订阅者身份」单播。**  
而直连模式的 receiver **没有订阅任何前缀**（它连上就收全部）——  
所以 **sender 在直连模式下没有办法只发给某一个 receiver**。

> 直连模式下，一个 sender 的 XPUB 上可能挂着**多个** receiver  
> （`CopierReceiver.mq4` 头部注释：ONE instance subscribes to N senders —— 反过来  
> 也可以多个 receiver 订阅同一个 sender）。要补发，只能**广播给全部**。

### 1.2 中枢模式（Hub）：可以定向，但**不是**用 `@<nid>`

> **⚠️ 本节原结论是错的（2026-10-13 实测后更正）。**
> 原文写「hub 已经在用 `@<nid>` 单播，所以 sender 复用即可」。
> **hub 确实在用 `@<nid>` 单播 —— 但那是 HUB 自己发给节点的**，
> 不是节点之间可以借用的通道。

`hub/src/main.rs:515` 的分支：

```rust
} else if topic.starts_with(b"@") {     // control for a node
    // 只处理 PING / REG / HBT2，其余只计数
    // **没有任何转发**
} else {                                 // 数据通路
    sock.send_multipart(vec![topic, payload.clone()], 0)   // 逐字节转发
}
```

→ **节点往 `@<anything>` 发布，会被 hub 当作「发给 hub 的控制消息」消费掉，永不转发。**
（`send_pong()`/`send_who()` 之所以能用 `@<nid>`，因为**发起者是 hub 本身**。）

**实测确认**（`tools/hub_stat_path_test.py`，对真实 `copier-hub.exe`）：
receiver 分别往 `@hub` / `@<sender nid>` / `<sender nid>` / `@all` 发同一条消息，
**sender 一条都收不到**（数据通路本身正常）。

#### 正确机制：**用「接收方自己的 NID」作为数据主题**

- **receiver**：中枢模式下**额外订阅 `(string)g_nid`**（非 `@` 前缀）
- **sender**：补发时发布到 `[(string)receiver_nid, envelope]`
- **hub**：**零改动** —— 非 `@` 主题本来就会逐字节转发，只有订阅了该前缀的那个 receiver 收到

**一个身份，两个主题，差别只在 `@`：**

| 主题 | 谁发起 | 作用 |
|---|---|---|
| `@<nid>` | **只有 hub** | hub → 节点的控制通道（PONG / WHO / `RCPT`）。节点往这里发 = 被消费 |
| `<nid>` | 任何人 | **数据**通道，逐字节转发给订阅了该前缀的节点 |

receiver 的 NID 不需要上线：`CopierNid()` 是纯函数（`account % 1e9`），
sender 从收据里的 `LOGIN` 直接算出来即可。

### 1.3 结论：**本特性分两阶段，中枢优先**

| 阶段 | 范围 | 定向能力 | 改动面 |
|---|---|---|---|
| **P1** | 中枢模式 | **可真正定向**（用 receiver 自己的 NID 作数据主题，见 §1.2） | 小（receiver 加一个订阅；**hub 零改动**） |
| **P2** | 直连模式 | 只能广播补发（XPUB 按订阅前缀分发，直连 receiver 订阅的是 `""`） | 无（复用既有 `Emit`） |

**建议先做 P1。** 直连模式的机器上通常就是 1 对 1（或 1 对少数），  
流量不是痛点；**1.5 TB/天只在 100 用户的中枢部署下才成立**。

### 1.4 ⚠️ 阻断性发现：**中枢模式下 STAT 根本到不了 sender**（2026-10-13 实测）

**上面 1.2/1.3 的结论是错的。** 中枢模式确实**能**从 hub 单播到节点  
（`@<nid>` 这条路是通的），但**收据搭乘的那班车（`STAT`）在中枢模式下不发车**。

#### 设计依据：D13 明确规定「中枢消费，不转发」

`CENTRAL-HUB-PLAN.md` 的 **D13**（**用户已拍板**的决定）：

> | D13 | `STAT` 在中央模式 | **中枢消费，不转发**。receiver 状态在**网页前端**看 |

§3.3 给出的理由：中枢本来就要拿这些数据做监控；`STAT` 的语义是  
「这个 receiver 现在怎么样」，在中央模式下**属于中枢的视图，不属于某个 sender**。  
配套的 D14 是：sender 面板**不再显示 receiver 状态行**，改为显示「中枢连接状态」。

**→ 所以「sender 收不到 STAT」不是 bug，是 D13 的既定行为。**

#### 三处代码证据

| 位置                         | 行为                                                                          |
| -------------------------- | --------------------------------------------------------------------------- |
| `CopierReceiver.mq4:3272`  | `if(g_hubOn) { g_tp.SendUp("@hub", msg); return; }` —— 中枢模式下 STAT 发往 `@hub` |
| `hub/src/main.rs:515-631`  | `topic.starts_with(b"@")` → **control 分支：消费**（只处理 PING/REG/HBT2），**不转发**    |
| `hub/src/main.rs:637`      | 只有 **非 `@`** 主题才 `send_multipart` 转发（数据通路）                                  |
| `CopierSender.mq4:501,505` | sender 只订阅 `@<自己 nid>` 和 `@all` —— **两个都是 `@` 前缀**，而 `@` 前缀被中枢消费            |

→ 结论：**receiver 无论选哪个主题，收据都到不了 sender。**

#### 实测证据（`tools/hub_stat_path_test.py`，对真实 `copier-hub.exe`）

```
PASS  receiver 发 '@hub'（代码实际用的）        → sender 收不到 STAT
PASS  receiver 发 '@<sender nid>'             → sender 收不到 STAT
PASS  receiver 发 '<sender nid>'（数据主题）    → sender 收不到 STAT
PASS  receiver 发 '@all'                      → sender 收不到 STAT
PASS  对照：sender → hub → receiver 数据通路仍然正常
hub 自己的日志确认收到 3 条 STAT，全部按 control 消费：
    [hub] up    @hub           T=STAT
    [hub] up    @252033316     T=STAT
    [hub] up    @all           T=STAT
```

#### 实盘日志证据（同一台机器，同一天，模式切换前后）

| 时段            | sender 模式                                 | sender 日志里有 receiver 状态行吗                         |
| ------------- | ----------------------------------------- | ------------------------------------------------- |
| 00:02 – 01:25 | **DIRECT**（`HubEndpoint=;`）               | **有**，每分钟一条 `receiver 252034803 status: equity=…` |
| 02:56 – 03:07 | **CENTRAL**（`HubEndpoint=127.0.0.1:6000`） | **一条都没有**（receiver 跑了 10 分钟）                      |

→ 直连模式通、中枢模式不通，**与 D13 完全吻合**。

#### 这意味着什么

**切片 A 在中枢模式下是死的 —— 而那正是 1.5 TB/天 问题唯一存在的模式。**  
直连模式通常是 1 对 1，没有流量痛点，所以「只在直连能用」等于「没有用」。

**收据本身不是「receiver 状态」**，它是「我的数据到了吗」——  
这是**投递问题**，只有 sender 能据此行动。所以它与 D13 的**原则不冲突**，  
但**当前实现把它塞进了 D13 管辖的消息里**。要解决，必须在中枢模式下给收据一条  
自己的路。

**→ 用户已选定 O1（中枢中继，新消息类型 `RCPT`），已实现并验证。见 §8。**

---

## 2. 关键设计决定（待你确认）

### D1. hash 的口径：**覆盖什么**

hash 必须**只覆盖 receiver 应当无条件复现的内容**，即 sender 真实发出的持仓。

- **参与**：每条记录的 `UID` + `SIDE`（方向）+ `LOTS`（**广播后的**，见 D2）
- **不参与**：`TKT`（receiver 侧 ticket 必然不同）、`OPN`（开盘时间可能差零点几秒）、  
  `PX`（成交价必不同）—— 这些**天生不同**，参与就必然触发补发

> 用 FNV-1a 或 DJB2 之类**简单、确定、跨平台一致**的算法即可。  
> **不要**用 MQL 没有的库，也**不要**用 `MathRand` 之类不确定的东西。  
> 目标不是防碰撞，是「这一版和上一版不同」。

### D2. hash 必须在**应用了 BroadcastLots 之后**算

`CopierSender.mq4:872` 现在的顺序：先 `BroadcastLots()` 改写 lots，再编码成 SNAP。  
**hash 必须和编码用同一份数据**，否则 hash 描述的是 receiver **不会收到**的东西。

### D3. `SnapshotSeconds` 语义**改成**「全量推送的最短间隔」，默认 **10**

**不是**简单地把 2 改成 10。原因见 §3。

### D4. receiver 新增 input：`SyncHeartbeatSeconds`（默认 1）—— **已按下方「独立 input」方案落地**

现在 receiver 的心跳（`CP_T_HBT2`）是**硬编码** `CP_HBT2_MS`（60 s），  
没有 input。新增一个，语义与 sender 的 `HeartbeatSeconds` 对齐。

> ⚠️ receiver 有**三个**「心跳」概念，名字相近但**互不相干**，加 input 时必须说清管的是哪个：
>
> - `CP_T_HBT2` → **发给中枢**的心跳（60 s，节点存活）—— **仅中枢模式**
> - `CP_T_HBT` → **sender 发给 receiver** 的账户心跳（1 s，带 BAL/EQ）—— 仅直连
> - `CP_T_STAT` → **receiver 发给 sender/中枢**的反向消息（**两种形状**，见 `PROTOCOL.md`）
>
> 最终决定（§5 Q2）：**新增独立的 `SyncHeartbeatSeconds`**，专门承载 hash 收据，
> 不复用 HBT2 —— 因为 HBT2 只在 `g_hubOn` 时发，直连模式没有它。
>
> **这里踩过的坑**：`STAT` 从此变成**每秒一条**（且按「receiver × 镜像的 sender」
> 成倍增加）。中枢原本只把 `PING`/`HBT2` 当例行不打印，于是实盘
> `hub.log` 被 `up @hub T=STAT` 刷了 1612 行 / 390 秒（约 28 MB/天）。
> 已把 `STAT` 加入 routine 名单，并由 `hub_stat_path_test.py` 断言
> 「20 条例行 STAT 零日志行」+「未知类型仍打印」。

### D5. 身份复用 `g_nid`，**不引入 UUID**

你提的「UUIDv4 + 账号」会造出**第二套身份系统**。现成的有：

- `g_nid`（账号归一化 ≤9 位，**已经是** SID + topic 二合一）
- `InstanceSuffix()`
- 幂等键 `SID:SSID:SEQ`

**定向 topic 直接用 `@<nid>`**（hub 已按此路由）。若同一账号跑两个 receiver，  
用 `InstanceSuffix()` 区分 —— 这与 `CENTRAL-HUB-PLAN.md` §6.1「同账户双 receiver  
**拒绝启动**」的既有决定一致。

---

## 3. 为什么不能简单把 `SnapshotSeconds` 改成 0（**重要**）

`SnapshotSeconds=0` 现在表示 **off**。直接关掉会同时移除三个**兜底职责**：

| 职责              | 现状                                      | 关掉后            |
| --------------- | --------------------------------------- | -------------- |
| 周期性对齐           | 每 `SnapshotSeconds`（默认 10）              | 无              |
| **（重）连时隐式同步**   | 第一个 SNAP 即全量                            | **断线重连后收不到全量** |
| **SL/TP 的兜底收敛**  | SNAP 仍带 SL/TP（**快速路径已由 `MODIFY` 事件承担**）   | **丢掉的 `MODIFY` 永远修不回来** |

第三项最危险。`MODIFY` 事件（2026-10-13 已实现）承担**低延迟**传播，
但 **SNAP 仍是收敛的唯一权威** —— 丢一条 `MODIFY` 只损失延迟，不会损失正确性，
前提是 SNAP 还在。**关掉 SNAP = 关掉兜底 = 一次丢包变成永久错误。**

### 所以正确的做法是**重新定义语义**：

```
SnapshotSeconds = 全量推送的最短间隔（下限）
  0  = 仅按需补发（不周期推送），但保留：
       · 连接后的首次全量
       · Hash 收据缺失时的补发
  10 = 至少每 10 秒一次全量（默认）
```

**「0 = 不周期推送」而非「0 = 关闭快照」** —— 兜底路径永远在线。

---

## 4. 建议的实现切片（**分步、可独立验证**）

### 切片 A（先做，风险最低）：**只观测，不补发**

1. sender：快照附带 `H=<hash>`（D1/D2 口径）
2. receiver：存下 `H`，**新增 input** `SyncHeartbeatSeconds`（默认 1）
3. receiver：心跳里带 `H=<收到的最后 hash>`
4. sender：收到心跳后，把 `H` 记录到 `g_peers` 的 `m_note[]`（**已有字段，无需新结构**）
5. sender：**只打日志** —— 「receiver X 报告的 hash 与当前不一致」
6. **不动 `SnapshotSeconds` 默认值**

**验证目标：跑几天，看「不一致」日志的频率。**

- 若几乎为零 → 方案成立，进入切片 B
- 若频繁 → 说明有我们没考虑到的路径，先查清楚再走

> 这一步**不改变任何行为**，纯粹测量。**这是最该先做的一步**，  
> 因为它用最小代价回答「这个方案到底成不成立」。

### 切片 B：**定向补发**（✅ 已实现，2026-10-13）

> 原文写「往 `@<nid>` 发全量 SNAP」——**那条路是错的**，见 §1.2 的更正。
> 实际实现如下。

**触发（`SnapRepairMaybe`）**，两道闸门都必须过：

| 闸门 | 规则 | 为什么 |
|---|---|---|
| **防抖** | 落后必须持续 `(实测心跳间隔 ≤ 2s) ? 2×间隔 : 1×间隔` | 收据**天生**滞后一点：sender 一**发出**就更新 hash，而 receiver 只能回「已**吃进**」的那版。所以每次内容变化都会开一个短窗口，让一个**完全健康**的 receiver 报出旧 hash。不防抖就会每次变化都触发一次补发 —— 正是本设计要消除的流量。**实测频率：约 6.8 分钟 3 次** |
| **限流**（Q5） | 同一 receiver 最快每 `SnapshotSeconds` 一次（`0` 时按 1s 兜底） | 一个「重发也修不好」的 receiver（socket 坏了、订阅被拒）否则会每个心跳吃一个全量包 —— 原来的流量问题，只是换了个说法 |

**发送**：
- **中枢模式** → `EmitToNode(CopierNid(LOGIN), CP_T_SNAP, payload)`，**定向**（§1.2 的机制）
- **直连模式** → `Emit(CP_T_SNAP, payload, true)`，**广播**（XPUB 无法定向；直连实际是 1 对 1）

**一个反直觉但关键的决定：补发重发的是「上一次广播的那串字节」，不是重新构建的快照。**

重新构建看起来更对，其实会**放大流量**：如果内容在广播之后变了，新构建的快照带**新 hash**，
`g_snapHash` 一移动，**所有其他收据本来正确的 receiver 也全部变成「落后」**
→ 一个 receiver 的落后会拖出全部 N 个的全量重发，定向补发直接变成 N 倍广播。

重发**同一串字节**就不可能这样：hash 不动，只有真正落后的那个受影响。
**内容变化是周期性广播的职责，不是补发的职责。**

**心跳间隔不上线**：sender 直接从收据的到达间隔测量（更诚实 —— 它含链路）。
`CopierNid()` 是纯函数，所以 receiver 的 NID 也不需要上线。

### 切片 C（可选）：直连模式定向

已随切片 B 一并处理：直连模式走 `Emit` 广播（`EmitToNode` 在非中枢时直接返回）。
直连部署实际是 1 对 1，广播即定向。

### 切片 D：**SL/TP 走独立事件（`MODIFY`）**（✅ 已实现，2026-10-13）

**动因（用户发现）**：SL/TP 变更原本只靠 SNAP 携带，所以延迟上限 = `SnapshotSeconds`。
这个决定的**原始前提是「快照 2 秒」**（`PILOT-MT4.md` 验收标准原文
"the receiver follows within ~2 s (one snapshot)"），
把 `SnapshotSeconds` 提到 10/30 就打破了这个前提。**实测延迟 3.4–5.8 秒**。

**实现**：sender 在已检测到变更的位置（`CopierSender.mq4` 的 stops 日志点）
发 `CP_T_MODIFY`，payload = `UID=..;OPN=..;SL=..;TP=..`。
receiver 侧：
- **override**：事件值放在 SNAP 值**旁边**并优先，直到 SNAP 追上（否则收敛每轮都会把它改回去）
- **限流**：新 input `StopsThrottleSeconds`（默认 **2 秒**，每仓位）限制 broker 改单频率；
  **是延迟而不是丢弃** —— 期望值仍被记住，收敛每秒重跑 10 次，窗口一开就应用

**SNAP 仍是收敛的唯一权威**：丢一条 `MODIFY` 只损失延迟，不损失正确性。

#### 实盘实测（2026-10-13，build 11:58）

按 UID 把 sender 的 `stops …` 与 receiver 的 `exec set-stops …` 配对：

| 接收端 | 平均 | 最小 | 最大 | n |
|---|---|---|---|---|
| MT5-ProgramFiles | **0.460s** | 0.442s | 0.474s | 3 |
| MT4-1 | 0.939s | **0.577s** | 2.346s | 5 |

**干净序列（同一仓位连续三次改动，两个接收端）：0.44 – 0.61 秒。**

对照改动前（同样配置、同样两个仓位）：

| 事件 | 改动前 | 改动后 |
|---|---|---|
| `A0DBBDJR` | 3.36s | 0.577s |
| `47QFW81D` | 5.84s | 0.58 – 0.61s |

→ **提升 6–10 倍，进入亚秒级。**

**唯一的离群值 2.346s 是冷启动**，不是链路：receiver 自己的决策日志
（`stops for A0DBBDJR`，就在 PushAction 之前）出现在 sender 发出后 **1.83s**，
所以延迟在 receiver 侧；同一仓位**下一次**改动是 **0.577s**。

**限流这次没有介入**（同一仓位两次改动间隔都 > 2s），所以所有干净测量都是亚秒级 ——
这符合预期：限流只在止损抖动快于窗口时才起作用。

无任何 MODIFY 相关错误 / 无 `ignoring type MODIFY`（后者会说明对端是旧版）。

### 验证

```
tools/snapshot_repair_test.py   pass=17  fail=0
tools/modify_event_test.py      pass=19  fail=0   （新增：payload / override / 限流延迟语义）
tools/snapshot_receipt_test.py  pass=37  fail=0
tools/hub_stat_path_test.py     pass=18  fail=0
bash tools/build.sh             ALL GREEN - 4 终端
```

---

## 5. 我仍需要你确认的问题

> **状态：Q1–Q6 已全部答复（2026-10-13），下表保留为记录。**  
> 答复：Q1 = 按**全量快照信息**算（含 SL/TP）；Q2 = 新增 `SyncHeartbeatSeconds`；  
> Q3 = 先做切片 A；Q4 = 连续 2 次才补发，但 `SyncHeartbeatSeconds > 2` 时一次即发；  
> Q5 = 要限流；Q6 = FNV-1a 32 位、8 位十六进制。

| #      | 问题                                            | 我的建议                                                                       |
| ------ | --------------------------------------------- | -------------------------------------------------------------------------- |
| **Q1** | hash 口径按 D1（UID+SIDE+LOTS）对吗？要不要并入 `SL`/`TP`？ | 并入 **SL/TP**，因为 SL/TP 靠 SNAP 传播（§3）；但要用**归一化后的值**，避免浮点尾差                   |
| **Q2** | 新增的 input 管哪个心跳？（D4）                          | 新增独立的 `SyncHeartbeatSeconds`，专用承载收据                                        |
| **Q3** | 先做**切片 A**（只观测）吗？                             | **强烈建议** —— 先测误报率再谈补发                                                      |
| **Q4** | 「hash 过期」的判据？                                 | 收到心跳时，若 `reported_H != current_H` → 记为待补发；**连续 N 次**（如 3 次，约 3 s）才真补发，避免抖动 |
| **Q5** | 补发要限流吗？                                       | 要。每个 receiver **最快每 `SnapshotSeconds` 一次**，否则一个卡住的 receiver 会被反复喂大包        |
| **Q6** | hash 值本身多大？                                   | 8 位十六进制（FNV-1a 32 位）。心跳里 `H=a1b2c3d4`，**十几字节**，可忽略                         |

---

## 6. 预期收益（按你的数字）

| 场景       | 现状                            | 切片 B 之后                          |
| -------- | ----------------------------- | -------------------------------- |
| 稳态（无分歧）  | 380 KB × 0.5/s = **190 KB/s** | 心跳 ~几十字节/s ≈ **0**               |
| 100 用户下行 | **~1.5 TB/天**                 | 接近 **0**（仅心跳 + 事件）               |
| 分歧时      | 全员广播 380 KB                   | **只 1 个 receiver** 收 380 KB      |
| 兜底       | 每 2 s 全量                      | 首次连接 + `SnapshotSeconds`（10 s）上限 |

> 稳态流量下降 **>99%**。**成本**：任意 receiver 最多滞后 `SyncHeartbeatSeconds`  
> 才被发现（默认 1 s）——比现在的 2 s 全量延迟**更短**，不是更长。

---

## 7. 与既有决定的一致性检查

- ✅ `g_nid` 作为定向 topic —— 与 `CENTRAL-HUB-PLAN.md` §6.1 一致
- ✅ 不引入 UUID —— 避免第二套身份
- ✅ `MODIFY` **已实现**（2026-10-13）—— 但 SL/TP **仍然**继续走 SNAP 作为兜底收敛
  （§3 已保证 SNAP 不会被关掉；`MODIFY` 只承担低延迟快路径）
- ✅ 心跳不参与交易 —— 与 `PROTOCOL.md`「`STAT` … nothing they carry feeds back into trading」一致
- ✅ 已更新 `doc/PROTOCOL.md`（SNAP 加 `H=`、STAT 收据字段与两个节拍）
- ❌ **与 D13 冲突** —— 收据搭 `STAT` 的便车，而 D13 规定中枢模式下 `STAT` 被中枢消费。  
  **见 §1.4。这是当前唯一未解决的阻断项。**

---

## 8. 未决 / 下一步

**切片 A 已实现、已编译、已验证**（32/32 + inputcheck + 4 终端 ALL GREEN），  
但第一次实盘跑（中枢模式）**观测不到任何东西** —— 原因见 §1.4。

### ✅ 已决定并已实现：中枢模式下收据走 `RCPT`（O1，2026-10-13）

用户选定 **O1**。已实现：

| 改动                                                       | 位置                                              |
| -------------------------------------------------------- | ----------------------------------------------- |
| 中枢抽出 `LOGIN`/`SID`/`H`，以新类型 `RCPT` 单播回 `@<SID>`          | `hub/src/main.rs` 新增 `send_receipt()` + STAT 分支 |
| 中枢统计新增 `receipts` 计数（中枢自己发的消息，其他计数器看不见）                  | `hub/src/stats.rs`                              |
| 新消息类型 `CP_T_RCPT`                                        | `src/Include/Copier/CopierDefs.mqh`             |
| sender 在中央通道下行（`DrainFrames`）处理 `RCPT`                   | `src/Experts/CopierSender.mq4`                  |
| **`SenderAnswersTo(id)`：sender 认两个 id**（直连=端口，中央=账号 NID） | 同上                                              |

**最后一条是实测踩出来的第二个坑**：`SenderId()` 返回的是**端口**（`EventsPort`），  
而中央模式下 receiver 报的 `SID` 是**账号 NID**（ini 里的 `id=`）。  
只认端口 → 中央模式的收据**全部被丢弃**，症状与「中继没生效」一模一样。

验证：`tools/hub_stat_path_test.py` **15/15**（含「中继确实到达」「不含任何监控数字」  
「无 SID 不中继」「发给别人的收据不会误投」）；`bash hub/build.sh --test` **23/23**。

### 实盘观测结果（2026-10-13）—— 收据通路已确认活着

用户的 MT5 ProgramFiles 终端跑 **CopierReceiver（login 53203699）**，镜像  
252033316 + 53203697；MT5 portable 跑 **CopierSender（NID 53203697）**。  
同一天里 receiver 在两种模式间切换过，**两条通路都拿到了实盘证据**：

| 时刻       | receiver 模式 | sender 日志                                                    | 说明                   |
| -------- | ----------- | ------------------------------------------------------------ | -------------------- |
| 03:20:59 | **DIRECT**  | 03:21:00 `receiver 53203699 reports NO snapshot receipt yet` | 直连：收据走 `STAT` 本体     |
| 10:06:07 | **CENTRAL** | 10:06:07 `receiver 53203699 reports NO snapshot receipt yet` | 中枢：收据走 **`RCPT` 中继** |

**→ `SnapTrack` 在两种模式下都触发了，证明收据通路（含 O1 中继）真实可用。**  
两次都报 `H` 为空，是因为**该时刻 receiver 刚启动、还没吃到快照** —— 这是正确语义，  
不是错误（`H` 为空 = 「还没有收据」，与「hash 不对」是两回事）。

### 🐞 实盘发现的 bug（我引入的，已修）

**03:21:06 的日志**：

```
receiver 53203699 status: equity= balance= held= position(s) lots= senders= risk= blocked=
```


**空数字的状态行。** 根因：`STAT` 有**两种形状**（见 §PROTOCOL「two cadences」）——  
每分钟一次是**完整监控报告**，每 `SyncHeartbeatSeconds` 一次是**纯收据**（只有 `LOGIN/SID/H`）。  
两者都是 `T=STAT`。sender 的监控日志路径**没有区分它们**，于是把纯收据当成报告打印。

我当时为**中枢中继**设计了独立的 `RCPT` 类型来避免这个问题，  
**却漏了直连模式下 receiver 自己发的纯收据 STAT 走的是同一条路**。

顺带还有一处：`g_peers.SetNote(login,risk)` 无条件执行，而纯收据的 `risk` 是空的  
→ 会把面板上的 risk 列在两次报告之间**清空**。

**修法**（`CopierSender.mq4`）：用 **`EQ` 是否存在**作为判别式  
（receiver 要么整块 figure 都发，要么一个都不发），  
`SetNote` 与状态行日志都移入 `StringLen(eq)>0` 分支；  
`g_peers.Seen(login)` 保持无条件（收据也是 liveness 信号，而且是 1/s 的高频那种）。

**为什么用「按内容判别」而不是「加新类型」**：直连模式下这条消息本来就叫 `STAT`，  
改类型要同时动 receiver、sender 和 hub 中继分支，而**判别式只是 sender 侧的健壮性**  
—— 它对任何未来的 `STAT` 形状都成立。已加契约测试钉住  
（`snapshot_receipt_test.py`「the TWO shapes of STAT must stay distinguishable」）。

### 复测确认（10:33）：**误报率为 0，收据一直匹配**

修复后重新挂载并复查四个终端，全天统计：

| 日志                        | `BEHIND` | `IN STEP` | `NO snapshot receipt` | 空数字状态行                         |
| ------------------------- | -------- | --------- | --------------------- | ------------------------------ |
| MT5-portable Sender       | 0        | 0         | 2                     | **1**（03:21:06，**修复前**的 build） |
| MT5-ProgramFiles Receiver | 0        | 0         | 0                     | 0                              |
| MT4-1 Receiver            | 0        | 0         | 0                     | 0                              |
| MT4-2 Sender              | 0        | 0         | 2                     | 0                              |
| **合计**                    | **0**    | **0**     | **4**                 | **1**                          |

**三个结论：**

1. **收据通路活着** —— 4 条 `NO snapshot receipt` 全部出现在接收方刚启动、  
   还没吃到快照的时刻，是正确语义；它们能出现就说明 `SnapTrack` 被调用了。
2. **从未 `BEHIND`** —— 没有任何一次收据与 sender 当前快照不一致。  
   **这正是切片 A 想验证的东西：误报率为 0**，所以切片 B 的  
   「连续 2 次防抖 / 按 `SnapshotSeconds` 限流」假设成立。
3. **空数字行的 bug 已修好** —— 唯一的空行属于修复前的 build；  
   修复后的 build 在**同样的直连配置**下不再产生空行，同时正常打出带数字的状态行。

> **为什么这次的「日志安静」可以当证据**：sender 在 10:31:50 重启过，  
> 而 `CopierOnceLog` 是内存态、重启即清空（去重窗口 10 分钟）。  
> 且 10:32:33 确实打出了一条带真实数字的状态行 —— **证明 `STAT` 到达了**，  
> 而不是「什么都没来」。这两点都必须先核实，否则「安静」是歧义的。

### 仍待办

- **实盘复测切片 B / D**：重新挂载后观察
  - `re-sent the snapshot to receiver …` = 补发真的跑过（看不到是**好事**，说明没落后）
  - `exec set-stops …` 距 sender 的 `stops …` 应缩到**亚秒级**（原本 3.4–5.8 秒）
- **hub 的 `receipts` 计数**是外部唯一能确认收据中继活着的信号
  （sender 只在「落后」或「补发」时打日志，健康系统里它什么都不打）
- **✅ SL/TP 延迟已解决**：`MODIFY` 事件（切片 D）承担低延迟路径，
  SNAP 保留为兜底。`SnapshotSeconds` 保持 10 不再有止损延迟代价。
- 新测试（`snapshot_repair_test.py`、`modify_event_test.py`）未接线到聚合 runner

### 备选方案存档（当时的三选一）

| #           | 方案                                                                   | 改动面                                       | 与 D13 的关系                                                        |
| ----------- | -------------------------------------------------------------------- | ----------------------------------------- | ---------------------------------------------------------------- |
| **O1 ✅ 已选** | **中枢中继收据**：hub 收到 `STAT` 后，抽出 `SID`+`H`，用 `@<SID>` 单播回 sender        | hub 小改（解析并重建一条 control 消息）；sender 加一个解析分支 | **最贴合 D13 原则**：状态数字仍停在中枢，只把「投递收据」这**一个非状态信号**放行                  |
| O2          | **独立收据主题**：sender 额外订阅 `<nid>R`，receiver 把收据发到 `<nid>R`（非 `@`，中枢会转发） | **hub 零改动**；两端各加一个订阅/发布                   | 与 D13 不冲突（不走 STAT），但引入**第二套主题命名**，与 §2 D5「复用 g_nid、不造第二套身份」的精神相悖 |
| O3          | **收据不进中枢**：只在直连模式启用切片 A；中枢模式的补发另想办法                                  | 无                                         | 不冲突，但**放弃了唯一的痛点场景**（§1.4 末段）                                     |

选 O1 的理由：收据不是「receiver 现在怎么样」，而是「我的数据到了吗」——  
D13 管的是前者，O1 放行的是后者，所以它是 D13 的**细化而非违背**；  
而且它复用中枢**已经**在用的 `@<nid>` 单播路径（`send_pong` 同一条），  
不新增主题命名空间（避免 O2 的第二套身份问题）。

**兜底方案（未采用，留档）**：若只想让观测先跑起来，把 receiver 的 `HubEndpoint`  
清空改成**直连**即可 —— 实盘日志已证明直连的 `STAT` 到得了 sender，  
代价是那台机器上没有中枢。
