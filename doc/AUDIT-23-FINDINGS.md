# 全栈审查报告（第二十三次·只读排查）

> 基线：commit `77b6d0c`（第二十二次审计全部落地后）
> 性质：**只读审查，未改动任何源码**（`git status` 干净）
> 范围：MQL4/MQL5 客户端、Include 头文件、Rust Hub、Web 前端、测试与部署工具
> 重点：上一次提交新引入代码的回归，以及此前未覆盖的角落

---

## 结论概览

本轮确认 **2 个需要修复的问题（1 个 P1 + 1 个 P2）+ 3 个低优先级清理项**。
没有发现致命级（P0）问题；第二十二次审计的修复经抽查全部正确落地。

最需要优先处理的是 **F-01：配置热重载不会失效停止几何缓存**——这是上一次审计
B8 优化引入的回归，影响实盘止损止盈的正确传播。

---

## F-01【P1】配置热重载不失效停止几何缓存，改 `inverttrades` / 紧急止损后已存在镜像不更新

**位置**
- `src/Experts/CopierReceiver.mq4:379`（`g_stOvEpoch` 声明）
- `src/Experts/CopierReceiver.mq4:3248-3263`（缓存查询，命中即 return）
- `src/Experts/CopierReceiver.mq4:3287`（唯一的 `g_stOvEpoch++`）
- `src/Experts/CopierReceiver.mq4:1158-1279`（`ApplyCommonConfig`）、`1281+`（`InitSenderSettings`）

**问题**

`QueueModifyIfNeeded` 的几何指纹缓存（第二十二次审计 B8）用
`g_stopSig[sh].epoch == g_stOvEpoch` 判断缓存是否过期。但 `g_stOvEpoch`
**只在 override 被快照追上时自增**（3287 行）。全文件没有任何其他地方动它。

签名覆盖的输入只有：`desired.sl/tp/openPx`、`local.sl/tp/pprice/pstop/pexpire`、
`local.ticket`。以下会改变计算结果、但**不在签名里**的输入，在配置热重载后
（Hub 推送 CFG 或 `reload` 指令 → `LoadConfigForHub` → `ApplyCommonConfig` /
`InitSenderSettings`）不会触发重算：

| 输入 | 变化后果 |
|---|---|
| `g_senderCfg[si].inverttrades` | 止损止盈的**方向定义整体翻转**，已存在镜像保留旧方向止损 |
| `g_senderCfg[si].emergencySLPips` / `emergencyTPPips` | 发送端无止损的已存在镜像**永远拿不到**紧急止损 |
| `si2.stopLevel`（券商 `SYMBOL_TRADE_STOPS_LEVEL`，行情/新闻期会变宽） | 已存在镜像的止损不会被重新钳位 |

**触发路径**：操作员在 Web 可视化配置里把某 sender 的 `inverttrades` 从 0 改成 1
→ CFG 推送 → Receiver 热应用 → 已持仓的止损止购维持原样，**直到发送端下一次
修改该仓位的止损，或该订单换 ticket（MT4 部分平仓重开票）才纠正**。

**影响**：中危。新开仓不受影响（新 ticket → 缓存未命中）；只有"改配置前就已
存在"的持仓受影响，且表现为"止损没跟着改"而不是"乱改"。

**建议修法**：在 `ApplyCommonConfig()` 与 `InitSenderSettings()` 末尾各加一行
`g_stOvEpoch++;`（每次 reload 一次，不在热路径上）。或者更精确地把
`inverttrades` / `emergencySLPips` / `emergencyTPPips` 三项并入签名（`v[8..10]`）。

---

## F-02【P2】`EncodeReceiverPositions` / `EncodeReceiverWaitList` 仍是 `out+=`，是 B1 优化漏项中最重的一处

**位置**
- `src/Experts/CopierReceiver.mq4:3819-3862`（`EncodeReceiverPositions`，`out+=` 在 3843-3853）
- `src/Experts/CopierReceiver.mq4:3865-3896`（`EncodeReceiverWaitList`）
- 调用点：`src/Experts/CopierReceiver.mq4:6844-6845`（每分钟一次 + WebUI 按需刷新）

**问题**

第二十二次审计 B1 用 `CopierStrBuilder` 消除了
`SerializeCurrentConfigToIni`、`CopierIniEscape/Unescape/ReadAll`、
`CopierEncodeSnapshot` 五处 O(n²) 字符串拼接，但**漏了这两处**。而 A2 恰好把
它们的上限从 128 提到了 `CP_MAX_POSITIONS`（2048），使它们成为全库剩下的
最大拼接点：

