# mt-copier 全栈只读审计报告（2026-11-06 · 第三轮 / 独立通读）

> **审计对象**：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
> **代码基线**：`HEAD = c81a07c`（2026-11-06 11:41），**工作区另有 14 个未提交改动**（含 `hub/src/main.rs`、`hub/src/service.rs`、`CopierReceiver.mq4`、`CopierConfig.mqh`、`CopierDefs.mqh`、`CopierSelfTest.mq4`、`doc/PROTOCOL.md`、5 个 service bat）。本报告审的是**当前工作区实际代码**，即包含这批尚未提交的"第 109 轮"修复。
> **审计方式**：单进程整文件顺序通读，未派发子代理，跨模块不变量一次对齐。
> **约束**：**只读，未修改任何源码 / 配置**；本报告是唯一新增文件。
> **重点**：本轮不重复列历史已闭环项，主查「最新一批未提交修复是否引入回归」+「历轮报告未覆盖的新问题」。

---

## 0. 本轮基线的一个关键事实

`git status` 显示 14 个文件处于未提交状态，其内容正是 11-06 日志里"未修、需用户确认"的几项落地：

| 改动 | 内容 |
|---|---|
| `main.rs` +292/-99 | 批量收据 `RH=<sid>:<h>,...` 的 Hub 侧拆分与 `relay_one_receipt` 重构；F-02 收紧为"topic 必须是数字 NID"；4 条新单测 |
| `CopierReceiver.mq4` +68/-27 | `OnTimer` 把每 sender 一条 STAT 改成按 `CP_STAT_RH_CHUNK` 分块的批量 STAT |
| `CopierDefs.mqh` +15 | 新增 `CP_STAT_RH_CHUNK 1200` |
| `CopierConfig.mqh` +63/-1 | B3：ini 写盘后读回比对，ANSI 代码页损坏时打 WARN；新增 `CopierIniCmpNormalize` |
| `CopierSelfTest.mq4` +16 | B3 的 5 条断言 |
| `service.rs` / 5 个 bat / `main.rs` | H4：`--instance NAME` 服务名后缀、日志路径解析、stdio 句柄不再 `mem::forget` |
| `doc/PROTOCOL.md` +87 | 明写"allow-list 是信任边界而非隔离机制"（A1 的文档缓解）、ini 三层往返语义 |

也就是说，这份报告实质上是**对这批新代码的第一次独立复核**。以下 F-01 ~ F-05 全部落在这批改动里。

> **审计期间工作区仍在变动**：通读过程中 `tools/hub_stat_path_test.py` 又新增了 61 行（批量 `RH=` 与 F-02 收紧的黑盒用例），说明这批修复尚未收尾。本报告以最后一次核对时的文件内容为准；所有 `文件:行号` 均按该时点给出。

---

## 1. 结论摘要

| 编号 | 端 | 等级 | 一句话 |
|---|---|:---:|---|
| **F-01** | MQL Config | **高（性能回归）** | 新增的 `CopierIniCmpNormalize` 用 `out += ShortToString(c)` 逐字符拼接，每次 CFG 推送对 100-sender ini 产生数十 GB 级内存复制，直接违背同一文件里 `CopierStrBuilder` 的设计原则 |
| **F-02** | 部署脚本 | **中高** | `service_install.bat` / `service_uninstall.bat` 在 `if (...)` 复合块内 `set` 后用 `%VAR%` 引用，cmd 会展开成进入块前的空值 → `--instance` 永远传不进去，H4 多实例功能在脚本路径上完全失效 |
| **F-03** | 协议 / 兼容 | **中高** | `CP_STAT_RH_CHUNK=1200` 配 `CP_MAX_SENDERS=100`（新注释误写 32），100 senders 必然分成 2 帧；第 2 帧没有 `SID=`/`H=`，老版本 Hub 只收到第 1 帧的一条收据，其余 sender 收据静默丢失 |
| **F-04** | Rust Hub | 中 | 批量化只降了帧数没降锁次数：`relay_one_receipt` 每个 pair 取 2 次全局 `shared` 锁，100 senders 仍是 200 次锁/秒/receiver，且集中在一帧内 |
| **F-05** | MQL Risk | 中 | V2 零净值恢复路径只挂在 `m_zeroLatched`（仅 `maxDrawdownPct>0` 才置位）；只配 `dailyLossPct` 时，连续 2 次瞬态 0 净值把日内熔断闩锁一整天 |
| **F-06** | 跨端 | 中低 | 节点 `CopierIniValidate` 与 Hub `validate_ini` 规则仍不对齐（首节前 key、空节名、节数/行数上限、空白 key），是 HUB-03 那类"死循环推配置"的残余面 |
| **F-07** | MQL Config | 低中 | B3 只加了 WARN，损坏文本照样落盘 / 下次启动照样回传 Hub；且这个"只警告"的代价是每次推送一次全量读盘 + 两次 O(n²) 归一化 |
| **F-08** | Rust Hub | 低 | `RH=` 的 hash 字段无格式校验，可把 `;` / `|` 注入 `RCPT` 的 `P=`；`parse_rh_pairs` 的 4096 上限与 100 senders 的实际规模也严重不匹配 |
| **F-09** | 文档 | 低 | `CP_MAX_SENDERS` 在新注释里写成 32，实际是 100；`PROTOCOL.md` 新增段落对 F-02 的描述与代码也有措辞偏差 |
| **F-10** | Rust HA | 中 | B1 用"hash 非空"近似"功能已启用"，全新 Standby 的通知/CURVE 文件不存在时永远不发起同步 |
| **F-11** | Rust HA | **中高** | 文件同步失败（`sync_err`）时 epoch 仍被采纳并落盘，与 HUB-02 注释承诺相反 |
| **F-12 ~ F-14** | Hub / 跨端 | 中低 | 用户表强同步默认关闭、压缩字段失败时两端语义不一致、Standby 连只读 `reqpos` 也 409 |
| **F-15 ~ F-21** | 多端 | 低 / 优化 | hash 缓存键、通知连接池、尾帧残局、统计口径、冷启动反射面等，详见第 4 节 |

