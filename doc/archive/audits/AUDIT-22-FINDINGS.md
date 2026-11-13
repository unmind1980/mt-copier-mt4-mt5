# MT-Copier 全栈代码审查报告（第二十二次审计 · 只读排查，未改动任何代码）

- **审查日期**：2026-10-23
- **代码基线**：`master` @ `e6afcfa`（工作区干净）
- **审查范围**：`src/Experts/*.mq4`、`src/Include/Copier/*.mqh`、`src/Scripts/*.mq4`、`hub/src/*.rs`、`hub/src/assets/dashboard.html`、`tools/*.py|*.sh`
- **代码规模**：约 41,000 行
- **状态**：**本报告仅为排查结论，未修改任何源码**。所有条目均给出 `文件:行号` 与可复现的触发路径。

---

## 0. 结论摘要

共确认 **11 项逻辑缺陷/隐患** + **11 项性能与可扩展性问题** + **3 项测试套件缺口**。

其中最需要优先处理的是：

| 编号 | 问题 | 严重度 | 一句话后果 |
|---|---|---|---|
| **A1** | `ComputeReceiverLots()` 把「发送端手数过滤器」当成「本地目标手数上下限」 | 🔴 严重 | 跟单手数被静默截断，或（fixed 模式）**永远不开仓** |
| **B1** | MQL 字符串 O(n²) 拼接（126 处 `out +=`） | 🟠 高 | 100 源配置每次 CFGREPORT 产生约 1 GB 级 memcpy，EA 主线程卡顿 |
| **B3** | Hub `poke()` 每条 STAT 触发，每个 dashboard 各自全量序列化 | 🟠 高 | 多标签页时 CPU 随「标签页数 × STAT 速率」线性放大 |
| **A3** | `HandleSnapshot()` 每条记录做 O(N) 线性查找 → 快照处理 O(N²) | 🟠 高 | 大账户（500+ 仓）快照解析明显变慢 |
| **A2** | `EncodeReceiverPositions()` 硬编码 128 条上限 | 🟠 高 | Web 控制台持仓明细静默截断，与 `CP_MAX_POSITIONS=2048` 不一致 |

---

## 1. 逻辑缺陷与隐患

### 🔴 A1. `ComputeReceiverLots()` 误用「发送端手数过滤器」作为本地手数上下限

**位置**
- `src/Experts/CopierReceiver.mq4:2988-2990`（错误传参）
- 对照 `src/Experts/CopierReceiver.mq4:4062-4063`（本来已经做过一次正确的过滤）
- 对照 `src/Include/Copier/CopierSizing.mqh:172-173`（`CopierComputeLots` 的语义）

**现状**

```mql4
// ComputeReceiverLots —— 传入的是 SENDER 的手数过滤门限
double lots=CopierComputeLots(senderLots,g_lotMode[si],g_lotParam[si],1.0,si2,
                              g_senderCfg[si].minsenderlotsize,
                              g_senderCfg[si].maxsenderlotsize,rejected);
```

而 `CopierComputeLots` 的这两个参数是**「本地最终手数」的下限/上限**：

```mql4
if(minLots>0.0 && v<minLots) { rejected=true; return 0.0; }   // 直接判定"拒单"
if(maxLots>0.0 && v>maxLots) v=CopierNormalizeLot(maxLots,si); // 静默截断，无日志
```

**为什么是错的**

`minsenderlotsize` / `maxsenderlotsize` 在文档与 UI 中的语义都是「**跳过发送端手数** < / > X 的信号」（`dashboard.html` 的提示文案就是 `Skip sender orders < lots`），并且在 `ConvergeSender()` 第 4062-4063 行已经用 `d.lots`（发送端原始手数）正确过滤过一次：

```mql4
if(g_senderCfg[si].minsenderlotsize>0.0 && d.lots<g_senderCfg[si].minsenderlotsize) continue;
if(g_senderCfg[si].maxsenderlotsize>0.0 && d.lots>g_senderCfg[si].maxsenderlotsize) continue;
```

把它再当作**本地目标手数**的上下限用一次，会产生两种错误：

1. **静默截断（无任何日志）**
   `maxsenderlotsize=0.5`、`lotmode=multiplier`、`lotparam=2.0`、发送端 0.4 手 → 本地目标 0.8 → 被 `maxLots` 截断为 **0.5**。跟单手数比配置意图少 37.5%，日志里一个字都没有。

