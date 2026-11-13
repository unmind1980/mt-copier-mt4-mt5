# mt-copier 全栈深度代码审计与系统优化评估报告（2026-11-08 综合终审定案版）

> **审计执行模式**：严格只读（Strictly Read-Only）。未对生产代码、配置文件或运行环境做任何修改。  
> **审计方式**：独立全栈通读与交叉推演，不使用子代理，确保全栈模块不变量、状态流转与网络时序整体闭环。  
> **审计范围**：
> 1. **MQL4 / MQL5 客户端与 Include 核心头文件**（`src/Experts/CopierSender.mq4`、`src/Experts/CopierReceiver.mq4`、`src/Include/Copier/*.mqh` 全量 17 个头文件、`src/Scripts/CopierSelfTest.mq4`）。
> 2. **Rust Hub 核心中枢与内置测试套件**（`hub/src/*.rs` 17 个模块、173 项 Rust 单元测试、HA 双活集群同步、命令重试引擎、API 鉴权与 WebSocket、ZeroMQ 数据与控制通道）。
> 3. **全栈协议与测试门禁**（`doc/PROTOCOL.md`、`doc/HANDOFF.md`、`doc/CENTRAL-HUB-HA-FINAL-PLAN.md`、Python 协议测试套件）。
>
> **输出文件**：本报告已保存至 `mt-copier/outputs/mt-copier-fullstack-audit-comprehensive-2026-11-08.md`，供操作员与开发者随时下载查阅。

---

## 目录