---

## 2. 高危 / 中高危发现详解

### F-01【高 · 性能回归】`CopierIniCmpNormalize` 是 O(n²) 的逐字符字符串拼接

**位置**：`src/Include/Copier/CopierConfig.mqh:764-783`，调用点 `CopierIniWriteAtomic():823-846`

```mql4
string CopierIniCmpNormalize(const string s)
  {
   int n=StringLen(s);
   string out="";
   for(int i=0;i<n;i++)
     {
      ushort c=StringGetCharacter(s,i);
      if(c=='\r') continue;
      out+=ShortToString(c);          // ← 每次追加都重新分配并复制整个 out
     }
   ...
  }
```

**为什么这是回归，而不是"可以再优化一下"**

同一个文件里，`CopierIniEscape`(516)、`CopierIniUnescape`(547)、`CopierIniReadAll`(660) 和 `CopierDefs.mqh:819-921` 的 `CopierStrBuilder` 都专门为了躲开这个模式而重写过，注释写得非常直白：

> `CopierDefs.mqh:824-831` — "MQL strings have no capacity doubling: `s += x` allocates a NEW string and copies the WHOLE of `s` every time ... the INI escaper (one append PER CHARACTER, **~36 GB of copying at 270 KB**)"

B3 新增的比较器恰好把作者自己禁止的写法重新引入了，而且**一次推送调用两次**（`want` 与 `got` 各一次）：

- 满配 100-sender 的 ini 约 270 KB（文件第 55 行、Hub `validate_ini` 注释第 931 行都给了这个数）；
- 单次归一化 ≈ 270,000 次追加 × 平均 135 KB 复制 ≈ **36 GB memcpy**；
- 两次 = **约 72 GB**，外加 `CopierIniReadAll` 的一次全量读盘；
- 这段代码跑在 `CopierIniWriteAtomic` 里，也就是 **每次 `CFG` 推送的 EA 主线程**上 —— 同一个线程还要收快照、发订单、跑 `OnTimer`。

这不只是"慢"：MQL 的 EA 主线程被卡住数秒会让心跳、快照收据和订单队列一起超时，表现为"推配置那一刻节点短暂掉线 / 漏单"。而绝大多数部署的 ini 只有几 KB，日常测试（包括新增的 5 条 SelfTest 断言）用的都是几十字节的短字符串，**这个代价只会在满配生产环境暴露**。

**建议**

1. 用现成的 `CopierStrBuilder` 做归一化（`sb.Add(ShortToString(c))`，或按 128 字符 run 批量 Add），把复杂度压到 O(n log n)；
2. 更省的做法：**先直接比较 `want == got`**，只有在不等、需要定位"第一个差异字符"时才做归一化 —— 稳态（纯 ASCII ini，绝大多数部署）一次归一化都不用做；
3. 补一条性能护栏断言：SelfTest 里用 270 KB 文本跑一次，断言耗时在可接受范围（或至少断言 `CopierIniCmpNormalize` 的 chunk 数有上界）。

---

### F-02【中高 · 部署】bat 的 `%MTC_INST_ARG%` 延迟展开陷阱使 `--instance` 永远不生效

**位置**：`tools/service_install.bat:68-75, 102-110, 121-126`；`tools/service_uninstall.bat:39-46, 54-72`

```bat
if "!PEER_IP!"=="" (
    echo [Mode] Standalone Mode ...
    set "MTC_INST_ARG="
    if defined MTC_INSTANCE set "MTC_INST_ARG=--instance %MTC_INSTANCE%"
    "%BIN%" --service-install primary %MTC_INST_ARG% --workdir "%REPO%" ...
) else (
    ...
    "%BIN%" --service-install primary %MTC_INST_ARG% ...
)
```

cmd.exe 在执行 `if (...) else (...)` 这类**复合语句块**前，会一次性把整块里的 `%VAR%` 全部替换成**进入块之前的值**。块内 `set` 的结果对同一块内的 `%MTC_INST_ARG%` 不可见（项目里已经用 `!PEER_IP!` 延迟展开处理过同类问题，但这个新变量用的是 `%...%`）。后果：

- 即使运维正确设置了 `MTC_INSTANCE=edge`，安装命令里 `MTC_INST_ARG` 仍是空 → `--instance` 从未传给 Rust；
- 服务仍注册成历史名 `MTCopierPrimary`，**第二次安装静默重配了第一个服务**，正是 H4 想修的那个故障；
- `service_uninstall.bat` 的 `if exist "%BIN%" (...)` 块同理；
- `:dual` 分支（121-126 行）根本没执行过 `set MTC_INST_ARG`，且 `sc start MTCopierPrimary` / `sc start MTCopierStandby` 仍是硬编码无后缀名 —— 即使 Rust 侧装出了带后缀的服务，脚本也启动不了它；
- `service_start.bat` / `service_stop.bat` / `service_status.bat` 的 `MTC_INST_SUFFIX` 在顶层逐行 `set` + `%...%` 展开，**这三个是对的**，于是形成"能查 `MTCopierPrimary_edge`、却装不出/启不动它"的错位。

**建议**

- 启用 `setlocal EnableDelayedExpansion`，块内一律用 `!MTC_INST_ARG!`；或把 `set` 移到整个 `if...else` 之前（块外）；
- `:dual` 分支的 `sc start` 改用 `%MTC_INST_SUFFIX%` 变量（复用其他三个脚本的写法）；
- 补一个不需要管理员权限的冒烟检查：设 `MTC_INSTANCE` 后 `--service-status primary --instance` 与 `sc query MTCopierPrimary_<name>` 都应命中，当前会失败。