2. **永远不开仓**
   `minsenderlotsize=0.1`、`lotmode=fixed`、`lotparam=0.05` → 本地目标 0.05 < 0.1 → `rejected=true` → 该信号**永远不会开仓**，日志写的是
   `lot sizing rejected <uid> <sym> senderLots=...`
   —— 这句话把原因指向"手数计算"，而真实原因是把一个**过滤器**当成了**下限**。

**补充**：`QueueTrimIfNeeded()`（3013）也走 `ComputeReceiverLots()`，所以 fixed 模式下的部分平仓比例计算同样被这个错误上限影响。

**建议**
- 把第 2989-2990 行恢复为 `0.0, 0.0`（发送端过滤已在 4062-4063 完成）；
- 若确实需要"本地手数上下限"，应该使用**独立的** `minlotsperposition` / `maxlotsperposition`（后者已存在，见 2992 行），而不是复用 sender 过滤字段；
- 顺手让 `CopierComputeLots` 的 `maxLots` 截断路径打一条（限频）日志，避免"静默改手数"这一类问题再次隐身。

---

### 🟠 A2. `EncodeReceiverPositions()` 硬编码 128 条上限，Web 持仓明细被静默截断

**位置**：`src/Experts/CopierReceiver.mq4:3649-3692`（`if(count>=128) break;` 在第 3689 行）
**同一问题**：`EncodeReceiverWaitList()` 第 3710、3714 行同样有 128 上限

**现象**
`CP_MAX_POSITIONS` 已经是 2048，快照、收敛、风控都按 2048 工作，但**上报给 Hub 的持仓/等待明细只发前 128 条**。

**影响**
- Web 控制台「Split Cockpit → 持仓明细」在持仓 >128 笔时只显示 128 行，而同一页面的 `HELD=` 计数显示真实数量（例如 300）。操作员看到「300 持仓」但表格只有 128 行，且**没有任何提示**说明被截断。
- 这正是本项目反复避免的「静默不一致」类问题：两个数字都对，但它们说的不是一件事。
- 每 60 秒一次，单条消息最大约 `128 × 90B ≈ 11 KB`，即便提到 512 条也只有 ~46 KB，压缩后更小，容量不是真正的约束。

**建议**
- 把上限提升到 `CP_MAX_POSITIONS`，或至少 512，并在 `STAT` 里附一个 `POSN=` 声明总数，让前端能显示「显示 128 / 共 300」；
- 或者改为按页上报（`POSPAGE=n`），由前端按需请求。

---

### 🟠 A3. `HandleSnapshot()` 每条记录做 O(N) 线性查找 → 快照处理 O(N²)

**位置**
- `src/Experts/CopierReceiver.mq4:4589-4595`（每条记录调用 `GetOrUpdateSenderPeakLots`）
- `src/Experts/CopierReceiver.mq4:789-811`（该函数是线性扫描）
- `src/Experts/CopierReceiver.mq4:761-787`（`PruneSenderPeakLots` 更重：`O(N × senders × desired)`）

**现象**

```mql4
for(int i=0;i<n;i++)
  {
   g_desired[base+i]=g_scratch[i];
   GetOrUpdateSenderPeakLots(g_scratch[i].uid,g_scratch[i].lots);  // ← O(g_uidPeakLotsCount)
  }
```

`GetOrUpdateSenderPeakLots` 内部是对 `g_uidPeakLots[0..count)` 的**字符串逐条比较**。

**量级**
- 500 笔持仓：500 × 500 / 2 ≈ **12.5 万次**字符串比较 / 快照
- 2048 笔持仓：≈ **210 万次**字符串比较 / 快照
- 表满触发 `PruneSenderPeakLots()` 时：`2048 × 1 sender × 2048 desired` ≈ **420 万次**

**建议**
复用本项目已有的做法（`CopierUidIndex` / `CopierBackoff` 的开放寻址 + FNV），给 `g_uidPeakLots` 建一个 uid → slot 的哈希索引；或直接用 `CopierUidIndex` 的思路重建一次再批量写回。

---

### 🟡 A4. Sender 忽略 `g_prev.InsertEmpty()` 返回值：表满后每个 tick 重复 EmitOpen

**位置**：`src/Experts/CopierSender.mq4:1491-1504`

```mql4
else
  {
   g_prev.InsertEmpty(g_curScratch[i]);   // ← 返回值被丢弃
  }
```