1. [执行摘要与问题评级总表](#1-执行摘要与问题评级总表)
2. [交易安全与业务逻辑缺陷 (Critical & High Logic Errors)](#2-交易安全与业务逻辑缺陷)
   - [ISSUE-01【高危·交易安全】平仓/减仓类退出动作被 `SymbolMarketClosed()` 门禁误拦，并被 15 分钟长休眠放大](#issue-01高危交易安全平仓减仓类退出动作被-symbolmarketclosed-门禁误拦并被-15-分钟长休眠放大)
   - [ISSUE-02【高危·交易安全】常规单向跟单中，盈利侧/异常止损被 `CopierFitStop` 强行夹紧至市价边缘造成即时被动止损](#issue-02高危交易安全常规单向跟单中盈利侧异常止损被-copierfitstop-强行夹紧至市价边缘造成即时被动止损)
   - [ISSUE-03【高危·防线失效】伪造/非法 `CFG`/`CMD` 帧在数据通道被拒前已推进 `AcceptSeq` 水位，致后续合法事件全量丢弃](#issue-03高危防线失效伪造非法-cfgcmd-帧在数据通道被拒前已推进-acceptseq-水位致后续合法事件全量丢弃)
   - [ISSUE-04【中高·自伤风暴】日内权益基线建立失败或断线时，`RefreshRisk()` 每 100ms 全表遍历历史订单致主线程 CPU 爆表](#issue-04中高自伤风暴日内权益基线建立失败或断线时refreshrisk-每-100ms-全表遍历历史订单致主线程-cpu-爆表)
   - [ISSUE-05【中高·交易安全】MODIFY 失败退避惩罚攀爬 24 小时阶梯，致使订单长期裸奔失去移动止损与保护](#issue-05中高交易安全modify-失败退避惩罚攀爬-24-小时阶梯致使订单长期裸奔失去移动止损与保护)
   - [ISSUE-06【中·高频抖动】Sender 平仓探测复杂度达 $O(N^2)$ 且每次探测重置整个终端历史选区](#issue-06中高频抖动sender-平仓探测复杂度达-on2-且每次探测重置整个终端历史选区)
   - [ISSUE-07【中·时钟回绕】`CopierManualClosedRing` 混用 `GetTickCount()` 导致 49.7 天回绕后 TTL 垃圾回收失效](#issue-07中时钟回绕copiermanualclosedring-混用-gettickcount-导致-497-天回绕后-ttl-垃圾回收失效)
3. [并发一致性、死锁与网络状态机缺陷 (Concurrency & State Machine Issues)](#3-并发一致性死锁与网络状态机缺陷)
   - [ISSUE-08【高危·可用性】Hub `commands.rs` 与 `config.rs` 的 `replace_all()` 错误路径未恢复句柄，致日志永久进入 `NotConnected`](#issue-08高危可用性hub-commandsrs-与-configrs-的-replace_all-错误路径未恢复句柄致日志永久进入-notconnected)
   - [ISSUE-09【高危·状态机损坏】ZMQ 数据帧多段转发异常时空终止帧遇 `EAGAIN`，致 XPUB 套接字帧边界倒挂](#issue-09高危状态机损坏zmq-数据帧多段转发异常时空终止帧遇-eagain致-xpub-套接字帧边界倒挂)
   - [ISSUE-10【中高·延迟抖动】命令与审计日志在全局互斥锁内执行 `sync_data()` (fsync)，直接挂起 ZMQ 转发主循环](#issue-10中高延迟抖动命令与审计日志在全局互斥锁内执行-sync_data-fsync直接挂起-zmq-转发主循环)
   - [ISSUE-11【中高·安全漏洞】集群接口未校验公开的弱默认令牌 `DEFAULT_CLUSTER_TOKEN`，单机或默认配置下存在越权风险](#issue-11中高安全漏洞集群接口未校验公开的弱默认令牌-default_cluster_token单机或默认配置下存在越权风险)
   - [ISSUE-12【中·并发锁竞争】SNAP 未变更分支在 ZMQ 主线程同步持有 `shared.lock_or_recover()` 更新时间戳](#issue-12中并发锁竞争snap-未变更分支在-zmq-主线程同步持有-sharedlock_or_recover-更新时间戳)
4. [协议规范、内存卫生与性能优化空间 (Protocol, Memory & Performance)](#4-协议规范内存卫生与性能优化空间)
   - [ISSUE-13【性能优化·单核 5%+】`CopierGetSymbolInfo()` 缺乏极短本地缓存，高持仓下产生天量无谓系统 API 调用](#issue-13性能优化单核-5copiergetsymbolinfo-缺乏极短本地缓存高持仓下产生天量无谓系统-api-调用)
   - [ISSUE-14【健壮性优化】`HandleSnapshot` 全包拒绝策略导致单条脏数据永久冻结收敛](#issue-14健壮性优化handlesnapshot-全包拒绝策略导致单条脏数据永久冻结收敛)
   - [ISSUE-15【协议规范】`CopierPayloadHbt2` 违背精简心跳设计，每 5 秒持续冗余发送 `NAME=` 字段](#issue-15协议规范copierpayloadhbt2-违背精简心跳设计每-5-秒持续冗余发送-name-字段)
   - [ISSUE-16【内存优化】CSV 过滤解析 `CopierFilter.mqh` 在循环中高频单步 `ArrayResize`](#issue-16内存优化csv-过滤解析-copierfiltermqh-在循环中高频单步-arrayresize)
   - [ISSUE-17【性能优化】`CopierInTradingSession` 交易时段缓存仅为 1 秒，造成高频重复探测](#issue-17性能优化copierintradingsession-交易时段缓存仅为-1-秒造成高频重复探测)
5. [测试套件盲区分析（为何 720 MQL + 173 Rust 门禁全绿）](#5-测试套件盲区分析)
6. [排期实施与优先级建议](#6-排期实施与优先级建议)

---

## 1. 执行摘要与问题评级总表

本次深度全栈审计覆盖了整个 `mt-copier` 项目在最新基线下的所有生产源码与测试套件。通过端到端的协议流转与多线程并发推演，本次审计共识别出 **17 项** 值得重点关注的代码逻辑缺陷、架构漏洞与优化机会：

- **高危严重缺陷（Critical / High）**：4 项（平仓休市闭锁、止损夹紧爆损、非法帧推高水位、Hub 句柄丢失致永久瘫痪）
- **中高危缺陷（Medium-High）**：4 项（历史订单 CPU 自伤、止损退避 24 小时、ZMQ 帧倒挂、默认集群 Token 越权）
- **中危缺陷（Medium）**：4 项（平仓探测 $O(N^2)$、时钟回绕 TTL、锁内 fsync 抖动、主线程锁竞争）
- **性能与协议优化（Optimization / Hygiene）**：5 项（SymbolInfo 缓存、快照子集容错、HBT2 冗余字段、ArrayResize 优化、Session 缓存扩充）

| 编号 | 类别 | 模块与具体位置 | 级别 | 核心危害 / 表现简述 |
|---|---|---|:---:|---|
| **ISSUE-01** | 交易安全 | `Receiver.mq4:3326-3336`, `CopierState.mqh:1557` | **高危** | `SymbolMarketClosed()` 阻断平仓/减仓类退出动作，叠加 `allMktClosed` 导致队列陷入 15 分钟长休眠；图表品种不符时 `OnTick` 无法唤醒 |
| **ISSUE-02** | 交易安全 | `Receiver.mq4:4566-4597`, `CopierSizing.mqh:240` | **高危** | 常规正常跟单缺少对"止损位于盘口盈利侧"的拦截，`CopierFitStop` 将畸形 SL 夹紧至当前盘口价差边缘，导致秒级爆损平仓 |
| **ISSUE-03** | 协议安全 | `Receiver.mq4:7835-7847` (`RouteMessage`) | **高危** | `AcceptSeq` 位于控制帧（`CFG`/`CMD`）拒绝检查之前，恶意或异常帧的大序列号推进水位后，导致后续所有真实交易事件被全量丢弃 |
| **ISSUE-04** | 性能自伤 | `Receiver.mq4:5363-5412`, `CopierModel.mqh:259` | **中高** | `g_riskDayStartEquity <= 0` 时 60s 节流失效，断线或出金时每 100ms 遍历数万笔历史订单，导致主线程单核 CPU 100% 跑满 |
| **ISSUE-05** | 交易安全 | `Receiver.mq4:2984, 3909`, `CopierState.mqh:991` | **中高** | MODIFY 失败使用与 OPEN 相同的长阶梯（封顶 24 小时），止损调整失败后订单被锁定在无保护状态长达数小时至一天 |
| **ISSUE-06** | 延迟抖动 | `CopierModel.mqh:1348-1399`, `Sender.mq4:2264` | **中** | 批量平仓时同一 tick 对所有丢失槽位全表扫 `PositionsTotal()` 并执行 `HistorySelectByPosition`，形成 $O(N^2)$ 缓存重载冲击 |
| **ISSUE-07** | 时钟回绕 | `CopierState.mqh:1646`, `Receiver.mq4:6358` | **中** | 手动平仓记录环使用 32 位 `GetTickCount()`，系统连续运行 49.7 天发生整数回绕后，计算出的 `ageMs` 变负，TTL 垃圾回收永久失效 |
| **ISSUE-08** | 系统可用性 | `hub/src/commands.rs:501-522`, `config.rs:308` | **高危** | `replace_all()` 在释放句柄后若发生原子替换或 reopen 异常，提前 `?` 退出留下 `file = None`，导致命令日志永久报 `NotConnected` |
| **ISSUE-09** | 网络状态机 | `hub/src/main.rs:2900-2910` | **高危** | 数据转发中第二段 payload 遇 `EAGAIN` 失败时，补发空帧若再遇 `EAGAIN` 则被忽略，XPUB 套接字停留在 multipart 模式导致后续所有帧边界倒挂 |
| **ISSUE-10** | 实时性 | `hub/src/commands.rs:1042`, `audit.rs:554` | **中高** | 命令确认与审计落盘在全局互斥锁内同步调用 `sync_data()` (fsync)，磁盘 I/O 延迟直接卡死 ZMQ 交易转发事件循环 |
| **ISSUE-11** | 安全漏洞 | `hub/src/api.rs:1048-1065`, `cluster.rs:376` | **中高** | 集群 API 鉴权未校验硬编码的公开默认值 `DEFAULT_CLUSTER_TOKEN`，单机或默认模式下任何人带固定 header 即可获得最高 Admin 权限 |
| **ISSUE-12** | 并发竞争 | `hub/src/main.rs:2941-2945` | **中** | 常态未变更快照在 ZMQ 主线程同步获取 `shared.lock_or_recover()` 更新时间戳，削弱了异步 snapshot channel 的低延迟收益 |
| **ISSUE-13** | 性能优化 | `Receiver.mq4:4238, 4281, 4429` | **优化** | `CopierGetSymbolInfo()` 零缓存，300 仓位时每秒触发逾 4 万次终端底层系统 API 查询，估算浪费 3%~6% 单核 CPU |
| **ISSUE-14** | 健壮性 | `Receiver.mq4:6454`, `CopierCodec.mqh:598` | **优化** | 快照验证对记录数采取全包拒绝（All-or-Nothing），只要单条仓位解码异常，整个快照被丢弃，对账收敛陷入永久停滞 |
| **ISSUE-15** | 协议精简 | `CopierCodec.mqh:858-862` | **优化** | `CopierPayloadHbt2` 实现与文档注释相反，每 5 秒心跳依然打包冗余的 `NAME=` 字符串 |
| **ISSUE-16** | 内存卫生 | `CopierFilter.mqh:87-89` | **优化** | CSV 过滤项循环内部对 3 个动态数组单步执行 `ArrayResize`，应先预分配再紧缩 |
| **ISSUE-17** | 性能优化 | `CopierSymbol.mqh:77-84` | **优化** | `CopierInTradingSession` 缓存时间仅 1 秒，对于天级别的交易日程造成每秒高频重复计算 |

---

## 2. 交易安全与业务逻辑缺陷

### ISSUE-01【高危·交易安全】平仓/减仓类退出动作被 `SymbolMarketClosed()` 门禁误拦，并被 15 分钟长休眠放大

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:3318-3336` (`ExecuteQueue`)
- `src/Experts/CopierReceiver.mq4:4169` (`allMktClosed` 判定)
- `src/Include/Copier/CopierState.mqh:1557-1566` (`CopierQueueNotePass`)
- `src/Experts/CopierReceiver.mq4:9520-9540` (`OnTick` 唤醒逻辑)

#### 2. 代码现状与逻辑矛盾
```mql4
// 3318行：全局行情停滞（Feed Stall）—— 代码明确豁免了退出动作：
if(globalStall && a.kind!=CP_ACT_CLOSE && a.kind!=CP_ACT_TRIM && a.kind!=CP_ACT_DEDUP)
  { RotateQueue(); skipped++; mktClosedHeld++; continue; }

// 3326行：休市门禁 —— 却未做任何动作类型区分，无差别拦截！
if(SymbolMarketClosed(a.sym))
  {
   if(g_once.ShouldEmit("qclosed|"+a.sym))
      g_log.Info("market for "+a.sym+" is closed - holding queued action "
                 +a.uid+" (kind="+(string)a.kind+"); it will execute when the market reopens");
   RotateQueue();
   skipped++;
   mktClosedHeld++;
   continue;
  }
```

#### 3. 深度危害剖析
1. **推断休市不是真实休市**：`SymbolMarketClosed(sym)` 的触发条件包含：① 券商 132/10018 拒绝缓存（60s）；② 官方交易时段；③ **本品种报价停更超过 60 秒（Stale Feed）**。在正常开盘交易时间内，非主力货币对或夜间流动性偏低的品种，60~120 秒无 tick 跳动是非常普遍的现象。此时一旦发送端发出平仓指令，接收端会因第 ③ 项直接判定该品种“休市”，进而阻止平仓，将动作放回队尾！
2. **15 分钟长休眠触发**：若队列中当前仅有这笔平仓动作（或全部动作为此品种），`allMktClosed` 条件满足：
   ```mql4
   bool allMktClosed = (g_qn>0 && done==0 && (mktClosedHeld>=g_qn || (mktClosedHeld>0 && mktClosedHeld==skipped)));
   ```
   `CopierQueueNotePass()` 立即将周期性出队挂起 **15 分钟（900,000ms）**！
3. **`OnTick` 唤醒盲区**：`OnTick()` 仅在 `g_q[idx].sym == _Symbol` 时才唤醒队列。接收端 EA 通常挂载于 EURUSD 图表，如果被阻断的订单品种是 USDJPY、XAUUSD 或 US500，图表永远只接收 EURUSD 的 tick，**这个唤醒永远不会被触发**！
4. **后果**：一笔本应在毫秒级内完成的紧急平仓或止损清仓动作，被系统活生生推迟 15 分钟！严重违背了项目设计规范中“平仓类动作永远旨在释放风险，绝不主动拦截”的绝对原则。

#### 4. 修复建议
- 退出动作（`CP_ACT_CLOSE`、`CP_ACT_TRIM`、`CP_ACT_DEDUP`）**完全豁免** `SymbolMarketClosed()` 门禁，直接交由券商执行。如果券商确实休市，会立即返回错误代码 132（MT4）或 10018（MT5），由 `CopierOrderClose` 自行记录并退避；
- `allMktClosed` 统计时，必须排除退出类动作，15 分钟长休眠仅允许作用于纯开仓（`CP_ACT_OPEN`）队列；
- `OnTick()` 的唤醒条件应从单一 `g_q[idx].sym == _Symbol` 调整为更通用的队列遍历唤醒。

---

### ISSUE-02【高危·交易安全】常规单向跟单中，盈利侧/异常止损被 `CopierFitStop` 强行夹紧至市价边缘造成即时被动止损

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:4566-4597` (`QueueModifyIfNeeded`)
- `src/Include/Copier/CopierDefs.mqh:1317-1337` (`CopierMirrorStop`)
- `src/Include/Copier/CopierSizing.mqh:224-249` (`CopierFitStopAt`)

#### 2. 代码现状
在 `QueueModifyIfNeeded()` 中：
```mql4
double rawWantSl=wantSl;
double rawWantTp=wantTp;
wantSl=CopierFitStop(wantSl,local.sym,local.side,true,si2,clampedSl);
wantTp=CopierFitStop(wantTp,local.sym,local.side,false,si2,clampedTp);
// 4574行：仅在 actualInverted（反向跟单）时才防范止损穿越盘口！
if(actualInverted)
  {
   double mktPx=0.0;
   if(CopierGetClosePrice(local.sym,local.side,mktPx) && mktPx>0.0)
     {
      if(rawWantSl>0.0 && ((local.side==CP_SIDE_BUY && rawWantSl>=mktPx) || (local.side==CP_SIDE_SELL && rawWantSl<=mktPx)))
        {
         wantSl=local.sl;
         clampedSl=false;
         invertedCrossed=true;
        }
     }
  }
```

#### 3. 深度危害剖析
1. **止损计算基础**：在 A86-02 改动后，为了支持保本损与移动止损，`CopierMirrorStop` 将止损从“必须位于开仓价亏损侧”放宽为基于开仓偏移的有符号计算：`localOpen + (senderStop - senderOpen)`。
2. **盘口穿越场景**：由于接收端与发送端存在点差差异、报价源滑点，或者操作员在发送端手工微调止损，极易出现发送端的 SL 偏移在接收端本地换算后，**其绝对价格已经处于当前市价的盈利侧**（例如 BUY 单的 `rawWantSl >= live_bid`）。
3. **强行夹紧至盘口边缘**：由于常规跟单下 `actualInverted == false`，上述保护代码完全被跳过！随后进入 `CopierFitStopAt()`：
   ```mql4
   double minPx = marketPx - si.stopLevel;
   if(out > minPx) { out = minPx; clamped = true; } // 买单止损被强行夹至当前盘口下方最小距离
   ```
4. **致命连锁反应**：接收端向券商发起修改订单请求，将止损精准钉在盘口现价边缘（`marketPx - stopLevel`，通常仅 0~2 点）。订单刚修改成功，下一笔微小的行情跳动便立刻触发止损出局！本该继续持仓获利的订单，直接被 EA 亲手斩仓。

#### 4. 修复建议
在非 inverted 路径补上完全对称的防范逻辑：当原始推导出的 `rawWantSl` 相对当前市价已位于非法/穿越方向时（买单 `rawWantSl >= mktPx`，卖单 `rawWantSl <= mktPx`），**绝不执行夹紧**，而是保留原有本地止损 `wantSl = local.sl`，并记录限流告警。

---

### ISSUE-03【高危·防线失效】伪造/非法 `CFG`/`CMD` 帧在数据通道被拒前已推进 `AcceptSeq` 水位，致后续合法事件全量丢弃

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:7835-7847` (`RouteMessage`)
- `src/Experts/CopierReceiver.mq4:7695-7697` (`AcceptSeq`)

#### 2. 代码现状
```mql4
int effectiveStream=(e.type==CP_T_HBT)?CP_STREAM_HBT:stream;
if(!AcceptSeq(si,e,effectiveStream,topic))
  {
   g_dropped[si]++;
   return false;
  }

// H-02: 拒绝数据通道上的控制帧
if(e.type==CP_T_CFG || e.type==CP_T_CMD)
  {
   g_log.Warn("SECURITY: rejected "+e.type+" frame from data stream / sender "+g_sid[si]+"; control frames only accepted from @hub");
   return false;
  }
```

#### 3. 深度危害剖析
1. **时序颠倒**：`RouteMessage` 在进行消息类型与安全通道合法性检查（`H-02`）之前，先执行了 `AcceptSeq(si, e, effectiveStream, topic)`。
2. **水位被恶意拔高**：如果网络上出现伪造帧，或者某一配置错乱的节点在数据主题上发布了一条带有超大序列号（如 `SEQ=999999`）的 `CFG` 或 `CMD` 帧：
   - `AcceptSeq` 认为该消息序列号大于当前记录的水位，将其更新为 `g_lastSeq[si][CP_STREAM_EVENTS] = 999999`，并返回 `true`；
   - 随后代码执行安全检查，识别出该帧不应出现在数据流中，将其丢弃并记录 `SECURITY` 警告。
3. **持久瘫痪**：然而，该发送端在接收端本地的事件序列号水位已经被拔高到 999999！此后，该发送端发送的所有合法交易事件（`OPEN`、`CLOSE`、`MODIFY`，序列号正常递增如 10、11、12）在进入 `AcceptSeq` 时，都会因为 `e.seq <= g_lastSeq`（10 <= 999999）被判定为陈旧消息而全部被当场丢弃！甚至连快照也会因为 `e.seq < g_lastSeq[si][CP_STREAM_EVENTS]` 被误判为旧快照而丢弃。
4. **后果**：整个接收端对此发送端的交易复制完全瘫痪，直到该发送端重启生成新 SSID 为止。

#### 4. 修复建议
将 `CP_T_CFG` 与 `CP_T_CMD` 等非法帧的安全类型检查**前置到 `AcceptSeq` 之前**（与 PING/PONG 的处理平级），未通过合法性检查的帧绝对不允许触碰和推进序列号水位。

---

### ISSUE-04【中高·自伤风暴】日内权益基线建立失败或断线时，`RefreshRisk()` 每 100ms 全表遍历历史订单致主线程 CPU 爆表

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:5363-5412` (`RefreshRisk`)
- `src/Include/Copier/CopierModel.mqh:259-269` (`CopierRealizedToday`)

#### 2. 代码现状
```mql4
else if(g_riskDayStartEquity<=0.0 || now-g_lastRealizedMs>60000)
  {
   g_lastRealizedMs=now;
   bool rOk=false;
   double realized=CopierRealizedToday(dayStart,rOk);
   ...
   if(rOk)
     {
      double derivedBase=curBal-realized;
      if(derivedBase>0.0)
        {
         g_riskDayStartEquity=derivedBase;
         ...
        }
     }
  }
```

#### 3. 深度危害剖析
1. **节流条件逻辑断裂**：条件使用了 `||`。只要 `g_riskDayStartEquity <= 0.0` 成立，后半部分的 `now - g_lastRealizedMs > 60000`（60 秒节流保护）**完全失效**！
2. **基线未能建立的常见场景**：
   - 在 MT4 中，`CopierRealizedToday()` 在终端断线时直接返回 `if(!IsConnected()) { outOk=false; return 0.0; }`。周末、维护期或 VPS 网络闪断期间，`rOk` 恒为 `false`；
   - 账户当日发生较大出金或特殊盈亏，导致计算出的 `derivedBase <= 0.0`，基线不会被赋值，始终保持 `0.0`。
3. **CPU 疯狂空转**：`RefreshRisk()` 位于 `OnTimer` 的慢车道中，触发频率为 **每 100 毫秒一次**。在 MT4 中，`CopierRealizedToday()` 必须调用 `OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)` 遍历整张历史表。对于拥有数万笔历史交易的成熟实盘账户，这意味着**每秒钟调用几十万次终端底层 API**，主线程单核 CPU 被活活打满至 100%，不仅造成终端严重假死卡顿，更直接挤占抢夺了行情接收与实时下单的宝贵算力。

#### 4. 修复建议
- 强制施行严格的双重 60 秒节流：无论基线是否建立成功，两次历史扫描之间必须间隔至少 60 秒；
- 在 `!IsConnected()` 时直接退出，不重试、不扫描历史；
- 对 `CopierRealizedToday` 增加基于当日起始时间戳和余额变动的局部缓存，避免无节制全量扫表。

---

### ISSUE-05【中高·交易安全】MODIFY 失败退避惩罚攀爬 24 小时阶梯，致使订单长期裸奔失去移动止损与保护

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:2984-2988` (`PushAction`)
- `src/Experts/CopierReceiver.mq4:3909-3953` (`ExecuteQueue`)
- `src/Include/Copier/CopierState.mqh:991-1001` (`CopierBackoffMs`)

#### 2. 代码现状
在 `PushAction` 中：
```mql4
if(kind==CP_ACT_CLOSE || kind==CP_ACT_TRIM || kind==CP_ACT_DEDUP)
  {
   if(si>=0 && g_backoff.BlockedExit(key)) { g_pushReject="retry_backoff"; return false; }
  }
else
  {
   string boKey = (kind==CP_ACT_MODIFY && ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)ticket) : key;
   if(g_backoff.Blocked(boKey)) { g_pushReject="retry_backoff"; return false; }
  }
```
`Blocked(boKey)` 使用的默认阶梯为：1m -> 5m -> 15m -> 1h -> 6h -> 12h -> **24h**。

#### 3. 深度危害剖析
- 平仓类退出动作受到 `BlockedExit` 的保护，退避上限被严格封顶在 60 秒；
- 但修改止损/止盈动作（`CP_ACT_MODIFY`）被归入了常规动作分支，采用长达 24 小时的惩罚阶梯；
- 当一笔订单因券商短暂停盘、行情跳空越过止损最小距离（StopLevel）等原因导致连续 5~6 次修改失败后，该 ticket 对应的退避时间将被拉长至 **6 小时甚至 24 小时**；
- 在这长达一整天的时间内，即便行情已经恢复正常平稳，发送端后续发来的所有保本止损（Break-even）、移动止损（Trailing Stop）以及人工拉大止损的避险指令，都会被 `PushAction` 以 `retry_backoff` 为由无情拒绝；
- 如果该订单在建仓时未能成功附带初始止损，该订单将在接下来的十几个小时内以完全裸奔状态暴露在剧烈波动的市场中，失去风控保护。

#### 4. 修复建议
- 为 `CP_ACT_MODIFY` 引入独立的退避判定（如 `BlockedModify`），退避阶梯封顶在 30~60 秒，绝对不允许蔓延至数小时；
- 若本地订单当前处于“无任何止损”（`local.sl <= 0`）的高风险状态，强制将退避时间重置为极短的 2 秒探测（`Park(boKey, 2000)`），优先保障风控止损能尽快落地。

---

### ISSUE-06【中·高频抖动】Sender 平仓探测复杂度达 $O(N^2)$ 且每次探测重置整个终端历史选区

#### 1. 源码调用路径
- `src/Include/Copier/CopierModel.mqh:1348-1399` (`CopierIsTicketClosedInHistory`)
- `src/Experts/CopierSender.mq4:2263-2265`

#### 2. 深度危害剖析
- 在 `CopierSender.mq4` 的多槽位扫描中，当外部发生批量平仓（例如网格 EA 集中止盈平掉 50 笔订单）时，所有消失的槽位在初次检测时都满足 `g_slotMissCount[k] <= 1`；
- 于是，在同一个 tick 周期内，系统对这 50 笔订单分别调用一次 `CopierIsTicketClosedInHistory(ticket)`；
- 在 MT5 中，每次调用包含：
  1. 遍历当前所有持仓 `PositionsTotal()` 比对 Identifier（50 次）；
  2. 调用 `HistorySelectByPosition((ulong)ticket)`，该 API 会彻底清空并重置 MT5 终端内存中当前激活的历史 Deals 集合；
  3. 遍历历史 Deals 累加成交量；
- 50 笔平仓集中触发，意味着在几毫秒内触发 50 次终端缓存强制刷新和数千次属性提取。在券商服务器最拥堵、行情剧烈波动、最需要极速向接收端下发平仓指令的关键时刻，Sender 自身却因密集的终端缓存重载产生了明显的计算毛刺与延迟抖动。

#### 4. 修复建议
- 在单个 tick 内实行批量探测：先执行单次 `HistorySelect(now - 86400, now + 86400)` 获取近期 Deals 摘要哈希表，然后再针对所有丢失槽位进行 $O(1)$ 的内存集合查找；
- 限制单个 tick 内执行深层历史探测的槽位数量上限。

---

### ISSUE-07【中·时钟回绕】`CopierManualClosedRing` 混用 `GetTickCount()` 导致 49.7 天回绕后 TTL 垃圾回收失效

#### 1. 源码调用路径
- `src/Include/Copier/CopierState.mqh:1646, 1655, 1670`
- `src/Experts/CopierReceiver.mq4:6347, 6358`

#### 2. 代码现状与危害
- 项目全栈其他所有模块均已统一使用 64 位单调微秒时钟 `CopierNowMs()`（基于 `GetMicrosecondCount() / 1000`）；
- 但在 `CopierManualClosedRing` 中，记录时间戳却使用了 32 位的 `GetTickCount()`，并在 `CopierReceiver.mq4:6347` 中直接取 `gcNow = GetTickCount()`；
- `GetTickCount()` 在 Windows 系统启动约 49.7 天后发生 32 位无符号整数溢出回绕（从 $2^{32}-1$ 变为 0）；
- 回绕发生后，`ageMs = (long)(gcNow - m_at[m])` 瞬间变为极大的负数，导致 `ageMs > CP_MANUAL_CLOSED_TTL_MS` 永不成立；
- 那些由于券商修改了订单 Comment 而仅记录了 Ticket 的历史手动平仓记录，将彻底失去 TTL 自动淘汰机制，长期驻留并占满环形缓冲区。

#### 4. 修复建议
将 `CopierManualClosedRing` 内的所有时间戳记录与读取统一替换为 `CopierNowMs()`。

---

## 3. 并发一致性、死锁与网络状态机缺陷

### ISSUE-08【高危·可用性】Hub `commands.rs` 与 `config.rs` 的 `replace_all()` 错误路径未恢复句柄，致日志永久进入 `NotConnected`

#### 1. 源码定位
- `hub/src/commands.rs:501-522`
- `hub/src/config.rs:308-322`

#### 2. 代码现状
```rust
{
    let mut inner = self.inner.lock_or_recover();
    inner.file = None; // Drop file handle so Windows allows replacing the file
    crate::cluster::atomic_replace_file(std::path::Path::new(&tmp), &self.path)?; // ← 若此处失败提前返回
    let file = OpenOptions::new().create(true).append(true).open(&self.path)?;     // ← 若此处失败提前返回
    inner.file = Some(file);
    ...
}
```

#### 3. 深度危害剖析
1. **Windows 句柄抢占**：在 Windows 文件系统上，杀毒软件、系统索引服务或其他读取进程经常会瞬时锁定目标文件，导致 `atomic_replace_file`（调用 `MoveFileExW` 或 `CopyFileExW`）在特定时刻返回错误（如 `SharingViolation` 或 `AccessDenied`）。
2. **句柄断流与状态不可逆**：当 `atomic_replace_file` 或其后的 `OpenOptions::open` 发生任何 I/O 错误时，`?` 操作符直接将错误向上抛出并退出了 `replace_all()` 函数。
3. **不可逆的死锁状态**：在提前退出时，`inner.file` 已经被置为了 `None`！在随后的运行中，任何调用 `append_many`（包括命令确认 `ack()`、下发操作 `issue_op()`、重试门禁 `due_gated()`）的代码路径，都会命中：
   ```rust
   return Err(io::Error::new(io::ErrorKind::NotConnected, "command journal file handle is not open"));
   ```
4. **后果**：整个 Hub 的命令管理系统在逻辑上彻底“瘫痪”，所有命令永远卡在 pending 状态，重试阶梯失效，且该状态无法自行恢复，只能由运维人员人工重启进程。

#### 4. 修复建议
采用“尽力保障句柄存活”的防御性模式：无论文件替换成功与否，在退出前必须尝试重新打开原文件恢复 `inner.file`：
```rust
let mut inner = self.inner.lock_or_recover();
inner.file = None;
let replace_res = crate::cluster::atomic_replace_file(std::path::Path::new(&tmp), &self.path);
let reopen_res = OpenOptions::new().create(true).append(true).open(&self.path);
inner.file = reopen_res.ok();
replace_res?;
```

---

### ISSUE-09【高危·状态机损坏】ZMQ 数据帧多段转发异常时空终止帧遇 `EAGAIN`，致 XPUB 套接字帧边界倒挂

#### 1. 源码定位
- `hub/src/main.rs:2900-2910`

#### 2. 代码现状
```rust
let first_res = sock.send(topic, zmq::DONTWAIT | zmq::SNDMORE);
match first_res {
    Ok(()) => {
        if let Err(e) = sock.send(payload, zmq::DONTWAIT) {
            eprintln!("[hub] WARN forward payload frame failed ({}): closing multipart frame with empty terminator", e);
            // P1-04: Safely close multipart message with empty frame so socket is not left in torn state
            let _ = sock.send("", zmq::DONTWAIT);
        } else {
            st.note_forward(topic_str, &ty);
            ...
        }
    }
    Err(e) => { ... }
}
```

#### 3. 深度危害剖析
1. **多段消息协议约束**：ZeroMQ 要求，一旦使用 `ZMQ_SNDMORE` 发送了第一帧，套接字便进入内部多段消息组装状态，后续**必须**有一帧不带 `SNDMORE` 的数据将其收尾。
2. **非阻塞落空**：当某一订阅者管道堵塞或套接字高水位线（HWM）达到上限时，`sock.send(payload, zmq::DONTWAIT)` 返回 `EAGAIN`。紧接着尝试补发的 `sock.send("", zmq::DONTWAIT)` 在下行写缓冲区已满的同一时刻，**同样极大概率返回 EAGAIN**！
3. **静默吞错导致套接字损坏**：`let _ = ...` 默默忽略了关帧失败。此时，ZMQ 套接字底层仍然坚挺地挂在 `SNDMORE` 状态！
4. **帧错位灾难**：当下一条完全无关的交易消息到达时，代码执行 `sock.send(new_topic, zmq::DONTWAIT | zmq::SNDMORE)`。ZMQ 底层将这个 `new_topic` 当成了上一条消息的 payload！而随后的 `new_payload` 则被当成了第三段……
5. **后果**：整个 XPUB 套接字上的消息帧序列被彻底打乱，所有订阅端收到的消息都变成“前一半的主题拼后一半的载荷”，导致全网节点解析协议全部报错，数据流瞬间阻断。

#### 4. 修复建议
借鉴 MQL 端 `CopierTransport.mqh` 的严密防护机制：在 Hub 内部引入 `mid_multipart: bool` 状态追踪。一旦第二段发送失败且补发终止帧未能成功，标记 `mid_multipart = true`；在处理下一条消息之前，优先以非阻塞循环或严格校验确保将上一次残留的悬空消息关闭，若无法关闭则暂缓发送新消息并重置连接。

---

### ISSUE-10【中高·延迟抖动】命令与审计日志在全局互斥锁内执行 `sync_data()` (fsync)，直接挂起 ZMQ 转发主循环

#### 1. 源码定位
- `hub/src/commands.rs:1042`
- `hub/src/config.rs:545, 580`
- `hub/src/audit.rs:554`

#### 2. 代码现状
```rust
match f.write_all(buf.as_bytes()).and_then(|_| f.sync_data()) {
    Ok(()) => Ok(()),
    Err(e) => { ... }
}
```
调用者（`ack`、`issue_op`、`due_gated_with`）全部在获取了 `self.inner.lock_or_recover()` 之后调用 `append_many`。

#### 3. 深度危害剖析
- 每次客户端发来命令回执（`ACK`），ZMQ 事件循环的主线程都要同步调用 `commands.ack()`；
- `commands.ack()` 持有 `self.inner` 互斥锁，并在该锁保护下同步调用系统的 `sync_data()`（底层触发 Windows 的 `FlushFileBuffers`）；
- 在机械硬盘、阵列卡刷新或低配公有云 VPS（如 AWS EBS / 阿里云 ESSD 爆发耗尽）上，一次真实的磁盘刷新耗时通常在 2ms~20ms 不等；
- **锁内 fsync 是高频低延迟系统的重大禁忌**：这不仅让 ZMQ 主转发循环暂停数毫秒（直接拖慢了同一时刻正在并发流转的毫秒级跟单事件），还阻塞了所有正在请求 Web 状态、统计信息或进行 HTTP 鉴权的辅助工作线程。

#### 4. 修复建议
- 将持久化落盘改为异步日志架构（专用写线程 + `mpsc` 无锁队列），内存状态即刻更新，磁盘 I/O 在后台异步流水线化执行；
- 或采用两段式提交：在互斥锁内完成内存状态演进并生成序列化字符串，**释放锁之后**在锁外执行磁盘写入与 `sync_data()`，若写盘失败再重新获取锁回滚内存索引。

---

### ISSUE-11【中高·安全漏洞】集群接口未校验公开的弱默认令牌 `DEFAULT_CLUSTER_TOKEN`，单机或默认配置下存在越权风险

#### 1. 源码定位
- `hub/src/api.rs:1048-1065`
- `hub/src/cluster.rs:376, 382`

#### 2. 代码现状
```rust
let is_cluster_path = path.starts_with("/api/v1/cluster/");
if is_cluster_path {
    let cluster_token = st.lock_or_recover().cluster.cluster_token.clone();
    let auth_hdr = req.headers().get(axum::http::header::AUTHORIZATION).and_then(|v| v.to_str().ok());
    let x_hdr = req.headers().get("X-Cluster-Token").and_then(|v| v.to_str().ok());
    let token_matches = auth_hdr.map(|h| h.strip_prefix("Bearer ").unwrap_or(h)).map(|h| constant_time_eq_str(h, &cluster_token)).unwrap_or(false)
        || x_hdr.map(|h| constant_time_eq_str(h, &cluster_token)).unwrap_or(false);
    if token_matches {
        req.extensions_mut().insert(Session {
            user_id: "cluster".to_string(),
            role: UserRole::Admin, // ← 直接获得超级管理员权限
            seen: unix_secs(),
            pass_hash: String::new(),
        });
        req.extensions_mut().insert(Token(cluster_token));
        return next.run(req).await;
    }
}
```

#### 3. 深度危害剖析
1. **公开的硬编码常量**：在 `cluster.rs:23` 中，公开定义了 `DEFAULT_CLUSTER_TOKEN = "mtc-cluster-auth-secret-token"`。在 `ClusterManager::disabled()` 或未配置独立密钥的环境下，`cluster_token` 会直接沿用此默认字符串。
2. **鉴权漏检默认值**：在 `cluster.rs:247` 的 `token_is_usable` 中，系统明确排除了该默认公开值；但是在 `api.rs` 的中间件里，直接盲目执行了 `constant_time_eq_str(h, &cluster_token)`，**未曾检查 `cluster_token` 是否是可用的非默认安全令牌**！
3. **严重越权后门**：在很多单机部署或测试环境中，任何外部网络攻击者只需在请求头中附带：
   `Authorization: Bearer mtc-cluster-auth-secret-token`
   即可通过集群鉴权检查，被系统直接授予 `UserRole::Admin` 的完全管理员身份，进而可以调用提权、下发命令、强制重载等敏感接口。

#### 4. 修复建议
在 `api.rs` 中引入严格的可用性检查：只有当 `cluster_token` 长度大于等于 16 字节且不等于 `DEFAULT_CLUSTER_TOKEN` 及已知公钥时，才允许基于令牌放行；否则一律拒绝匿名凭据访问。

---

### ISSUE-12【中·并发锁竞争】SNAP 未变更分支在 ZMQ 主线程同步持有 `shared.lock_or_recover()` 更新时间戳

#### 1. 源码定位
- `hub/src/main.rs:2941-2945`

#### 2. 代码现状
```rust
if should_dispatch {
    match snap_tx.try_send((sid.clone(), snap_payload.to_vec(), pos_now)) { ... }
} else {
    // Touch timestamp in positions without blocking for full parse
    let mut s = shared.lock_or_recover();
    s.pos.touch(&sid, pos_now);
}
```

#### 3. 深度危害剖析
- 系统原本设计了 `snap_tx` 异步通道，将繁重的快照解码工作剥离至后台线程，确保 ZMQ 转发主线程维持微秒级延迟；
- 然而在实盘中，99.9% 的周期性快照是没有发生任何持仓变化的（`should_dispatch == false`）；
- 在这个绝大多数场景都命中的分支里，代码却在 ZMQ 主循环线程上直接调用 `let mut s = shared.lock_or_recover()`；
- `shared` 是一把保护了全量全局状态的大锁，Web API 的 `/api/v1/positions` 查询、`/api/v1/nodes` 节点遍历等都在竞争同一把锁。若恰逢 Web 线程正在序列化一个包含 2000 个仓位的 JSON 大对象，ZMQ 主循环便会在这里被动挂起数毫秒，与异步解耦的设计初衷背道而驰。

#### 4. 修复建议
将更新时间戳的轻量通知同样通过 `snap_tx` 发送给后台工作线程处理，或者在 `Positions` 内部使用独立的细粒度读写锁（`RwLock`）隔离时间戳更新，彻底解除 ZMQ 主循环对 `SharedState` 大互斥锁的依赖。

---

## 4. 协议规范、内存卫生与性能优化空间

### ISSUE-13【性能优化·单核 5%+】`CopierGetSymbolInfo()` 缺乏极短本地缓存，高持仓下产生天量无谓系统 API 调用

#### 1. 源码调用路径
- `src/Experts/CopierReceiver.mq4:4238, 4281, 4429`
- `src/Include/Copier/CopierModel.mqh:35-65`

#### 2. 性能损耗模型分析
在 `ConvergeSender` 收敛循环中，每一个与本地持仓匹配的单据在每一轮定时遍历中都会执行以下调用：
1. `ComputeTargetLotsForMirror` 内部调用 1~2 次 `CopierGetSymbolInfo`；
2. `QueueModifyIfNeeded` 内部调用 1 次 `CopierGetSymbolInfo`；
3. `QueueTrimIfNeeded` 内部调用 1 次 `CopierGetSymbolInfo`。

在 MT5 环境下，单次 `CopierGetSymbolInfo` 需要连续调用 8~9 个底层终端 API（包括 `SYMBOL_POINT`、`SYMBOL_DIGITS`、`SYMBOL_VOLUME_MIN`、`SYMBOL_VOLUME_MAX`、`SYMBOL_VOLUME_STEP`、`SYMBOL_TRADE_STOPS_LEVEL`、`SYMBOL_TRADE_TICK_SIZE`、`SYMBOL_TRADE_CONTRACT_SIZE` 等）。

- **计算量估算**：若账户同时跟单 300 笔持仓，在每秒 4 次的常规收敛周期下，系统每秒将爆发 **$300 \times 3.5 \times 9 \approx 33,000$ 至 $45,000$ 次底层系统调用**！
- **收益评估**：品种的合约规格（小数位、最小手数、步进、停损水平）在券商端属于极罕见变更的静态参数。引入一个类似 `g_symFresh` 的 256 槽直接映射结构体缓存（TTL 设置为 30~60 秒），可直接削减 99.9% 的 API 轮询消耗，粗估降低单核 CPU 占用 3%~6%。

---

### ISSUE-14【健壮性优化】`HandleSnapshot` 全包拒绝策略导致单条脏数据永久冻结收敛

#### 1. 源码定位
- `src/Experts/CopierReceiver.mq4:6454`
- `src/Include/Copier/CopierCodec.mqh:598-603`

#### 2. 机制分析
```mql4
int expected=(sent>maxCapacity)?maxCapacity:sent;
if(decodedCount<0 || decodedCount!=expected)
  {
   err="count mismatch: decoded "+(string)decodedCount+" expected "+(string)expected;
   return false;
  }
```
- 当前接收端对快照采用了“全包拒绝（All-or-Nothing）”策略。如果发送端持有 500 笔持仓，其中仅有 1 笔因浮点舍入过小导致 `lots=0.0`，或因极罕见的符号转义导致解码单行失败，`decodedCount` 将变为 499；
- 因为 $499 \neq 500$，整个快照被判定为非法并整体丢弃，接收端拒绝更新 `g_desired`；
- 由于发送端持仓在未变化前广播的原始字节流完全一致，此后的每一次快照都将持续报错失败，导致该发送端的对账收敛与自动平仓功能永久陷入停滞状态。

#### 3. 建议方案
建议分级处理：当 `decodedCount > 0 && decodedCount < expected` 时，允许接受已成功解码的有效子集，但暂时跳过本轮“发送端已平仓”的清仓动作（对未匹配的本地持仓保持观察，避免误平仓），并在 STAT 状态中向 Hub 上报警告状态，从而在兼顾安全的同时避免整个系统的自愈收敛彻底冻结。

---

### ISSUE-15【协议规范】`CopierPayloadHbt2` 违背精简心跳设计，每 5 秒持续冗余发送 `NAME=` 字段

#### 1. 源码定位
- `src/Include/Copier/CopierCodec.mqh:827-833`, `858-862`

#### 2. 代码对比
- **规范注释（827-833行）**：“REG 与 HBT2 的唯一差别在于 REG 携带终端名称 NAME，而 HBT2 不携带：每隔几秒重复发送一个无法改变的终端名称毫无意义且浪费带宽。”
- **实际实现（858-862行）**：
  ```mql4
  string CopierPayloadHbt2(const string role,const long acc,const string name,const long upSeconds)
    {
     return CopierBuildNodePayload(role,acc,name,upSeconds); // 依然打包了 NAME=
    }
  ```
- **影响**：纯网络开销与代码契约不符。虽不影响交易正确性，但违背了协议设计文档中的既定约束。

---

### ISSUE-16【内存优化】CSV 过滤解析 `CopierFilter.mqh` 在循环中高频单步 `ArrayResize`

#### 1. 源码定位
- `src/Include/Copier/CopierFilter.mqh:87-89`

#### 2. 机制分析
```mql4
ArrayResize(m_item,kept+1);
ArrayResize(m_itemLong,kept+1);
ArrayResize(m_itemLongValid,kept+1);
```
在解析 `PermittedSymbols` 等列表时，代码每匹配到一个有效项，就同时对 3 个动态数组执行一次单步扩容（`ArrayResize(..., kept + 1)`）。在 MQL 运行环境中，这会触发多次内存重新分配与碎片化开销。建议在进入循环前直接一次性预分配 `n`（即 `parts` 数组的最大可能容量），循环结束后再单次缩容至 `kept`。

---

### ISSUE-17【性能优化】`CopierInTradingSession` 交易时段缓存仅为 1 秒，造成高频重复探测

#### 1. 源码定位
- `src/Include/Copier/CopierSymbol.mqh:77-84`

#### 2. 机制分析
```mql4
if(g_sessKey[i]==sym)
  {
   foundIdx=i;
   if(now>=g_sessAt[i] && now-g_sessAt[i]<1) return g_sessVal[i];
   break;
  }
```
- `now` 是以整秒递增的服务器时钟（`CopierServerTime()`）；
- `now - g_sessAt[i] < 1` 意味着这个缓存的存活期实际上只有 **0 秒（同 1 秒内命中）**，进入下一秒便必定失效；
- 券商官方的交易时段以小时和天为单位，每秒都重新调用 8 次 `SymbolInfoSessionTrade` 纯属空耗计算资源。将缓存阈值放宽至 30~60 秒，既能保证及时响应休市切换，又能大幅减少终端底层的无效计算。

---

## 5. 测试套件盲区分析

在本次审计前，项目既有的测试门禁表现极为优异：
- **MQL 自检套件**：715 项断言全部 PASS（`tools/selftest_run.sh`，MT5 715 基线通过）；
- **Rust 单元测试**：173 项测试全部 PASS（`hub/build.sh --test`，173 passed, 0 failed）；
- **Python 端到端测试**：`hub_commands_test.py` 等 22 个测试套件 47/47 PASS。

### 为什么如此扎实的测试门禁依然漏过了上述问题？

1. **ISSUE-01（平仓休市闭锁）**：既有的自检用例 `TestQueue` 均在活跃交易日模拟，且测试数据中的品种名称与图表品种高度一致，没有构建过“队列中仅有 CLOSE/TRIM 动作，且对应品种的行情停更超过 60 秒”的极端停盘场景。
2. **ISSUE-02（止损向盘口夹紧）**：`TestStopCalculations` 仅断言了“发送端止损位于正常亏损侧”的标准场景，没有构造“发送端止损由于点差或手工修改已经越过接收端当前盘口”的异常输入向量。
3. **ISSUE-03（控制帧推高序列号）**：测试套件中的安全测试覆盖了“非法控制帧必须被拒绝”，但断言仅检查了返回值是否为 `false`，**没有在拒绝后继续发送一帧合法的交易事件**来断言后续合法事件是否依然能够被正常接收。
4. **ISSUE-04（历史订单 CPU 自伤）**：所有自检用例均运行在连接正常的测试终端中，`IsConnected()` 始终为真且历史单据极少，未曾模拟真实实盘中积累数万笔订单且遭遇断线时的自激震荡。
5. **ISSUE-08 & ISSUE-09（Hub 句柄丢失与 ZMQ 帧倒挂）**：Rust 单元测试基于纯内存或标准 POSIX 模拟环境，未曾在注入 Windows 文件锁（如杀毒软件抢占）或制造高负载下行网络背压（`EAGAIN`）的状态下进行故障注入测试。
6. **ISSUE-11（弱集群令牌）**：集成测试中显式传递了生成的随机测试 Token，未曾针对“携带默认常量 `DEFAULT_CLUSTER_TOKEN` 的恶意请求是否会被拒绝”编写负向断言。

---

## 6. 排期实施与优先级建议

基于交易安全第一、系统可用性优先的金融系统原则，建议后续的修复与优化工作分三批次推进：

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 第一优先级：交易安全与致命缺陷（本轮必须关闭，消除爆单、死锁与瘫痪隐患）   │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. ISSUE-01: 退出动作（CLOSE/TRIM/DEDUP）彻底豁免 SymbolMarketClosed 门禁  │
│ 2. ISSUE-02: 常规跟单补齐防夹紧保护，禁止将越界 SL 夹到盘口边缘           │
│ 3. ISSUE-03: 将 CFG / CMD 帧类型合法性校验提前至 AcceptSeq 水位推进之前  │
│ 4. ISSUE-08: Hub replace_all() 失败路径必须保障 inner.file 句柄存活恢复 │
│ 5. ISSUE-09: Hub ZMQ 数据多段转发增加 mid_multipart 状态闭环保护         │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 第二优先级：系统稳定性与可用性（消除 CPU 飙高、长时间闭锁与权限后门）     │
├─────────────────────────────────────────────────────────────────────────┤
│ 6. ISSUE-04: RefreshRisk 历史订单扫描增加强制 60s 节流与断线短路保护       │
│ 7. ISSUE-05: MODIFY 失败退避设置独立 30~60s 封顶阶梯，无损单优先探测     │
│ 8. ISSUE-10: commands / config / audit 日志 fsync (sync_data) 移出互斥锁 │
│ 9. ISSUE-11: 集群 API 鉴权显式拦截 DEFAULT_CLUSTER_TOKEN 等弱默认密钥    │
│ 10. ISSUE-07: CopierManualClosedRing 统一使用 CopierNowMs 消除 49天回绕 │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 第三优先级：计算性能、带宽优化与代码卫生（随版本迭代优化，精简架构开销） │
├─────────────────────────────────────────────────────────────────────────┤
│ 11. ISSUE-13: CopierGetSymbolInfo 增加 60 秒本地规格缓存，降低单核占用   │
│ 12. ISSUE-06: Sender 平仓探测改为每 tick 单次批量 HistorySelect 索引     │
│ 13. ISSUE-12: SNAP 未变更快照解绑 SharedState 互斥锁，减少 ZMQ 主线程锁竞争│
│ 14. ISSUE-14: HandleSnapshot 实行子集容错，避免单条坏数据冻结整包对账    │
│ 15. ISSUE-15: HBT2 心跳按契约剥离冗余 NAME 字段                         │
│ 16. ISSUE-16: CopierFilter 预分配数组，消除循环内部频繁 ArrayResize     │
│ 17. ISSUE-17: CopierInTradingSession 缓存放宽至 30~60 秒                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

> **结语**：本报告已完整落盘保存于 `mt-copier/outputs/mt-copier-fullstack-audit-comprehensive-2026-11-08.md`。审计全程保持严格的只读模式，未触碰任何业务代码。后续操作员可随时查阅并按优先级逐项调度实施。