---

### F-03【中高 · 协议兼容】批量 STAT 分块后，第 2 帧不带 `SID=`/`H=`，老 Hub 会静默丢掉一半 sender 的收据

**位置**：`CopierDefs.mqh:234-247`（`CP_STAT_RH_CHUNK 1200`）、`CopierReceiver.mq4:8960-8995`（分块循环）、`hub/src/main.rs:2729-2760`

**推导**

- `CP_MAX_SENDERS = 100`（`CopierDefs.mqh:57`），但新注释第 245 行写的是 "`CP_MAX_SENDERS` is 32"，据此算出"最坏 608 字节，一帧一定装得下"；
- 实际每对是 `<9位sid>:<8位hash>,` ≈ 19 字节，100 对 ≈ **1900 字节 > 1200** → 必然分成 2 帧（ sender 更多或 SID 更长时更多）；
- 分块循环只在 `firstChunk` 追加 `SID=`/`H=` 与 `tail`（HELD/LOTS/POS/EQ/...）。第 2 帧只有 `LOGIN=` + `RH=`；
- 新 Hub 用 `RH=` 拆对，工作正常；**老 Hub 只认 `SID=`/`H=`**，于是每心跳只处理第 1 帧的那一条收据，剩下约 50 个 sender 的收据永久静默丢失 —— 在 sender 看来就是"这个 receiver 一直没确认快照"，触发持续的单播补发；
- 注释声称"older hub receives one receipt instead of none"，但没说明**这是 N 个 sender 里的 1 个**。主备双 Hub 版本不一致、或滚动升级窗口，都会踩到。

**另外**：第 2 帧没有 `EQ/HELD/RISK/PING`，新 Hub 的 `need_stat` 判定为 false（`main.rs:2684`），这是有意的、正确；但 `STAT` 帧数从 N 降到 2 后，**任何依赖"每 sender 一帧"的下游统计口径都变了**，需要在协议文档里写清楚。

**建议**

1. 把 `CP_STAT_RH_CHUNK` 提到能容纳满配的值（`CP_MAX_SENDERS * 24 + 余量`，约 3072），并让注释引用常量而不是硬写 32；
2. 或者保留分块但**每一帧都带 `SID=`/`H=`**（取本块第一个 pair），这样老 Hub 至少每个 chunk 能收到一条；
3. 按历轮约定，`RH=` 属于需要两端同版本的协议扩展，应升 `CP_NODE_VER`（当前 `"2.0"`，`CopierDefs.mqh:337` 未动），并在 `PROTOCOL.md` 明确"混合版本时批量收据不可用 / 需回退到逐 sender STAT"；
4. 补一条 Python 契约测试：构造 100 个 sender 的 `RH=`，断言 Hub 拆出 100 个 pair 且 `RCPT` 目标数正确；现有 4 条 Rust 单测只测了 2 对、畸形串和 9000 对上限，没有满配规模用例。

---

### F-04【中 · 性能】批量化省了帧，没省锁

**位置**：`hub/src/main.rs:965-1035`（`relay_one_receipt`）、`2743-2759`（每 pair 调用）

重构把每 sender 一条 STAT 合成一条 `RH=`，帧数确实从 O(N) 降到 O(1)。但 `relay_one_receipt` 内部有**两次** `shared.lock_or_recover()`：

```rust
let (sender_valid, receiver_valid, changed) = { let mut s = shared.lock_or_recover(); ... };  // 1
...
let is_primary_or_takeover = { let s = shared.lock_or_recover(); ... };                      // 2
```

而且 `sid_is_sender` / `login_is_receiver` 在两个分支里都会 `s.reg.nodes().iter().any(...)` **全表扫描注册表**（`main.rs:979-990`）。于是满配 100 senders × 1 Hz × R 个 receiver：

- 锁获取：**200 × R 次/秒**，与改之前完全相同（改之前是 100 帧 × 2 锁）；
- 每次锁内还可能全表 `nodes()` 扫描（节点数 K），即 O(N×K) 字符串比较/秒；
- 更糟的是这些锁现在**集中在同一帧的处理里连续获取**，而不是分散在 100 帧之间，短时间内对 `shared` 的争用更尖锐 —— Web API、cluster 同步、WS 广播都要抢同一把锁。

**建议**：把 batch 的 pair 校验合并到**一次**锁内完成（一次 `nodes()` 快照 → `HashSet`，一次 `mirrors` 批量插入，一次判定 `is_primary_or_takeover`），锁外只做去重表与 `send_receipt`。这样帧数与锁数一起降到 O(1)。

---

### F-05【中 · 逻辑】只配置日内亏损限额时，瞬态零净值仍会闩锁一整天

**位置**：`src/Include/Copier/CopierRisk.mqh:212-242`

V2 修复引入了"连续 2 次零净值才闩锁 + 连续 20 次健康净值后释放"，但释放逻辑挂在 `m_zeroLatched` 上：

```mql4
if(equity<=0.0) {
   ...
   if(m_lim.dailyLossPct>0.0 && !m_dailyTripped) { m_dailyTripped=true; ... }   // 不置 m_zeroLatched
   if(m_lim.maxDrawdownPct>0.0 && !m_ddTripped)  { m_ddTripped=true; m_zeroLatched=true; ... }
   return;
}
...
if(m_zeroLatched) {                       // ← 只有回撤路径才进得来
   m_recoverN++;
   if(m_recoverN>=CP_RECOVER_CONFIRM_N) {
      m_zeroLatched=false; m_recoverN=0;
      m_ddTripped=false; m_dailyTripped=false;
   }
}
```