`InsertEmpty()` 在表满时返回 `-1`（`CopierState.mqh:366-386`）。

**后果链**
1. 插入失败 → 该仓位不在 `g_prev` 里；
2. 下一 tick `BuildCurrent()` 的 `FindByTicket` 找不到它 → `slot=-1` → 判定为"新仓" → **再发一次 `EmitOpen`**；
3. 同时 `CopierNewUid()`（第 637 行）会为它**生成一个全新的 UID**；
4. 接收端看到的是"新 UID 的新仓"，在风控与 `g_seen` 抑制之前会尝试重复开仓；
5. 直到表腾出空位为止，**每个 tick 重复一次**。

**触发条件**
`sender` 账户持仓数 > `CP_MAX_POSITIONS`（2048）。概率低，但一旦触发就是持续重复下单尝试，属于"安静但昂贵"的故障。

**建议**
- 检查返回值，失败时限频报错（`g_once.ShouldEmit("prevfull")`）并**跳过本轮快照/事件生成**，而不是让状态机在"未知"状态下继续；
- 或者与 A5 一起处理：UID 只在确认插入成功后才分配。

---

### 🟡 A5. `BuildCurrent()` 先分配 UID、后确认插入，失败即丢失 UID

**位置**：`src/Experts/CopierSender.mq4:634-645`

```mql4
if(StringLen(uid)==0)
  {
   uid=CopierNewUid();   // 分配
   slot=-1;
  }
...
if(n>=CP_MAX_POSITIONS) break;
g_curScratch[n]=p;       // 真正"提交"在这里（以及后续 InsertEmpty）
```

与 A4 同源：`CopierNewUid()` 的结果只有在 `InsertEmpty()` 成功后才会被记住。任何在两者之间失败的路径（表满、`break`）都会让下一 tick 换一个新 UID，使接收端把同一笔仓位看成两笔。

**建议**：把 UID 的持久化时机后移到 `InsertEmpty` 成功之后；或在 `g_curScratch` 里保留"待确认 UID"并在下一 tick 复用。

---

### 🟡 A6. Hub `risk.blocked` 告警静默窗口被 `rearm()` 反复击穿

**位置**
- `hub/src/alerts.rs:348-367`（`risk.blocked` 的 state-aware 逻辑）
- `hub/src/alerts.rs:164-166`（`rearm()` 直接 `fired.remove()`）
- `hub/src/alerts.rs:70`（`silence::RISK = 300`）
- 接收端 `src/Experts/CopierReceiver.mq4:6692`（`if(dueStatus) g_riskBlocked=0;`）

**机制**
1. 接收端每 60 秒的完整 STAT 里带 `BLOCKED=N`，**发完立刻把 `g_riskBlocked` 归零**；
2. Hub 端 `note_stat()` 只在 `RISK` 非空时更新 `e.blocked`（`registry.rs:416-419`），所以下一分钟收到的是 `BLOCKED=0`；
3. `alerts.rs:364-367` 看到 `n.blocked==0 && prev_blocked>0` → `last_risk_blocked.remove()` + **`rearm("risk.blocked")`**；
4. 再下一分钟 `BLOCKED=M>0` → `n.blocked > prev_blocked(0)` → **再次告警**。

**后果**
只要风控持续拦截，告警就以**约 1～2 分钟一次**的节奏无限重复，而 `silence::RISK=300` 设计意图是 5 分钟一次。每一条都会经 `notif_tx` 派发到 Telegram / 企业微信 / 钉钉 / Webhook。

**建议**
`rearm()` 只应响应"真正恢复"，而不是"计数器被清零"。可以：
- 让接收端**不要**在发完 STAT 后清零，而是改成"自上次报告以来的增量"（这样 0 只代表"本分钟没有新拦截"）；
- 或者在 `alerts.rs` 里把 `n.blocked==0` 的 rearm 加上"且上一轮 `risk` 已回到 ok"的条件，或给 rearm 加一个最小间隔（如 `silence::RISK`）。

---

### 🟡 A7. `HandleCfg()` 仍用 32 位 `StringToInteger` 解析 `REV=`

**位置**：`src/Experts/CopierReceiver.mq4:4770`

```mql4
long rev=(long)StringToInteger(revs);
```

全库其它位置（`CopierKvGetLong`、快照 `ticket/magic/openTime`、`seq/ts/ms`、`CopierResolveMagic`、`CopierReadIniRevision`）都已经换成 64 位 `CopierParseLong`，唯独这里漏了。