- `EncodeReceiverPositions`：每条记录 9 次 `+=`，2048 条 × ~70 字符 ≈ 143 KB
  成品，累计拷贝 ≈ **146 MB memcpy / 分钟**（`sum(i*70)`），全部发生在 EA
  主线程——正是要同时应答快照和下单的那个线程。
- `EncodeReceiverWaitList`：≤ 384 条（`g_qn` ≤ 256 + `g_waitItemsCount` ≤ 128），
  ≈ 5 MB / 分钟，量级可忽略，但顺手一起改更一致。

**影响**：P2。2048 持仓的大型账户上每分钟一次可见卡顿（数十毫秒级）；持仓
< 500 的普通账户无感。

**建议修法**：两处都改用局部 `CopierStrBuilder`，每条记录 `sb.Add(...)`，
返回 `sb.Result()`。与 B1 已改的五处写法完全一致。

---

## F-03【P3】`CopierBackoff::Clear()` 每次成功动作都全量重建哈希索引

**位置**
- `src/Include/Copier/CopierState.mqh:970-979`（`Clear` → `EraseHash`）
- `src/Include/Copier/CopierState.mqh:866-872`（`EraseHash`：256 桶清零 + 每个活跃键一次 `HashOf`）
- 调用点：`src/Experts/CopierReceiver.mq4:2875`（每个成功执行的动作后，含每个 OPEN）

**问题**

`EraseHash` 的注释说"erases are rare"，但 `Clear()` 并不稀有——它在
`ExecuteQueue` 的成功分支里，每个成交动作调一次。每次都是 256 桶
`ArrayInitialize` ×2 + N 次完整字符串哈希（N = 活跃退避键数）。

**影响**：P3。实测量级很小（100 活跃键 ≈ 1 万次简单操作/次 Clear，
10 动作/秒 ≈ 1% 以下 CPU），但与注释的假设不符，且是纯浪费。
`Clear()` 的 `m_k[i]=""` 先于 `EraseHash(i)` 的顺序是**正确的**（重建时
已排除被清除的键，无墓碑条目）——这一点已核实无问题。

**建议修法**：改用线性探测的 backward-shift deletion（教科书做法，O(1) 摊销），
或至少给"键已在索引中"的清除加一条跳过重建的快速路径。

---

## F-04【P3】`ResetRuntimeInputsFromInputs` 的 `Magic = StringToInteger(mStr)` 是全库最后一处 32 位用户长整型解析

**位置**：`src/Experts/CopierReceiver.mq4:1109`

**问题**

第十七次审计已把 ticket/magic/openTime/seq/ts 等全部换成 `CopierParseLong`，
但 EA 输入参数 `InpMagic`（字符串型）的解析漏了一处。MQL4 上用户输入超过
2^31 的 magic 会回绕成负数，之后 `g_magic[0]` 与发送端永不相匹配。

**影响**：P3。魔法数字惯例上都远小于 2^31，实际触发概率极低；属于一致性遗留。
`CopierParseLong` 就在同一编译单元可见的 `CopierDefs.mqh` 里。

**建议修法**：`Magic = CopierParseLong(mStr);`

---

## F-05【P3】死代码清理

**位置**
- `hub/src/assets/dashboard.html:2964-2991`（`renderRecPositions()`）+
  `hub/src/assets/dashboard.html:1408`（`<div id="recposbody" class="hidden">`）
- `src/Include/Copier/CopierDefs.mqh:781`（`CopierStrBuilder::Length()`）

**问题**

1. `renderRecPositions()` **从未被调用**（全文件无调用点），其宿主
   `#recposbody` 永久 `hidden` 且永不填充。这是早期 Receiver 汇总表改版为
   Split Cockpit 后的残留；函数内部还是 `host.innerHTML = ...` 整树重建写法。
2. `CopierStrBuilder::Length()` 从未被调用，且语义有歧义——返回的是**已 flush
   的块数**（`m_n`），不是字符长度，容易被后来者误用。

**影响**：无功能影响，纯维护性。约 30 行死 JS + 1 个孤儿 DOM 节点 + 1 个
误导性命名的访问器。

**建议修法**：删除 `renderRecPositions` 与 `#recposbody`；删除或把
`Length()` 改名为 `ChunkCount()`。

---

## 本轮已核实无问题的项（避免后续重复排查）

以下都在本次逐行核对范围内，确认正确，**不需要动**：

1. **`CopierStrBuilder` 成对合并算法**：奇数尾处理、`Result()` 后状态重置、
   六处调用点均为"局部构建 → 单次 `Result()`"，无重复消费。