**触发组合**：`DailyLossPct=5`、`MaxDrawdownPct=0`（只开日内保护，是很常见的配置）。账户切换 / 重连瞬间连续 2 次 `AccountEquity()==0` → `m_dailyTripped=true`，但 `m_zeroLatched=false`。之后净值恢复正常，恢复计数分支根本不会执行，`m_dailyTripped` 只在 `serverDay != m_day`（跨服务器日）时清除（`251-256`）。结果：**净值早已恢复正常，系统却拒开新仓一整天，日志还报 daily loss limit**。

历史 V2 报告的验收描述是"瞬态 0 后净值恢复 → 日闩可释放"，现代码只覆盖了同时配置回撤限额的情形。

**建议**：把"零净值闩"做成独立标志，无论哪个百分比限额被触发都置位；或在 `equity>0` 的恢复计数里不依赖 `m_zeroLatched`，直接检查"上次是零净值路径闩的"。SelfTest 补一条"仅 `dailyLossPct>0` + 2 次零 + 20 次健康 → `AllowOpen` 放行"的断言。

**已核实测试确实漏掉了这个组合**：`CopierSelfTest.mq4:1305-1310` 的 `rl` 是 `dailyLossPct=5.0 / maxDrawdownPct=0.0`；`rkBlown`（1341-1346）用的就是 `rl`，只断言"连续零会闩锁"，**没有恢复断言**。而唯一的恢复用例 `rkRecover`（1366-1379）配的是 `dailyLossPct=0 / maxDrawdownPct=5.0`。两个用例正好把"只开日内"和"要能恢复"拆开测了，合起来的那一种没人测。

---

## 3. Rust Hub / 跨端发现（F-06 ~ F-14）

### F-06【中低 · 跨端规则漂移】节点的 ini 形状校验比 Hub 少四条规则

| 规则 | Hub `config.rs::validate_ini` | 节点 `CopierConfig.mqh::CopierIniValidate` |
|---|---|---|
| 首个 `[section]` 之前出现 `key=value` | 拒绝（`has_section`，971-973） | **接受** |
| 空节名 `[]` / `[   ]` | 拒绝（964-966） | **接受**（只查首尾字符且 `len>=3`） |
| 节数上限 132 / 行数上限 12288 | 拒绝（990-1001） | **不检查** |
| key 全空白 `"  =v"` | 拒绝（`k.trim().is_empty()`） | **接受**（只查 `eq>0`） |

方向上是**节点更宽松、Hub 更严格**，所以 Hub 不会推送自己拒绝的 ini，短期内不会重现 HUB-03 的"死循环推配置"。但节点本地编辑的 ini、`CFGRPT` 回传的文本、以及"Hub 存下节点当前配置再推给别的节点"这条链路，仍可能携带 Hub 自己会拒绝的形状，形成跨节点不一致。`CopierIni::Load` 虽然另有 `CP_INI_MAX` / `CP_INI_SECTIONS` 兜底，但那是**加载时**而非**校验时**，两者报错口径也不同。

**建议**：把 `validate_ini` 的四条规则原样移植到 `CopierIniValidate`，并在 `tools/hub_config_test.py` 里加一组"同一批畸形 ini，两端判定必须一致"的表驱动用例。历轮备忘明确要求"守卫须与下游完整函数/拒绝谓词同构，不手抄阈值"，这里正是手抄导致的漂移。

### F-07【低中】B3 只做了"可见化"，没有阻断损坏文本，而且代价很贵

`CopierIniWriteAtomic` 在写盘后读回比对，不一致只 `Print` 一条 WARN，然后照常 `return true`。于是：

- 磁盘上的 `copier.ini` 仍是 `'?'` 版本；
- 下次 `LoadConfig()` 读到损坏文本 → 重新序列化 → `IH=` 变化 → Hub 判定不一致 → `reqcfg` → 节点把**损坏后的文本**作为 `CFGRPT` 上报 → Hub 的 `node_current_ini`（`main.rs:2625-2636`）被覆盖；
- 仪表盘 "Load Current Setting from Node" 从此显示乱码。

`PROTOCOL.md` 新增段落已经把三层往返语义写清楚了，但结论 2（"`IH=` cannot be affected by the file encoding"）只在**值都是 ASCII** 时成立；注释本身也承认将来加一个带非 ASCII 的 symbol alias 就会变假。而 `IH=` 一旦漂移就是持续的 `CFG` ↔ `CFGRPT` 抖动。

**建议**（按代价）：① 先把 F-01 的 O(n²) 修掉；② 把 WARN 升级为"拒绝本次 CFG 并上报 `ACK` 失败"，让 Hub 知道推送没落地；③ 长期仍应改成 `FILE_UNICODE` 或纯 ASCII 字节转义（历史 B3 建议未变）。当前状态属于"已经知道会坏、只是打了日志"。

### F-08【低】`RH=` 的 hash 字段没有格式校验

`parse_rh_pairs`（`main.rs:931-963`）只要求 `sid` 非空，`h` 原样保留（`"c:"` → `("", "")` 也接受）。随后 `send_receipt` 把 `h` 直接插进：

```rust
format!("V=1|SID=hub|...|T=RCPT|P=LOGIN={};SID={};H={}", login, sid, h)
```

一个 `RH=` 里带 `;` 或 `|` 的 h 会**新增/截断 RCPT 的 payload 字段**；`|` 甚至能提前结束 `P=` 段（Hub 自己不解析，但 Sender 的 `CopierDecodeEnv` 会把后面内容当 header 字段）。合法 sender 的哈希固定 8 位小写 hex，没有任何理由接受别的形状。