**影响**：`REV` 超过 21.4 亿时在 MQL4 上溢出为负数，随后 `g_cfgRev` 与 `CopierCfgRevSave()` 都会写入错误值，Hub 端看到节点 `REV` 倒退，会反复判定"落后"并重推配置。现实中 REV 很小，但这是**同一个坑的最后一处遗漏**，属于一致性缺陷。

**建议**：改为 `long rev=CopierParseLong(revs);`（`HandleCmd` 里若有类似解析一并检查）。

---

### 🟡 A8. 日志限频结构的两处热点

**位置**
- `src/Include/Copier/CopierLog.mqh:188`（1 秒内相同消息合并只用 `m_lastLevel/m_lastMsg` **单槽**）
- `src/Include/Copier/CopierLog.mqh:284-313`（`CopierOnceLog::ShouldEmit` 是 **64 槽线性扫描**）

**现象**
`ShouldEmit()` 在 `ConvergeSender()` 的每仓位路径上被调用多次（`noreopen|`、`gateexist|`、`stopcalc|`、`slclamp|`、`fillgrace|` 等），每个 key 都是**现场拼接的字符串**（如 `g_sid[si]+":fillgrace:"+d.uid`）。

**量级**：300 仓 × 10 Hz × 若干 key × 64 槽比较 ≈ **每秒百万级字符串比较 + 数千次临时字符串分配**。

**建议**
- 给 `CopierOnceLog` 加一层 FNV 哈希索引（与 `CopierBackoff` 完全同构，本仓库已有现成范式）；
- 热点路径上的 key 改成**预分配 + 复用的全局 buffer**，避免每 tick 新建字符串；
- `CopierLog::Write` 的单槽合并对"两种消息交替出现"（A、B、A、B…）完全无效，建议改成 4～8 槽的小环。

---

### 🟢 A9. `CopierIni::Load()` 中的空操作死代码

**位置**：`src/Include/Copier/CopierConfig.mqh:126`

```mql4
string first=StringSubstr(line,0,1);
if(first==";" || first=="#" || first=="[") {}   // ← 什么也不做
if(first=="[" ) { ... }
```

**影响**：无功能影响，但会误导读者以为这里做了分类处理。属于清理项。

---

### 🟢 A10. `CopierBackoff::InsertHash()` 的探测循环没有次数上限

**位置**：`src/Include/Copier/CopierState.mqh:829-833`

```mql4
while(m_slot[k]!=0)
  {
   if(m_h[k]==tag && m_slot[k]==i+1) return;
   k=(k+1)&mask;                 // 无 probes 计数
  }
```

目前靠"`FreeSlot()` 淘汰后一定有空桶"这个不变量保证终止。一旦将来新增一条删除路径忘记 `EraseHash()`（本文件历史上就出过"哈希桶与数据槽位错位"的 bug），这里会变成**死循环并卡死 EA**，而不是像 `Find()` 那样安全返回 -1。

**建议**：加 `for(int probes=0;probes<CP_BACKOFF_SLOTS;probes++)` 上限，超限时 `EraseHash()` 重建并重试一次。

---

### 🟢 A11. `positions.rs::parse_snap()` 的死代码

**位置**：`hub/src/positions.rs:273` 与 `326`

```rust
let mut order: Vec<String> = Vec::new();
...
order.push(sym.clone());   // 收集后从未被读取
```

**影响**：每条记录多一次 `String` 克隆与一次 `Vec` 增长；同时是一处"看起来在维护顺序、其实没有"的误导。删除即可（`symbols` 本身已按 first-seen 顺序 push）。

---

## 2. 性能与可扩展性

### 🟠 B1. MQL 字符串 O(n²) 拼接（本项目最大的单点性能问题）

MQL 的 `string +=` 没有容量倍增，每次都在堆上重新分配并整体拷贝。以下四处都是"循环内 `+=`"：