2. **`SerializeCurrentConfigToIni` 重构后逐字节等价**：刷新点按 sender 块边界
   切分，输出序列与旧版 `out+=` 完全一致 → `IH=` 配置哈希不受影响。
3. **`CopierDecodeRec` 无 `StringSplit` 重写**：边界扫描对空字段、字段数 <10
   拒绝、>15 字段截断的行为与旧 `StringSplit` 一致；15 字段挂单记录 round-trip
   由 `snapshot_receipt_test.py` 覆盖。
4. **三个直接映射缓存全部比对校验、安全**：`g_peakLookup`（A3）、
   `g_magicLookup`（B9）、`CopierOnceLog::m_lookup`（A8）命中均校验
   UID/key 后才信任；`ForgetSenderPeakLots` 与 `PruneSenderPeakLots` 的交换
   压缩都正确失效了受影响的两个缓存槽。
5. **magic 缓存的热重载清空**：`MagicLookupClear()` 在直连（1031）与 Hub
   （1651）两条配置路径上、`g_magic[i]` 赋值之前调用。
6. **Sender 表满防御（A4/A5）**：`g_prev.IsFull()` 时拒绝铸造新 UID 并
   `continue`；`InsertEmpty` 返回值有检查与限频告警。
7. **`CopierBackoff` 槽位映射（审计21 BUG-01）**：`Find` 经 `m_slot[k]-1`
   取数并比对 key；`InsertHash` 探测有界；`EraseHash` 墓碑条目因比对校验
   不会给出错误答案；`Note()` 里的防御性 `EraseHash` 实际不可达。
8. **CFGR 门禁与重复发送（审计19 BUG-05）**：`args.writes` 门禁在位，手动
   `send_cfg` 已移除，统一走 `due_gated`。
9. **`commands.rs` 批量 fsync / prune / compact（B5/B6）**：运行时 prune 只
   影响内存，重启时 `load()` 会重新 prune，无"删除的数据复活"问题；
   `compact_journal` 先写临时文件再原子 rename；`issue_cfg` 的 60s revive
   冷却正确。
10. **WebSocket 广播合并（B3）**：`poke_pending` 标志 + 200ms 合并 +
    `Arc<String>` 单次序列化；锁外序列化、每连接一次发送；
    `Lagged` 语义正确（客户端会收到更新状态）。
11. **配置历史瘦身与按需拉取（B4）**：`history()` 移除 ini 仅留 `ini_bytes`；
    新增 `/config/revision/:rev` 路由；前端 `#cfgloadhist` 改为 fetch 且有
    完整错误分支；同源 fetch 自动携带 `mtc_session` cookie，认证无缺口。
12. **A2 扩容全链路容量一致**：Receiver 编码上限 `CP_MAX_POSITIONS`(2048)
    ≤ Hub `MAX_RECORDS`(4096)；POS 记录 10 字段与 `registry.rs:177-191` 的
    解析（9 必选 + 第 10 可选）对齐；前端 `renderPositions` 按 sender 渲染
    （≤100 行），明细在驾驶舱内。
13. **驾驶舱明细行的 HTML 字符串缓存**：行内容全是稳定字段（ticket/symbol/
    lots/open_px/sl/tp/comment，无实时价列），稳态下缓存命中，不存在每秒
    整树重建——此前担心的"实时价格导致缓存永不命中"不成立。
14. **`stats.rs` REG 告警**：`nodes_count.max(1)` 除零保护在位。
15. **`alerts.rs` risk.blocked 不 rearm（A6）**：符合设计意图——接收端每 60s
    例行清零 `BLOCKED`，"归零"不是恢复；真正的恢复由 `risk.tripped` 分支
    （驱动于不例行重置的 RISK 字符串）负责 rearm。
16. **`EncodeReceiverPositions` 内的 `CopierReadCommentByTicket`**：每分钟
    对每个本方持仓一次 `OrderSelect`，2048 持仓下是可接受的一次性成本。

---

## 建议修复顺序

| 批次 | 项 | 预计改动量 |
|---|---|---|
| 第 1 批（建议） | F-01（`g_stOvEpoch++` 两行） | 2 行 |
| 第 2 批 | F-02（两处改 `CopierStrBuilder`） | ~20 行 |
| 第 3 批（可选） | F-03、F-04、F-05 | ~40 行，含删除 |

确认后我再动手：改代码 → `deploy.sh` + `compile.sh` 四终端编译 →
全套回归测试 → 更新 HANDOFF → 推送 GitHub。