**建议**：`parse_rh_pairs` 里校验 `h.is_empty() || (h.len()==8 && h.bytes().all(is_ascii_hexdigit))`，非法对直接丢弃；`sid` 也顺手约束为纯数字 ≤11 位（与 `relay_one_receipt` 的 `sid_plausible` 同构，省掉一次无效锁）。另外 `MAX_PAIRS=4096` 相对 `CP_MAX_SENDERS=100` 大了 40 倍，按 `CP_MAX_SENDERS + 余量` 收紧即可。

### F-09【低 · 文档】常量注释与代码不一致

- `CopierDefs.mqh:245` 新增注释写 "`CP_MAX_SENDERS` is 32, 所以最坏 608 字节、一帧一定装得下"，而 `:57` 的实际定义是 **100**。这不是纯措辞问题 —— `CP_STAT_RH_CHUNK=1200` 就是按 32 算出来的，直接导致 F-03。
- `doc/PROTOCOL.md` 新增的 "What the code does enforce today" 说 F-02 要求 `topic == SID`，例外是"topic 是**已注册 receiver** 的 nid"；而当前 `main.rs:2809-2812` 的实现是 `topic_is_nid`（纯数字、长度 ≤11），**不查注册表**。代码里的注释（2801-2807）也明确写着"要求已注册 receiver 被考虑后否决了"。文档与代码对同一条安全规则给了两种描述。

---

### F-10【中 · HA】B1 的"空 hash 跳过比较"把"本端文件还没建"也一起跳过了

**位置**：`hub/src/cluster.rs:663-668`（`notif_diff` / `curve_diff`）、`hub/src/api.rs:3536-3546`

```rust
let notif_diff = remote_st.notif_hash != notif_h
    && !remote_st.notif_hash.is_empty()
    && !notif_h.is_empty();
```

`file_sha256()` 在**路径为空**（`--notifications none`）和**文件不存在**两种情况下都返回 `""`（`cluster.rs:137-141`）。B1 想区分的是前者，实现却用"hash 非空"一刀切，把后者也当成"功能未启用"。

**触发场景**：全新 Standby 启用了通知 / CURVE 白名单（路径有效），但对应文件还没创建；Primary 已配置好告警渠道和 `curve_clients.txt`。此时 `notif_h=""`、`curve_h=""` → 两个 diff 都为 false。如果两边 journal 也都是空的（新集群先配告警、还没发过任何命令），`needs_sync` 全 false → **一次 sync 都不会发起** → Standby 永远拿不到告警渠道与 CURVE 白名单。故障切换后告警静默、CURVE 允许列表可能为空。

历史 B1 报告建议的是给 `ClusterStatusResponse` 加 `notif_enabled` / `curve_clients_enabled` 布尔量，"只有双方都 enabled 才比较"，当前实现并不等价（enabled ≠ 文件已存在）。写盘侧（`cluster.rs:830-839`）倒是正确区分了"路径为空 = 未启用，跳过且不算错误"。

**建议**：`needs_sync` 用"本端路径是否为空"判 enabled，而不是用 hash 是否为空；`ClusterStatusResponse` 增加 enabled 标志以便双方对称。补测试："Standby 通知文件不存在 + Primary 有内容 + 两个 journal 皆空" → 必须发起一次 sync 并落盘。

### F-11【中高 · HA 不变量】文件同步失败时 epoch 仍被采纳，与 HUB-02 的注释/承诺相反

**位置**：`hub/src/cluster.rs:612-614`（注释）、`916-932`（实现）

```rust
// 612-614:
// HUB-02: Do NOT prematurely adopt higher epoch before /cluster/sync succeeds!
// Epoch is safely updated in post-sync handler only when file_sync_err is None ...

// 916-932:
let save_info = if data.epoch > s.cluster.epoch() {
    s.cluster.state.epoch = data.epoch;        // ← 无条件采纳
    (true, ...)
} ...
if let Some(err) = file_sync_err {
    s.cluster.sync_status = "sync_err";        // ← 之后才判断失败
} else { ... }
```

`file_sync_err` 会在 `cfg.replace_all` / `cmds.replace_all` / users 写盘 / 通知写盘 / CURVE 写盘 / users 解析等任一失败时被置位，但 **epoch 已经写进内存并落盘了**。注释承诺的守卫不存在。

**为什么危险**：Standby 的数据还是旧的，epoch 却追平了 Primary。后续若发生"双 Standby 决胜"（`cluster.rs:583-608`，`promote()` 会把 epoch +1）或 peer 失联后的接管，这个节点会带着**旧用户表 / 旧命令日志 / 旧 CURVE 白名单**成为更高 epoch 的 Primary；原 Primary 再看到 `remote epoch > epoch` 会按 ADR-04 自我降级（`549-574`）。这正是 HUB-02 要防的"数据回退 + 脑裂"。

`sync_status="sync_err"` 确实会清掉 `continuous_online_start`（971-977）并挡住 `cluster_failback_now`（`api.rs:3819`），所以**正常路径**不会立刻接管；风险集中在异常路径与后续 promote。属于"防护只剩一层状态字符串"的隐性不变量。

**建议**：把 epoch 采纳移到 `if file_sync_err.is_none()` 分支内（或先算 `save_info` 但只在成功时赋值），并补一条单测：注入一次写盘失败，断言 Standby 的 epoch 保持不变。

### F-12【中低 · 默认配置与文档承诺不符】用户表强同步默认关闭

`README.zh-CN.md:51` / `README.md` 都写"主备实时强同步：命令日志、配置修订、**用户权限**及客户端白名单"。但 `MTC_SYNC_USERS` 默认 `false`（`cluster.rs:642-644`、`api.rs:3527-3529`），`users_hash` 不参与 `needs_sync`（675 行），Primary 也只在开启时才返回 `users_content`（3530-3534）。