| 位置 | 规模 | 每次成本估算 |
|---|---|---|
| `CopierReceiver.mq4:1276-1360` `SerializeCurrentConfigToIni()`，**126 处 `out +=`** | 100 源 ≈ 270 KB | 约 `7400 行 × 平均 135 KB` ≈ **1 GB 级 memcpy** |
| `CopierConfig.mqh:374-392` `CopierIniEscape()`，**逐字符** `out +=` | 270 KB | 约 `270k × 135k` ≈ **36 GB 级字节拷贝**（未计 UTF-16 双字节） |
| `CopierConfig.mqh:499-515` `CopierIniReadAll()`，逐行 `out +=` | 270 KB / 7400 行 | 约 1 GB 级 |
| `CopierCodec.mqh:438-455` `CopierEncodeSnapshot()`，逐记录 `recs +=` | 2048 条 ≈ 380 KB | 约 `2048 × 190 KB` ≈ 390 MB |

**触发时机**：`SendCurrentConfigReport()`（REG 之后、每次 CFG 应用、每次 `reqcfg`）都会跑一遍 `Serialize + Escape`；`CopierIniReadAll` 在每次 `CopierIniWriteAtomic` 都会跑。100 源部署下这是一次**秒级的主线程阻塞**——而主线程同时负责 ZMQ 收包与下单。

**建议**（按性价比排序）
1. 先把行收集进 `string lines[]`，最后一次 `StringJoin(lines, "")`；
2. `CopierIniEscape` 改为 `StringSetLength(out, n*3)` + `StringSetCharacter()` 单趟写入（或按"整段无特殊字符就整段 append"分块处理，实践中 99% 的配置行不含需转义字符）；
3. `CopierEncodeSnapshot` 同样用 `string recs[]` + `StringJoin`。

> 注：本仓库目前**完全没有使用** `StringJoin` / `StringSetLength`（已 grep 确认），所以这是一整类尚未处理的开销。

---

### 🟠 B2. 快照解码每条记录 `StringSplit` 出 15 个字符串

**位置**
- `src/Include/Copier/CopierCodec.mqh:469-497`（`CopierDecodeSnapshot`：`StringSplit` 出 N 条记录）
- `src/Include/Copier/CopierCodec.mqh:152-194`（`CopierDecodeRec`：再 `StringSplit` 出 15 个字段）

**量级**：2048 条记录 = **2048 + 30,720 = 约 3.3 万次字符串对象分配 / 快照**，全部是临时对象，给 MQL 的堆管理造成明显压力（GC 与碎片）。

**建议**：改为手写单趟扫描（与 Rust 端 `rec_field()` 同风格）：定位逗号偏移后直接 `StringToDouble(StringSubstr(...))`，或者更彻底——按偏移解析而不生成中间子串（`StringToDouble` 必须吃字符串，所以至少省掉 `StringSplit` 的数组分配）。

---

### 🟠 B3. Hub `poke()` 每条 STAT 触发；每个 dashboard 各自做一次全量序列化

**位置**
- `hub/src/main.rs:2096`（STAT 分支里的 `poke()`）
- `hub/src/api.rs:823-837`（`snapshot_text()`：持 `shared` 锁 + 序列化**所有节点 + 所有持仓 + 告警 + curve**）
- `hub/src/api.rs:785-818`（每个 WS 连接独立 `select!` 循环，收到 `()` 就自己 `snapshot_text()`）

**量级**：默认 `SyncHeartbeatSeconds=1`，接收端**每个被镜像的 sender 每秒发一条 STAT**。2 接收端 × 2 发送端 = 4 poke/s；若打开 10 个浏览器标签，就是 **40 次/秒全量 JSON 序列化**，且每次都抢 `shared` 互斥锁。100 节点、数千持仓时，单次序列化就是几十毫秒——标签页越多，Hub 的 ZMQ 转发线程被拖得越慢。

**建议**
1. **序列化一次，广播字符串**：把 `snapshot_text()` 的结果放进 `tokio::sync::broadcast::Sender<String>`，各 WS 连接只 `send()`，不再自己锁+序列化；
2. 给 `poke()` 加 250–500 ms 合并（coalescing）：`if last_poke.elapsed() < 250ms { pending = true }`，节拍器统一发；
3. 持仓明细（`positions`）与节点列表分离成两条消息，前端按需订阅——大账户下 `positions` 是体积主体。

---

### 🟡 B4. `ConfigStore::history()` 每次请求全量读盘 + 返回所有 revision 的完整 INI

**位置**：`hub/src/config.rs:309-340`

```rust
let text = std::fs::read_to_string(&self.path)?;   // 整个 jsonl
for line in text.lines() { serde_json::from_str::<Value>(line) ... }
```

**两个问题**
1. **每次请求 O(文件大小)**：50 个 revision × 270 KB INI ≈ 13.5 MB 读盘 + 13.5 MB JSON 解析，且**在 async 运行时里同步阻塞**；
2. **响应体同样巨大**：`brief` 只补了 `ini_bytes`，但**没有移除 `ini`**（第 324-333 行），所以每个 revision 的完整 INI 都会进入 HTTP 响应。50 条历史 = 约 13 MB 响应，浏览器解析会明显卡顿。

**建议**
- 列表接口只返回元数据（`rev/ts/actor/kind/ini_bytes`），单条正文走 `GET /config/revision/{rev}` 按需取（`revision_body()` 已有现成实现）；
- 把 `current` 状态在内存里缓存（启动时 `load()` 已经做了一次），避免每次读盘。

---

### 🟡 B5. `CommandStore` 无淘汰：内存与 `commands.jsonl` 无限增长

**位置**：`hub/src/commands.rs:153-167`（`commands: HashMap<String, Command>`）、`549-600`（`load()` 全量读盘重建）

**现象**
- 每条命令从 `pending → sent → acked/rejected`，每次状态变化都 `append()` 一行 JSON；
- 重试阶梯最多 8 级，**每次重试也写一行**；
- 命令**永不删除**，启动时全量读回内存。

**量级**：`reqcfg` 自愈在哈希不匹配时会每 60 秒发一条（`main.rs:1553`），单节点一年 ≈ 52 万条命令。`commands.jsonl` 会到几百 MB，启动解析要数十秒，`stats()`（`commands.rs:233-241`）的 `values().filter()` 也变成 O(全部历史)。

**建议**
- 加保留策略：终态（acked/rejected/unknown）且超过 N 天/超过 M 条的记录，在启动时丢弃或按节点只保留最近 K 条；
- `commands.jsonl` 做定期压缩（重写成"每条命令只剩最后状态"的快照文件）；
- `stats()` 改用 `in_flight.len()` + 计数器，避免每次 O(N) 遍历。

---

### 🟡 B6. `due_gated()` 在持锁状态下逐条 `fsync`

**位置**：`hub/src/commands.rs:465-467`（循环里 `inner.append(c)`）、`530`（`f.sync_data()`）

```rust
for c in &changed { inner.append(c); }   // 每条 append 内部都 sync_data()
```

**影响**：一次有 10 条命令到期，就是 **10 次 fsync 串行**，全部发生在**主循环线程**（也就是转发 SNAP/OPEN/CLOSE 的那条线程）上，并且全程持有命令锁。机械盘/网络盘上单次 fsync 可达 5–20 ms，10 条就是 50–200 ms 的转发延迟——而这段时间里交易的 OPEN/CLOSE 事件是在排队的。

**建议**
- 把 journal 写入改成"收集 → 释放锁 → 批量写 → 一次 fsync"；
- 或把 journal 交给一个后台线程（`audit` 已经是这么做的，可以直接复用那套模式）。

---

### 🟡 B7. `CopierPosTable::CopyFrom()` 是 O(N²)

**位置**：`src/Include/Copier/CopierState.mqh:272-280`（`Clear()` + 逐行 `Upsert()`）、`285-308`（`Upsert` 内部 `Find()` 是 2048 槽线性扫描）
**调用点**：`src/Experts/CopierReceiver.mq4:1986-1989`（`SaveReceiverMap()`，每 10 秒一次）

**量级**
- 300 仓：`300 × (2048 Find + 2048 空槽扫描)` ≈ **123 万次比较 / 10 秒**
- 2048 仓：≈ **840 万次 / 10 秒**
- 启动恢复（`OnInit` 里逐条 `Upsert`）：同样 O(N²)，2048 条就是 840 万次，直接体现为启动延迟

**建议**
`CopyFrom` 可以直接整表拷贝（两个表同为 `CopierPosTable`、同容量），或改成"一次 `Find` 建索引 + 一次线性写回"。`Upsert` 也应使用 `m_hint`（它已经存在，只是 `Upsert` 没用）。

---

### 🟡 B8. `QueueModifyIfNeeded()` 每仓位每 tick 重算止损几何

**位置**：`src/Experts/CopierReceiver.mq4:3108-3230`

**每次调用的固定成本**：`CopierGetSymbolInfo()` + `StopsOvIndex()`（线性，最多 512 槽）+ 2 次 `CopierMapInvertedStops` + 4 次 `CopierMirrorStop` + 2 次 `CopierFitStop`（内含取价）。