也就是说**默认部署下用户表根本不复制**：在 Primary 改密、禁用账号、新建管理员后，Standby 的 `users.json` 仍是旧的。切换过去后旧会话 / 旧密码可能重新可用。代码每 5 分钟会打一行 WARN（646-652），但一个默认开启的功能用"日志提醒"来兜底，不如在 README 与启动日志里写清楚"HA 用户同步需显式 `MTC_SYNC_USERS=1`"。

**建议**：至少修文档；更好的做法是默认开启但要求集群走 TLS/内网（注释里拒绝默认开启的理由是"明文 cluster 通道会泄露密码摘要"，这个理由成立，那就把前提写进部署文档并在 `/cluster/status` 里暴露 `users_sync_enabled`）。

### F-13【低中 · 跨端解码不一致】压缩字段解码失败时，Hub 返回原文、节点返回空

| 端 | 行为 |
|---|---|
| MQL `CopierCodec.mqh:434` | `CopierDecompressField` 解码失败 → `return ""` → `CopierDecodeSnapshot` 因 `R` 空而 `return -1`，**整包拒绝** |
| Rust `envelope.rs:179` | `decompress_field` 解码失败 → `latin1(field_bytes)`，即把 `"1:0:not_valid_z85..."` **原文当记录文本**返回 → `parse_snap` 逐条按 `~` 切、`sym` 为空全部 `continue`，`v.records=0` 但 `v.declared=N` |

结果：同一帧，节点直接丢弃，Hub 的持仓视图却显示"声明 N 条、解析到 0 条"（且 `N` 非空会让看板以为节点丢单）。Rust 单测 `decompress_field_corrupted_graceful`（291-294）把这个返回原文的行为**固定成了期望**，所以这不是偶发，是设计差异。

另外 pad 前缀判定也不完全同构：`envelope.rs:116-127` 要求 `s_prefixed.len()%5==0` 才认新格式，MQL `CopierCodec.mqh:383-388` 只查 `field[2]∈0..3 && field[3]==':'`。畸形帧上两端会走不同分支（R58-05 修过一轮，仍有残余）。

**建议**：统一为"解码失败返回空"，把 Rust 单测改成断言空串；pad 判定抽成同一套谓词并在 `hub_proto_test.py` 做双端向量比对。

### F-14【低】Standby 连只读的全网查询也拒绝

`commands_global`（`api.rs:2829-2835`）在 `is_read_only` 判断**之前**就 `if !is_primary { return 409 }`。于是 Standby 上看板点 `reqpos` / `reqcfg`（`is_read_only_op=true`，2817）会被 409 挡掉，尽管 2836 行的注释明确写了"允许只读操作"。Standby 是只读节点，只读查询本应可用（也是运维在切换前核对持仓的常用动作）。

**建议**：把 `!is_primary` 检查改成 `if !is_read_only && !is_primary`（`writes` 门已经在 2837 对读操作放行）。

---

## 4. 低危 / 性能优化空间

| 编号 | 位置 | 内容 |
|---|---|---|
| **F-15** | `cluster.rs:137-159` `file_sha256` | 缓存键只有 `(mtime, len)`。同一秒内被改写且长度不变的文件（等长 URL 替换、`"false"→"true"` 之类近似等长编辑）在 mtime 精度较粗的文件系统上会命中旧 hash，HA 判为"已一致"而跳过复制。建议加入 `size + mtime + 内容抽样`，或对 `users.json` / `curve_clients.txt` 这类小文件干脆不做缓存（它们本来就不大）。 |
| **F-16** | `main.rs:965-1035` | 见 F-04：batch pair 的 `nodes()` 全表扫描 + 双锁。可在一次锁内用 `HashSet<&str>` 预建注册表快照，把 O(N×K) 降为 O(N+K)。 |
| **F-17** | `notifications.rs:1255-1302` | `resolve_pinned_client` 仍每次发送新建 `reqwest::Client`（历轮 P-1 / P2 未修）。突发告警时每条都要 DNS + TCP + TLS 握手，且易触发厂商单 IP 频控。建议 `(host, resolved_addrs)` 为键、TTL 300s 的 client 缓存，SSRF 校验仍每次执行。 |
| **F-18** | `CopierTransport.mqh:517-531` | `SendUp` 尾帧 `sendMore` 成功而 `send` 失败时补 `send("",true)`；若空帧也失败，`ZMQ_SNDMORE` 残局仍在，下一条消息首帧会被拼进上一条（历轮 P-3 未修）。建议置 `m_framingCorrupted`，在下一次发送前重建 socket。 |
| **F-19** | `CopierSymbol.mqh` `CopierSymbolQuoteAgeMs` | 每次调用线性扫 256 槽（外层还有 memo）；100 符号 × 10Hz 时约 25 万次字符串比较/秒。可复用 `CopierUidIndex` 同款哈希。历轮 P5 曾判定"成本被高估"，但批量 STAT 落地后 Receiver 主线程更忙，值得重估。 |
| **F-20** | `main.rs:2729-2760` | 批量 STAT 后，`st.note_receipt_seen()` 的口径从"每帧一次"变成"每 pair 一次"。若看板用 `receipt/seen` 比值表示"去重节省率"，含义已经变了（帧数省了，但 seen 计数没变），需要在 `stats.rs` / 仪表盘文案里同步。 |
| **F-21** | `main.rs:975-990` `relay_one_receipt` | `sv = sid_is_sender \|\| warm \|\| count_by_role(Sender)==0`。最后一项**没有时间限制**：只要注册表里一个 sender 都没有（冷启动、sender 全掉线、registry 被清空），任意已连接的 receiver 上报任意数字 SID 都会被视为有效并触发一次 Hub 代发的 `RCPT`。`sid_plausible`（纯数字 ≤11 位）把目标限制在数字主题，影响有限，但历史 B7/C2 的"warm 窗口反射面"其实并未被 60s 窗口完全框住。建议把 `count_by_role==0` 也纳入 `warm` 时间条件，或改为"只放行注册表中真实存在的 receiver 的 `login`"。 |