**量级**：300 仓 × 10 Hz = **3000 次/秒**，而其中 99.9% 的结论是"没变"（第 3208 行才 return）。

**建议**
加一个"输入签名"短路：把 `(desired.sl, desired.tp, desired.openPx, local.sl, local.tp, local.pprice, local.pstop, local.pexpire, mirrorstops, inverttrades)` 压成一个小的数值指纹，与上次相同就直接返回。缓存可放在 `g_posCache` 旁边（按 ticket 索引），失效条件明确、无正确性风险。

`QueueTrimIfNeeded()`（2999）同理。

---

### 🟡 B9. `RefreshRisk()` 的 magic → sender 查找是 O(仓位 × sender)

**位置**：`src/Experts/CopierReceiver.mq4:3736-3756`

```mql4
for(int i=0;i<an;i++) {
  for(int k=0;k<g_nSenders;k++) if(g_acctAllPos[i].magic==g_magic[k]) { ours=true; break; }
  ...
}
```

100 仓位 × 100 sender = **10,000 次比较 / tick（10 Hz）**。同样的嵌套循环还出现在 `EncodeReceiverPositions`（3656-3660）与 `ScanAndResolveAccountPositions`（3577-3580）。

**建议**：建一次 `magic → senderIdx` 的开放寻址哈希（`long` 键，本仓库已有 `TicketHash` 范式），配置加载时重建，三处共用。

---

### 🟢 B10. `ArrayResize(g_desired, g_nSenders*CP_MAX_POSITIONS)` 的规模

**位置**：`src/Experts/CopierReceiver.mq4:1474` 与 `1529`

100 sender × 2048 = **204,800 个 `CopierPos`**（含 3 个 `string` + 5 个 `double` + 3 个 `long` + 4 个 `int`，约 150 B）= **约 30 MB**，且每次 CFG 推送都 `ArrayResize`（realloc + 整体拷贝）。

**建议**：按"实际配置的 sender 数"分配没错，但可以在数量未变时跳过 resize；或把 `g_desired` 拆成 `CopierPos g_desiredBySender[CP_MAX_SENDERS][]` 的锯齿数组，让单个 sender 的数组独立增长（MQL4 对动态数组数组支持有限，需实测）。

---

### 🟢 B11. `CopierPeerTable` / `UpdatePanel` 的 100 槽循环

`CheckPeers()`（`CopierReceiver.mq4:5994`、`CopierSender.mq4` 同构）与 `UpdatePanel()`（6181）每 1.5 s / 每 tick 遍历全部 100 槽并调用 `NameAt()`（返回 `string` 拷贝）。量级不大（100 × 10 Hz），但 `NameAt()` 的返回值拷贝可以改成 `const string &` 或增加一个 `bool NameAt(i, string &out)` 版本。

---

## 3. 测试套件缺口

### 🟡 C1. `tools/tests.sh` 未运行 `dash_check.py`

**位置**：`tools/tests.sh:67-85`（`PY_TESTS` 列表）

`dash_check.py` 是**唯一**能发现 `dashboard.html` 中 JS 语法错误（会让整页白屏）的检查，也是本项目历史上真实救过场的工具（未转义引号导致 `renderNodes` 解析失败）。但它**不在测试套件里**，只能靠人记得手动跑。

**建议**：把 `dash_check.py` 加入 `PY_TESTS`（它不依赖 pyzmq，可以直接用系统 python 跑）。

### 🟢 C2. 三个 ZMQ 集成测试未纳入

`zmq_bidir_test.py`、`zmq_fanout_test.py`、`zmq_conflate_size_test.py` 不在 `tests.sh` 里（`zmq_topic_test.py` 在）。如果是有意排除（需要独立 hub 实例），建议在 `tests.sh` 里加一行注释说明，避免下次审查再次误判为遗漏。

### 🟢 C3. 缺少针对本报告 A1/A2/A3 的回归断言

- `ComputeReceiverLots` 的手数语义（sender 过滤 ≠ 本地上下限）——可用纯函数测试覆盖 `CopierComputeLots`，但**调用方传参**目前无测试；
- `EncodeReceiverPositions` 的 128 上限——构造 200 条记录断言条数；
- `PruneSenderPeakLots` / `GetOrUpdateSenderPeakLots` 的表满与回收——`CopierSelfTest.mq4` 里可加。

---

## 4. 已核查、确认无问题的点（避免重复排查）

以下是本次重点核对后**确认当前实现正确**的部分，供后续审计跳过：

| 检查项 | 结论 |
|---|---|
| `CopierBackoff` 哈希桶 ↔ 数据槽位映射 | 已修复正确（`m_slot[k]=i+1` + `Find()` 取 `idx`） |
| `CopierCfgHash` 全量 UTF-8 字节 | 正确（`count=-1` + 去尾部 `\0`） |
| `CopierCompressField` 的 `1:<pad>:<z85>` 与 Rust 侧 PKZIP 解析 | 两侧一致，`pad` 剥离与 `PK\x03\x04` 头处理都对 |
| `CopierTransport::DrainFrames` 多帧排空 | 已改为动态 `hasMore`，不会吞后续消息 |
| `CopierNowMs()` MT4 49.7 天回绕 | 已有单调拼接保护 |
| `ExecuteQueue()` 出队风控重检 | 待入队传 0、per-sender 用 `sAddedCount/sAddedLots` 累加，正确 |
| `AcceptSeq()` 的 SSID 变更重置 | `g_ready=false` + `g_desiredCount=0` + watermark 重置，正确 |
| `HandleSnapshot()` 的 `N=` 与解码数不符拒绝 | 正确（含 `CP_MAX_POSITIONS` 上限归一） |
| `LoadConfigForHub()` 的 per-sender 状态重置 | `g_lastSeq/g_ssidSeen/g_ready/g_desiredCount/g_snapHash` 全部清零，正确 |
| `HandleCfg()` 的备份→写入→回读校验→失败回滚 | 顺序正确，`ClearQueue()` 也在 |
| `CopierRisk::Configure()` 的 latch 重算 | 正确（限值变更清 latch，peak 保留） |
| `CopierTradingTimes::Allows()` 跨午夜 | 已区分 blanket / per-day，并尊重显式闭市日 |
| `positions.rs` 的 `side` 解析（`i8`） | 与 MQL `CP_SIDE_BUY=1/SELL=-1` 一致 |
| `envelope.rs::decompress_field` 的 4 MB 上限与 latin1 兜底 | 正确 |
| `api.rs` `nodes_json_list` 的排序与 `view_for` O(1) | 正确 |
| `dashboard.html` 的 `renderAlerts` / `renderNodes` / `renderCockpit` 原位更新 | 均有签名守卫，稳态不重建 DOM |

---

## 5. 建议的修复批次

| 批次 | 内容 | 理由 |
|---|---|---|
| **第 1 批（交易正确性，优先）** | A1、A2、A4+A5 | A1 会静默改变跟单手数或彻底不开仓；A2 让操作员看到不完整持仓；A4/A5 会在极端情况下重复下单 |
| **第 2 批（主线程性能）** | B1、B2、B3、B6 | 全部是"卡住 EA/Hub 主线程"的问题，100 源部署下最先暴露 |
| **第 3 批（长期稳定性）** | A3、A6、B5、B7、B8、B9 | 内存/告警/CPU 随运行时间或规模劣化 |
| **第 4 批（一致性与清理）** | A7、A8、A9、A10、A11、B4、B10、B11、C1～C3 | 一致性、可维护性、测试覆盖 |

---

## 6. 附：复现与验证建议

- **A1**：把 `copier.ini` 设为 `lotmode=fixed` / `lotparam=0.05` / `minsenderlotsize=0.1`，发送端开 0.2 手 → 观察接收端日志 `lot sizing rejected` 且永不建仓；再把 `maxsenderlotsize=0.5`、`lotmode=multiplier`、`lotparam=2.0`、发送端 0.4 手 → 本地只开 0.5 手且无任何提示。
- **A2**：在测试账户开 200 笔带 copier 注释的持仓，观察 `/api/v1/nodes/{id}` 的 `positions.items` 长度恒为 128。
- **B3**：开 5 个 dashboard 标签 + 4 条 STAT/s，用 `--stats-every 5` 观察 Hub 主循环的转发延迟，或直接用 `perf`/`top` 看 CPU 随标签页数增长。
- **A6**：把 `MaxOpenPositions` 设为 1 并让发送端持续开仓，观察 `audit.jsonl` 里 `risk.blocked` 的间隔是否稳定在 60–120 秒而不是 300 秒。

---

*报告结束。所有结论基于静态代码阅读与调用链推演，未运行实盘。*