---

## 5. 历轮遗留项复核（避免重复开案 / 避免误以为已修）

| 历史项 | 本轮结论 | 证据 |
|---|---|---|
| **A1 数据面无发布者归属** | **架构未修，文档已缓解** | `PROTOCOL.md` 新增 "The allow-list is a TRUST BOUNDARY" 整节，明写一条伪造 `SNAP N=0` 可清空所有镜像，"one hub, one operator"。代码仍是 `main.rs:2781-2823` 的 `SID`/topic 自证，无法区分发布者。属协议级，需 per-node pipe 或 payload HMAC，建议单独立项。 |
| **B3 ini ANSI 编码** | **部分缓解，未修根因** | 见 F-07 / F-01。只加了 WARN；`FILE_ANSI` 照旧。 |
| **B5 / P4 批量收据** | **已实现，但引入 F-03 / F-04 / F-08 / F-09** | `RH=` 两端已落地；`CP_NODE_VER` 仍 `"2.0"` 未升版。 |
| **A2 止损变动触发 4Hz 全量快照** | **已修复，闭环** | `MarkStateDirty` 拆成 State / Snapshot / Latest 三分（`Sender.mq4:441-443`）；`stopsDiff/ppriceDiff` 走 `MarkLatestDirty()`（2182），只 `RebuildSnapshotPayload()` 不广播（2339-2344）；`RebuildSnapshotPayload` 不动 `g_snapHash`（1731-1739），`IsRecentSnapHash` 同时接受 broadcast 与 latest（328）。**本轮追过消费端，未发现回归**。 |
| **V1/C5 journal 物理行镜像** | **已修复，闭环** | `commands.rs:1057-1096` / `config.rs:611` 的 `append_raw` 把每条合法行原样写盘并计数；`should_insert` 只决定内存 map。`apply_delta_lines` 先落盘后改内存，写失败会回滚 `line_count` 并返回 Err。 |
| **B2 全网 `close`** | **已修复** | `api.rs:2870-2882` 直接 400。 |
| **C4/V3 双 Hub PONG 提前 Disarm** | **已修复** | 两端 `g_pumpPongExpect`（`Sender.mq4:1132-1205`、`Receiver.mq4:7984-8032`）按期望 PONG 数递减后才 `Disarm`；`CopierPump` 另有 15ms 硬超时兜底，丢包不会永久卡泵。 |
| **H4 服务多实例** | **Rust 侧完成，脚本侧失效** | 见 F-02。`service.rs` 的 `service_name()`、`resolve_workdir()`、stdio 句柄改用 `static Mutex<Option<File>>`（不再 `mem::forget`）都正确。 |
| **P1 通知连接池 / P3 尾帧标志** | **仍未实现** | F-17 / F-18。 |
| **H1 `HELD=0` 抹空手工单 / H2/H3 备机日志** | **已修复** | `registry.rs:520-548` 用 `tc|` 注释区分孤儿与纯手工单；`commands.rs` 已 `append_raw`。 |
| **P5/P6/P7（上一轮判定"不做"）** | 维持原判，但 P5 建议随批量收据重估 | 见 F-19。 |

---

## 6. 测试缺口（按优先级）

1. **批量收据满配契约**：审计期间 `tools/hub_stat_path_test.py` 已新增 2 对 `RH=` 的黑盒用例（含"同一帧拆成两条 RCPT、各自保留自己的 hash 与目标"），Rust 侧另有 4 条单测（2 对 / 畸形串 / 9000 对上限）。**仍缺**的是：构造 `CP_MAX_SENDERS=100` 个 sender，断言 Hub 拆出 100 对、且 **分块数 == 1**（即验证 `CP_STAT_RH_CHUNK` 容得下满配）。所有现有用例都是 2 对，正好绕开 F-03 的 1200 字节边界。
2. **混合版本 Hub**：老 Hub（无 `RH=` 解析）+ 新 Receiver，断言所有 sender 的收据都能被处理；当前会静默丢一半（F-03）。
3. **HA 文件同步失败时不采纳 epoch**：注入一次 `replace_all` / 写盘失败，断言 Standby `epoch` 不变（F-11）。这是 HUB-02 承诺缺测试锁住的典型。
4. **HA 首次同步**：Standby 通知/CURVE 文件不存在、双方 journal 皆空、Primary 有内容 → 断言发生一次 sync 且文件落盘（F-10）。
5. **ini 大文本往返性能**：270 KB 含注释 ini 走一次 `CopierIniWriteAtomic`，断言 `CopierIniCmpNormalize` 的耗时 / 分块数有上界（F-01）。现有 5 条 B3 断言全是几十字节短串。
6. **ini 两端形状校验一致性**：表驱动畸形 ini，断言 `validate_ini` 与 `CopierIniValidate` 判定完全相同（F-06）。
7. **Risk 组合**：仅 `dailyLossPct>0` + 2 次零净值 + 25 次健康净值 → `AllowOpen` 必须放行（F-05）；当前 `rkBlown` 与 `rkRecover` 把这个组合劈成了两半。
8. **bat 冒烟**：设 `MTC_INSTANCE` 后跑安装/查询，断言服务名带后缀（F-02）。这个 bug 在 Windows cmd 上是确定性的，一条断言就能锁住。
9. **压缩字段失败语义**：同一畸形 `1:` 字段，断言 Hub 与节点都判为空/拒绝（F-13）。

---

## 7. 本轮复核确认无问题（避免下一轮重复排查）

1. **`constant_time_eq_str`**（`api.rs:1002-1013`）先比长度再逐字节 `xor`，不存在"短前缀被接受"的常量时间比较缺陷；cluster token middleware（1040-1068）在 `--users none` 下仍强制 token，未留匿名后门。
2. **F-02 收紧为 `topic_is_nid`**（`main.rs:2808-2823`）只要求纯数字 ≤11 位，不要求"已注册 receiver"，因此**不会**因为节点刚上线/注册表老化而误丢合法的定向补发 SNAP；10 位 raw acc 也仍匹配。我一度怀疑这里会丢帧，追到实现后排除。
3. **V1 `append_raw` 的错误路径**：写失败会 `line_count -= written` 并返回 Err，内存 map 未动，`cluster.rs` 会据此置 `sync_err`，三态闭合。
4. **`commands.rs::read_lines_from_path` / `load()` / `apply_delta_lines`** 的"合法行"谓词（`id`/`node` 非空）三处一致，行数水位不再撕裂。
5. **`snap-worker` 的 `last_known_receipt`**：队列满不推进回执（2858-2864），与 F-07 历史修复一致。
6. **`CopierStrBuilder::Result()`** 的成对合并仍先取 `merged` 临时变量（900-903），R60-01 修复在位；`CopierSeenRing::DropAt` 与四个消费端的"删除后不前进下标"契约一致。
7. **`CopierSnapshot` 三方计数**：`CopierEncodeSnapshot` 的 `N=` → `CopierDecodeSnapshot` 的 clamp → `CopierValidateSnapshot` 的 `decoded==min(N,cap)`，与 `CopierLotEncodable` 咽喉过滤同构；`N=0` 且 `R` 非空仍拒绝。
8. **`parse_snap`**（`positions.rs:286-390`）单趟扫描、`N=` 首字段不再被漏读；`envelope_payload` / `envelope_hdr` 分离正确。
9. **Rust cluster 锁范围**：`file_sha256` 与所有写盘都在 `shared` 锁外（616-629、726-735），未发现锁内磁盘 I/O 回归。

---

## 8. 修复优先级建议

| 顺序 | 项目 | 理由 |
|:---:|---|---|
| 1 | **F-01** | 改动最小（换 `CopierStrBuilder` + 先直接比较），收益最大：消除每次 CFG 推送的数十 GB 复制，且只影响新增代码 |
| 2 | **F-02** | 改 5 行 bat（块外 set 或 `!VAR!`），让 H4 多实例真正可用；否则装第二个服务会静默重配第一个 |
| 3 | **F-03** | 提 `CP_STAT_RH_CHUNK` 到 3072 + 升 `CP_NODE_VER` + 文档写明混合版本行为；避免滚动升级期收据静默丢失 |
| 4 | **F-11** | 一个 `if file_sync_err.is_none()` 守卫，守住 HUB-02 的核心承诺；配一条单测 |
| 5 | **F-05** | 独立零净值闩标志 + 一条组合断言，避免"只开日内保护"的账户被瞬态 0 净值锁一整天 |
| 6 | **F-10 / F-12** | HA 首次同步与用户表默认不同步，属"默认部署下 HA 承诺不成立"，应至少补文档 + 测试 |
| 7 | **F-04 / F-06 / F-07 / F-08 / F-14** | 按影响面分批：锁合并、两端校验对齐、B3 升级为拒绝、RH 字段校验、Standby 只读查询 |
| 8 | **F-15 ~ F-20** | 清理项，可随下一次性能专项一起做 |

---

## 9. 通读范围与说明

- **整文件顺序通读**：`CopierConfig.mqh`、`CopierCodec.mqh`、`CopierDefs.mqh`、`CopierTransport.mqh`、`CopierRisk.mqh`、`CopierFilter.mqh`、`CopierSizing.mqh`、`CopierPump.mqh`、`envelope.rs`、`cluster.rs`（全文含单测）、`CopierState.mqh` 前半、`CopierModel.mqh` 前半；以及**全部未提交改动**的 diff。
- **按关键路径大块下钻**：`CopierSender.mq4`（快照构建/广播、MODIFY 分支、收据修复、事件泵计数）、`CopierReceiver.mq4`（`OnTimer` 批量 STAT、`CopierSendStatus`、配置加载与风控刷新入口）、`main.rs`（`STAT` 处理、`relay_one_receipt`、F-01/F-02 转发、`send_receipt`/`copier_nid`、新增单测）、`api.rs`（鉴权 middleware、`cluster_sync` / `cluster_failback_now` / `commands_global`）、`commands.rs` 与 `config.rs` 的 journal 复制与 `append_raw`、`registry.rs::note_stat_at`、`positions.rs::parse_snap`、`CopierSelfTest.mq4` 的 Risk/B3 断言、`tools/tests.sh` 的 24 个套件清单、`tools/hub_stat_path_test.py` 新增的批量收据用例。
- **文档**：`README.zh-CN.md`、`README.md`（结构）、`doc/PROTOCOL.md` 新增段落、11-05 / 11-06 的四份历史审计报告、`.workbuddy-ai/memory/` 的 11-05 / 11-06 日志与长期备忘。
- **未逐行覆盖**：`dashboard.html`（453 KB 前端资源，仅核对引用关系）、`Receiver.mq4` / `api.rs` / `notifications.rs` / `tls.rs` / `users.rs` / `audit.rs` / `alerts.rs` / `curve.rs` 的全部行、`tools/*.py` 的逐条断言。这些模块历轮已多次专项审计，本轮以"与本批改动有交互的路径"为界下钻；若需要，可另开一轮针对前端与通知/TLS 的逐文件通读。
- **约束**：全程只读，未改动任何源码、配置、服务或测试；未连接经纪商、未启停进程。唯一新增文件即本报告。

---

*报告完毕。源程序保持原状，可直接下载本文件核对每条结论的 `文件:行号`。*

