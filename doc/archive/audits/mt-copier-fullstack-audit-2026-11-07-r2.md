# mt-copier 全栈深度代码审计与优化评估报告（2026-11-07 / 第 111 轮）

> **审计基线**：`HEAD = bbaa07f` + 第 110 轮未提交工作区变更（13 个文件已修改）  
> **审计范围**：
> - MQL 客户端与头文件：`src/Include/Copier/*.mqh`（全部 17 个头文件）、`src/Experts/CopierSender.mq4`、`src/Experts/CopierReceiver.mq4`、`src/Scripts/CopierSelfTest.mq4`
> - Rust Hub 核心中枢：`hub/src/*.rs`（全部 17 个模块：`main.rs`、`api.rs`、`commands.rs`、`cluster.rs`、`config.rs`、`envelope.rs`、`positions.rs`、`registry.rs`、`stats.rs`、`lockx.rs`、`notifications.rs`、`tls.rs`、`users.rs`、`audit.rs`、`alerts.rs`、`curve.rs`、`service.rs`）
> - 测试套件与工具：`hub/src` 内置 172 项单元测试、`tools/*.py` 全量 Python 自动化测试脚本
> - 文档规范：`doc/PROTOCOL.md`、`doc/HANDOFF.md`、`doc/CENTRAL-HUB-HA-FINAL-PLAN.md`、`README.md`、`.workbuddy-ai/memory/MEMORY.md`
>
> **审计约束**：**严格只读**。未修改任何工程源码、配置文件或运行时环境；本报告作为唯一交付文件保存于 `outputs/mt-copier-fullstack-audit-2026-11-07-r2.md`，供用户下载审阅。单进程全栈连贯通读，未派发子代理。

---

## 目录

1. [执行摘要与问题评级总表](#1-执行摘要与问题评级总表)
2. [关键逻辑错误与隐患详解 (Critical & High Logic Errors)](#2-关键逻辑错误与隐患详解)
   - [L-01: `SendUp` 双发遇破帧清理失败时 `continue` 导致后续帧二次污染与误报成功](#l-01-sendup-双发遇破帧清理失败时-continue-导致后续帧二次污染与误报成功)
   - [L-02: `g_uidPeakLots` 全局单表容量耗尽致多 Sender 场景下 FIXED 比例减仓静默失效](#l-02-guidpeaklots-全局单表容量耗尽致多-sender-场景下-fixed-比例减仓静默失效)
   - [L-03: `CopierClosePartial` 硬编码 `1e-7` 浮点阈值与 8 位小数手数精度不匹配](#l-03-copierclosepartial-硬编码-1e-7-浮点阈值与-8-位小数手数精度不匹配)
   - [L-04: MT4 `CopierRealizedToday` 异步历史就绪竞态导致盘中冷启动误锁零亏损基线](#l-04-mt4-copierrealizedtoday-异步历史就绪竞态导致盘中冷启动误锁零亏损基线)
   - [L-05: Rust Hub `replace_all()` 重建日志时多重释放锁导致并发请求读写空句柄与脏状态](#l-05-rust-hub-replace_all-重建日志时多重释放锁导致并发请求读写空句柄与脏状态)
3. [架构与协议一致性问题 (Medium Architecture & Protocol Issues)](#3-架构与协议一致性问题)
   - [M-01: `ConnectExtraHub` 手动重放订阅与 libzmq XSUB 自动重放叠加导致引用计数虚高](#m-01-connectextrahub-手动重放订阅与-libzmq-xsub-自动重放叠加导致引用计数虚高)
   - [M-02: Standby 备机变更高危 API 端点返回格式与只读命令拦截提示不一致](#m-02-standby-备机变更高危-api-端点返回格式与只读命令拦截提示不一致)
   - [M-03: `StopsPrune` 紧缩删除尾部槽位未清空字符串引用引发内存驻留](#m-03-stopsprune-紧缩删除尾部槽位未清空字符串引用引发内存驻留)
   - [M-04: `StopsPrune` 在活跃移动止损满表下每事件全量扫描引发的主线程抖动](#m-04-stopsprune-在活跃移动止损满表下每事件全量扫描引发的主线程抖动)
4. [性能与内存优化空间 (Performance & Memory Optimization)](#4-性能与内存优化空间)
   - [O-01: `SerializeCurrentConfigToIni` 块内字符串累加与多映射双重循环优化](#o-01-serializecurrentconfigtoini-块内字符串累加与多映射双重循环优化)
   - [O-02: `PeakFind` 直接映射哈希碰撞覆盖引发的 O(N) 线性退化与乒乓震荡](#o-02-peakfind-直接映射哈希碰撞覆盖引发的-on-线性退化与乒乓震荡)
   - [O-03: 100-Sender 突发快照下 ZMQ 接收队列排空上限与端到端延迟控制](#o-03-100-sender-突发快照下-zmq-接收队列排空上限与端到端延迟控制)
   - [O-04: `EncodeReceiverPositions` 局部格式化中间字符串临时分配优化](#o-04-encodereceiverpositions-局部格式化中间字符串临时分配优化)
5. [第 110 轮修复复核与测试套件缺口分析](#5-第-110-轮修复复核与测试套件缺口分析)
6. [排期与实施路线建议](#6-排期与实施路线建议)

---

## 1. 执行摘要与问题评级总表

本轮审计以第 110 轮已落地的 9 项修复（N-01、N-02、N-04、N-05、N-06、N-08、N-09、N-10、N-11、N-12）为新基线，对全栈代码及跨端交互逻辑进行了深度推导与端到端状态机核验。

共发现 **13 项** 值得关注的逻辑缺陷、边界隐患与优化空间：

| 编号 | 类别 | 模块 / 路径 | 严重度 | 核心影响简述 |
|---|---|---|:---:|---|
| **L-01** | 逻辑缺陷 | `src/Include/Copier/CopierTransport.mqh:585-608` | **高** | `SendUp` 双发时第 1 份 payload 发送失败且空帧补齐失败后，未中断循环而直接 `continue` 进入第 2 份发送，导致在残破多帧流上拼接新消息，产生畸变帧并误报成功 |
| **L-02** | 逻辑缺陷 | `src/Experts/CopierReceiver.mq4:1051-1150` | **高** | `g_uidPeakLots` 全局容量仅 2048；多 Sender 合计超过 2048 活跃 UID 时表满且无法淘汰，`GetOrUpdateSenderPeakLots` 降级为返回当前 lots，FIXED 比例减仓静默失效 |
| **L-03** | 精度隐患 | `src/Include/Copier/CopierModel.mqh:1245, 1303` | **中高** | 部分平仓守卫采用硬编码 `lots >= have - 0.0000001`，对于 8 位小数（如加密货币/微型碎股 0.00000020 手）部分平仓判定发生误拦截（报 -3 拒单） |
| **L-04** | 状态竞态 | `src/Include/Copier/CopierModel.mqh:258-270` | **中高** | MT4 `OrdersHistoryTotal()` 在启动/重连后历史加载完成前返回 0，`CopierRealizedToday` 返回 `outOk=true`，导致盘中重启冷启动误将早盘亏损归零抹除 |
| **L-05** | 并发一致性 | `hub/src/commands.rs:485-530`, `config.rs:298-330` | **中高** | `replace_all()` 在 Windows 原子替换过程中三次释放/重新获取全局锁，窗口期内并发 `ack()` 遭遇 `inner.file=None` 写入失败，API 查询看到旧命令状态 |
| **M-01** | 协议冗余 | `src/Include/Copier/CopierTransport.mqh:441-456` | **中** | libzmq XSUB 在 `connect(ep)` 时底层自动向新管道重放订阅树；MQL 侧额外循环发送 `\x01` 导致全网 Hub 收到双倍订阅递增，退订帧数膨胀 |
| **M-02** | 接口规范 | `hub/src/api.rs:2233, 2384, 4135...` | **中** | Standby 上拦截写操作端点返回的 JSON 仅有 `error`，缺少 N-02 在命令端点统一的 `primary` URL 与 `detail` 引导字段，造成客户端解析不统一 |
| **M-03** | 内存驻留 | `src/Experts/CopierReceiver.mq4:6478-6490` | **中低** | `StopsPrune` 回收尾部条目时未执行 `g_stUid[last] = ""`，导致被淘汰 UID 的 MQL 字符串引用残留在已缩容数组末尾，形成隐性内存引用驻留 |
| **M-04** | 性能隐患 | `src/Experts/CopierReceiver.mq4:6402-6466` | **中低** | 止损覆盖表容量达 2048 且全部处于 active 状态时，后续每个 `MODIFY` 事件都会触发一次 O(Desired + Acct) 的全量修剪并淘汰 0 条，主线程高频空转 |
| **O-01** | 性能优化 | `src/Experts/CopierReceiver.mq4:1677-1790` | **低中** | `SerializeCurrentConfigToIni` 单 Sender 块内 60 次 `+=` 产生 90KB 复制，100 Sender 叠加大规模符号映射嵌套循环（10,000 次探测），可做块内直推与映射索引 |
| **O-02** | 性能优化 | `src/Experts/CopierReceiver.mq4:1065-1077` | **低中** | `PeakFind` 直接映射哈希碰撞时后写覆盖，两冲突 UID 频繁访问时交替将对方挤出缓存，持续退化为 O(N) 线性扫描 |
| **O-03** | 吞吐优化 | `src/Experts/CopierReceiver.mq4:8740-8790` | **低** | 100 Sender 规模下 `CP_DRAIN_MAX=32` 每 tick 排空上限偏小，订单执行阻塞（如券商 150ms 延迟）后积压在 OS ZMQ 缓冲区中的快照需多 tick 消化 |
| **O-04** | 内存开销 | `src/Experts/CopierReceiver.mq4:5048-5060` | **低** | `EncodeReceiverPositions` 组装行时 12 次字符串相加产生 11 个临时对象，可利用 `CopierStrBuilder` 流式输出降低 GC 压力 |

---

## 2. 关键逻辑错误与隐患详解

### L-01: `SendUp` 双发遇破帧清理失败时 `continue` 导致后续帧二次污染与误报成功

**源码定位**：`src/Include/Copier/CopierTransport.mqh:581-609`

```mql4
int copies=(m_connectedHubs>1) ? 2 : 1;
int sent=0;
for(int i=0;i<copies;i++)
  {
   if(!m_sub.sendMore(topic,true)) { m_errno=CopierZmqErrno(); continue; }
   if(!m_sub.send(payload,true))
     {
      m_errno=CopierZmqErrno();
      if(!m_sub.send("",true))
        {
         m_midMultipart=true;   // 已经标记中途损坏
        }
      continue;                 // <-- 隐患：继续进入 i=1 的循环体！
     }
   sent++;
  }
return (sent>0);
```

**逻辑推导**：
1. 当连接到双 Hub（`m_connectedHubs > 1`，`copies = 2`）时，系统设计通过 `for` 循环发送两次以覆盖两个物理管道。
2. 假设在第 1 次迭代（`i = 0`）：
   - `sendMore(topic, true)` 发送成功，套接字处于 `ZMQ_SNDMORE` 状态，等待 Payload 帧完成闭合；
   - `send(payload, true)` 遭遇缓冲区满（EAGAIN），发送失败；
   - 代码尝试使用 `m_sub.send("", true)` 紧急发送空帧以闭合该 multipart 消息；
   - 此时若底层套接字仍然不可写，空帧发送也返回 `false`，代码正确地将 `m_midMultipart = true` 置位。
3. **致命逻辑跳转**：置位之后执行了 `continue`，循环推进到第 2 次迭代（`i = 1`）！
4. 在 `i = 1` 中，循环直接调用 `m_sub.sendMore(topic, true)`：
   - 此时底层管道仍残留着 `i = 0` 没能闭合的多帧残局；
   - `i = 1` 的 `topic` 被直接作为 **第 3 帧** 追加在上一条残破消息之后；
   - 随后 `send(payload, true)` 发送了 **第 4 帧**；
   - 接收端（Hub）将收到畸变消息 `[topic_0, topic_1, payload_1]`：Hub 的协议解析器把 `topic_1` 当作 Payload 解析，必然报协议损坏；
5. 更严重的是，`i = 1` 若发送成功，`sent++` 变为 1，函数末尾 `return (sent > 0)` 竟然向调用方（如 `SendCfgAck`、`HubAnnounce`）返回 **`true`（成功）**！
6. 调用端以为控制帧已可靠送达，而实际上送出的是一串格式损坏的废帧。

**修复方案**：
一旦尝试补发空帧失败（`!m_sub.send("", true)`），套接字已彻底锁定在未闭合残局中，本次函数调用决不能再往同一套接字写入任何新帧，必须立即 `break` 中断循环并返回 `false`：

```mql4
if(!m_sub.send(payload,true))
  {
   m_errno=CopierZmqErrno();
   if(!m_sub.send("",true))
     {
      m_midMultipart=true;
      break; // 必须立即中止循环，防止 i=1 破坏帧序列
     }
   continue;
  }
```

---

### L-02: `g_uidPeakLots` 全局单表容量耗尽致多 Sender 场景下 FIXED 比例减仓静默失效

**源码定位**：
- `src/Experts/CopierReceiver.mq4:1051`：`CopierUidPeakLots g_uidPeakLots[CP_MAX_POSITIONS];`
- `src/Experts/CopierReceiver.mq4:1137-1150`：`GetOrUpdateSenderPeakLots`
- `src/Experts/CopierReceiver.mq4:4086-4108`：`ComputeTargetLotsForMirror`

**逻辑推导**：
1. 系统的整体容量规格为：每个 Receiver 支持最多 `CP_MAX_SENDERS = 100` 个信号源，每个信号源各自拥有 `CP_MAX_POSITIONS = 2048` 的持仓容量空间（`g_desired` 数组大小为 `100 * 2048`）。
2. 但记录信号源开仓原始手数的 `g_uidPeakLots` 却是一个 **全局仅 2048 槽位** 的单表，并非按 Sender 分片，也不是按总容量设计。
3. 当部署多个活跃交易的 Sender 时，例如：
   - Sender 0 当前持有 1100 张订单；
   - Sender 1 当前持有 1000 张订单；
   - 两者活跃 UID 之和达到 2100，超过了 2048 容量。
4. 此时处理新 UID 时调用 `GetOrUpdateSenderPeakLots(uid, curLots)`：
   - 表满触发 `PruneSenderPeakLots()`；
   - `PruneSenderPeakLots` 遍历所有 Sender 的 `g_desired` 及本地 `g_acctAllPos`，发现这 2048 个 UID 全都处于存活状态，**无法释放任何一个槽位**；
   - 紧接着代码进入 fallback 分支：
     ```mql4
     if(g_uidPeakLotsCount<CP_MAX_POSITIONS) { ... }
     return curLots; // 静默降级：无法记录峰值，直接返回当前快照的手数
     ```
5. 当被降级的订单在 Sender 端发生部分平仓（例如由 2.00 手减仓至 1.00 手）：
   - Receiver 收到新快照，调用 `ComputeTargetLotsForMirror`；
   - FIXED 模式计算目标仓位：
     ```mql4
     double origLots = GetOrUpdateSenderPeakLots(desired.uid, desired.lots);
     // 此时 origLots 返回的是当前的 desired.lots (1.00)，而不是初始的 2.00！
     if(origLots>0.0 && desired.lots<origLots)
       {
        targetLots=baseLots*(desired.lots/origLots);
       }
     ```
   - 因为 `origLots == desired.lots`，`desired.lots < origLots` 条件**恒为假**！
   - 目标手数 `targetLots` 保持 `baseLots` 不变（仍为 0.50 手，未能缩减到 0.25 手）；
   - **后果**：接收端持仓手数相对发送端凭空重了一倍，且全程没有任何报警与日志。

**建议方案**：
- 结构性重构：将峰值/初始手数存入 `g_desired` 行结构中，或按 Sender 分片：`g_uidPeakLots[si * CP_MAX_POSITIONS + slot]`；
- 容错兜底：当 `g_uidPeakLotsCount >= CP_MAX_POSITIONS` 且修剪无法腾出空间时，至少使用 `CopierOnceLog` 输出一次 `Error` 级警报，并向遥测状态上报，杜绝静默失效。

---

### L-03: `CopierClosePartial` 硬编码 `1e-7` 浮点阈值与 8 位小数手数精度不匹配

**源码定位**：
- `src/Include/Copier/CopierDefs.mqh:26`：`#define CP_DIGITS_LOTS 8`
- `src/Include/Copier/CopierModel.mqh:1245`（MT5 平台）：`if(lots>=have-0.0000001) { outErr=-3; return false; }`
- `src/Include/Copier/CopierModel.mqh:1303`（MT4 平台）：`if(lots>=have-0.0000001) { outErr=-3; return false; }`

**逻辑推导**：
1. 全系统对于交易手数的精度定义是 8 位小数（`CP_DIGITS_LOTS = 8`），以原生支持加密货币（BTC/ETH 常见 0.00001 或 0.00000001 手）及碎股交易。
2. 在平仓执行模块中，为了防止误将“部分平仓”当成“全平”，代码设置了守卫判断：如果欲平手数 `lots` 大于等于现有持仓手数 `have`，则判定为全平操作，在此处拒绝（`outErr = -3`），要求调用方走标准全平通道。
3. 但判断阈值采用的是硬编码的 `have - 0.0000001`（即 $10^{-7}$）：
   - 设某加密货币持仓 `have = 0.00000020` 手；
   - 交易员执行减半平仓，欲平 `lots = 0.00000010` 手；
   - 临界值 `have - 0.0000001 = 0.00000010`；
   - 判断表达式 `lots >= have - 0.0000001` 成立（$10^{-7} \ge 10^{-7}$）；
   - `CopierClosePartial` 立即判定非法并拒绝平仓（`outErr = -3`）！
4. 此外，IEEE 754 双精度浮点在第 7、8 位小数做减法时极易产生微小舍入误差，导致微型手数的合法部分平仓被概率性误拦截。

**建议方案**：
守卫应以交易品种的实际 `si.lotStep` 或最小交易量 `si.minLot` 为基准判定剩余仓位是否合法，或者将浮点容差调整为 $10^{-9}$（小于 8 位最小步进）：

```mql4
double remain = have - lots;
if(NormalizeDouble(remain, CP_DIGITS_LOTS) <= 0.0)
  {
   outErr = -3; // 剩余手数为0，确系全平
   return false;
  }
```

---

### L-04: MT4 `CopierRealizedToday` 异步历史就绪竞态导致盘中冷启动误锁零亏损基线

**源码定位**：
- `src/Include/Copier/CopierModel.mqh:258-268`
- `src/Experts/CopierReceiver.mq4:5178-5206`（`RefreshRisk` 冷启动处理）

**逻辑推导**：
1. 在 MT5 平台中，`CopierRealizedToday` 调用平台 API `HistorySelect(from, to)`。若终端历史尚未同步完成，该函数返回 `false`，代码正确地将 `outOk = false` 返回给外层。外层据此保持 `g_riskDayStartEquity = 0.0`，在下一个 tick 持续重试，直到历史加载就绪。
2. 但在 MT4 平台分支（`:258-268`）：
   ```mql4
   int total=OrdersHistoryTotal();
   for(int i=0;i<total;i++) { ... }
   return sum; // outOk 始终默认为 true！
   ```
3. 在 MT4 终端启动、重启或网络重连的瞬间，终端的平仓历史订单数据库是由后台线程从券商服务器异步拉取的。在拉取完成前的那几百毫秒至数秒内，`OrdersHistoryTotal()` 立即返回 **0**。
4. 此时接收端 EA 刚挂载（`wasColdStart = true`）：
   - `CopierRealizedToday` 读出 `total = 0`，算出 `realized = 0.0`，返回 `rOk = true`；
   - `RefreshRisk` 误信了此结果，计算日初基准：
     `trueStartBal = curBal - realized = curBal - 0.0 = curBal`；
   - 随即将当前余额锁定为日初基线：`g_riskDayStartBalance = curBal`、`g_riskDayStartEquity = curBal`；
   - 标志位 `wasColdStart` 变为 `false`，冷启动流程结束。
5. **灾难场景**：
   - 假设账户早盘已经发生了 $2,000 的实际亏损（日初 $10,000，此时余额仅剩 $8,000）；
   - EA 在此时重启，由于 MT4 历史异步竞态，日初基线被错误锁定在 $8,000；
   - 系统的日内最大回撤与最大亏损风控守卫（`dailyLossPct`）将在接下来的全天交易中**彻底赦免早盘发生的 $2,000 亏损**；
   - 违反了项目备忘中关于“盘中重启不得原谅早盘亏损”的交易安全核心铁律。

**建议方案**：
在 MT4 下，当 `OrdersHistoryTotal() == 0` 时，若终端当前还未与服务器建立稳定连接（`!IsConnected()`），或者启动耗时小于安全历史预热时间（例如挂载前 3 秒且订单池为空），不可盲目标记 `outOk = true`，应将其标记为 `outOk = false`，强制等待历史订单池就绪后再计算日初基准。

---

### L-05: Rust Hub `replace_all()` 重建日志时多重释放锁导致并发请求读写空句柄与脏状态

**源码定位**：
- `hub/src/commands.rs:485-530`
- `hub/src/config.rs:298-330`

**逻辑推导**：
以 `hub/src/commands.rs` 中的 `replace_all` 为例：

```rust
// 第 1 处锁释放：释放文件句柄供 Windows 替换
{
    let mut inner = self.inner.lock_or_recover();
    inner.file = None; 
}
let replace_res = crate::cluster::atomic_replace_file(&tmp, &self.path);
let file = OpenOptions::new().create(true).append(true).open(&self.path)?;

// 第 2 处锁释放：写回新打开的文件句柄
{
    let mut inner = self.inner.lock_or_recover();
    inner.file = Some(file);
}
replace_res?;
// 在没有持锁的情况下从磁盘全量 load
let (mut commands, seq, torn, line_count, max_seq) = load(&self.path)?;

// 第 3 处锁：更新内存数据结构
let mut inner = self.inner.lock_or_recover();
inner.commands = std::mem::take(&mut commands);
...
```

1. **第 1 个空窗期**（第 1 次释放后至第 2 次获取前）：
   - `inner.file` 为 `None`；
   - 此时若有节点 ACK 消息到达，调用 `self.ack(id, ...)`；
   - `ack()` 尝试调用 `inner.append()`，发现 `file.is_none()`，立即返回 `false` 并打印 `COMMAND JOURNAL WRITE FAILED`；
   - 虽然第 110 轮修复了 N-09（写盘失败保留 pending），但这次本该成功的确认被直接中断并推入错误重试阶梯。
2. **第 2 个空窗期**（第 2 次释放后至第 3 次获取前）：
   - `inner.file` 已经指向了新文件，但 `inner.commands` 内存哈希表、`inner.seq`、`inner.line_count` 仍然是旧状态；
   - 此时从外部调用 `/api/v1/commands` 或 `/stats`，读到的内存视图与磁盘物理文件处于撕裂不一致状态。
3. 虽然该函数只在 Standby 节点的全量同步时执行，但 HA 容灾切换过程中如果主备切换与重同步重叠，会带来不可预测的命令状态跳变。

**建议方案**：
在 `CommandStore` 内部引入读写门禁或换代标记（`is_resyncing`），在文件替换与全量重新加载完成前，阻塞或优雅排队其他并发请求，而不是在半就绪状态下多次开放锁。

---

## 3. 架构与协议一致性问题

### M-01: `ConnectExtraHub` 手动重放订阅与 libzmq XSUB 自动重放叠加导致引用计数虚高

**源码定位**：`src/Include/Copier/CopierTransport.mqh:435-456`

```mql4
if(!m_sub.connect(ep)) return false;
m_connectedHubs++;
for(int i=0;i<m_nSubPrefixes;i++)
  {
   if(StringLen(m_subPrefixes[i])>0)
     {
      if(m_sub.send("\x01"+m_subPrefixes[i],true))
         m_subSent[i]++;
     }
  }
```

**机理解析**：
- 根据 ZeroMQ 官方设计规范及 libzmq 源码（`xsub_t::xattach_pipe`）：当 XSUB 套接字连接到一个新的端点（新建管道）时，**libzmq 内核会自动把当前套接字维护的整个订阅字典树（`_subscriptions` trie）完整重放到新建管道上**；
- 也就是说，新建的 `ep` 管道在握手建立的瞬间，就已经自动收到了各前缀的第 1 次 `0x01` 订阅帧；
- 随后，MQL 的 `ConnectExtraHub` 循环又显式发送了一次 `m_sub.send("\x01"+...)`；
- 在 XSUB 套接字上调用 `send` 会将该订阅帧向底层**所有管道广播**（管道 1 和管道 2 都会再收一份），同时 `m_subSent[i]++` 累加到了 2；
- 这导致：
  1. 远端 Hub 端维持的订阅者引用计数被人工翻倍；
  2. 当后续执行 `Unsubscribe` 时，由于 `m_subSent[i] == 2`，必须连续发送两个 `0x00` 帧才能彻底注销；
  3. 虽然两两相抵，但在连接建立与退订期间产生了完全冗余的 ZMQ 控制帧流量，并在网络丢包边缘造成不对称计数的风险。

---

### M-02: Standby 备机变更高危 API 端点返回格式与只读命令拦截提示不一致

**源码定位**：`hub/src/api.rs:2233, 2384, 4135, 4268, 4305, 4341, 4384`

**问题比对**：
第 110 轮修复 N-02 时，将 `post_command` 与 `commands_global` 在 Standby 上的 409 拦截响应升级为具备可自愈指导意义的格式：

```rust
// post_command / commands_global 的规范响应
Json(json!({
    "error": "Standby node does not dispatch commands (read-only queries included).",
    "detail": hint,
    "primary": peer_url,
}))
```

然而，在 `api.rs` 的其他所有数据修改端点（配置更新 `put_config`、配置回滚 `rollback_config`、用户管理 `post_user`/`put_user`/`delete_user`、告警渠道 `post_channel`/`delete_channel`）中，拦截返回仍然停留在旧的简单结构：

```rust
// 其他修改端点的响应
Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." }))
```

**影响**：
前端 Web 控制台或第三方集成脚本在捕获到 409 错误时，需要针对两套不同的 JSON 响应分支做兼容处理；且当用户在 Standby 控制台上误操作修改用户或配置时，系统无法向其展示当前可用的 Primary Hub 重定向链接（缺少 `primary` 键）。

---

### M-03: `StopsPrune` 紧缩删除尾部槽位未清空字符串引用引发内存驻留

**源码定位**：`src/Experts/CopierReceiver.mq4:6478-6490`

```mql4
int last=g_stCount-1;
if(i!=last)
  {
   g_stUid[i]=g_stUid[last];
   g_stHasOv[i]=g_stHasOv[last];
   g_stOvSl[i]=g_stOvSl[last];
   g_stOvTp[i]=g_stOvTp[last];
   g_stOvOpn[i]=g_stOvOpn[last];
   g_stOvPprice[i]=g_stOvPprice[last];
   g_stLastMs[i]=g_stLastMs[last];
  }
g_stCount--;
pruned++;
// 缺少：g_stUid[last] = "";
```

**问题分析**：
- MQL4/MQL5 中 `string` 数组元素持有对平台内部字符串池对象的引用计数；
- 当把 `last` 槽位的数据移动覆盖到 `i` 槽位并将有效长度 `g_stCount--` 扣减后，`g_stUid[last]` 仍然保留着原先的字符串内容；
- 对比 `PruneSenderPeakLots`（`:1117`），那里规范地执行了 `for(int k=writeIdx;k<oldPeakCount;k++) g_uidPeakLots[k].uid="";`；
- `StopsPrune` 漏掉了尾部清空，在 2048 规模的账户长期运行下，被平仓淘汰的陈旧 UID 字符串将持续驻留在 MQL 运行时的内存堆中，直到有新记录覆盖。

---

### M-04: `StopsPrune` 在活跃移动止损满表下每事件全量扫描引发的主线程抖动

**源码定位**：`src/Experts/CopierReceiver.mq4:6402-6466`

**推导过程**：
1. `StopsOvIndex(uid, true)` 是处理每个 `MODIFY` 事件（止损更新）的热路径；
2. 当持仓量极大且多 Sender 活跃（例如已有 2048 个持仓设置了移动止损，`g_stCount == CP_MAX_STOPS_OV == 2048`）：
3. 当收到一个新 UID 的 MODIFY 时：
   - 触发 `StopsPrune(CopierNowMs())`；
   - `StopsPrune` 遍历所有 Sender 的 desired 列表（2048 项）和账户持仓列表（2048 项），并将 2048 个条目的 `s_isOvAlive` 全数置为 `true`；
   - 随后的修剪循环无法淘汰任何一条（`pruned == 0`）；
   - 函数退出后，`g_stCount` 仍然等于 2048，无法容纳新 UID，打一条 `stopsovfull` 警告并丢弃事件。
4. **性能雪崩**：如果行情处于剧烈波动期，新 UID 事件持续进入，**每一个事件都会引发一次无功的全量 O(Desired + Acct) 双层遍历**；
5. 在 4 Hz 的事件冲击下，这会在 EA 主线程造成每秒数千次无意义的数组遍历，严重推迟下一个 tick 的执行节拍。

---

## 4. 性能与内存优化空间

### O-01: `SerializeCurrentConfigToIni` 块内字符串累加与多映射双重循环优化

**源码定位**：`src/Experts/CopierReceiver.mq4:1736-1787`

**现状**：
函数内虽然在 Sender 块外部使用了 `sb.Add(out)`，但在每个 Sender 内部仍有约 60 次 `out += ...` 累加：
1. 每次 `out +=` 都会在 MQL 堆中重新分配字符串并拷贝之前的内容，单个 Sender 块内累积产生约 90 KB 的无效内存拷贝；100 个 Sender 即达约 9 MB；
2. 符号映射部分：
   ```mql4
   for(int m = 0; m < g_nMap; m++)
     {
      if(g_mapSender[m] == i)
         out += "symbol." + g_mapFrom[m] + "=" + g_mapTo[m] + "\n";
     }
   ```
   如果有 100 个符号映射和 100 个 Sender，这个双重嵌套循环将在 EA 主线程空转 10,000 次比较。

**优化方案**：
- 块内直接调用 `sb.Add(...)` 单行追加，彻底消除块内的 O(n²) 字符串复制；
- 符号映射表预先按照 Sender 归类或记录偏移区间，使映射输出由 O(Senders × Maps) 降为 O(Maps)。

---

### O-02: `PeakFind` 直接映射哈希碰撞覆盖引发的 O(N) 线性退化与乒乓震荡

**源码定位**：`src/Experts/CopierReceiver.mq4:1065-1077`

```mql4
int PeakFind(const string uid)
  {
   if(StringLen(uid)==0) return -1;
   int h=(int)(CopierHash32(uid)&(CP_PEAK_LOOKUP-1));
   int c=g_peakLookup[h];
   if(c>0 && c<=g_uidPeakLotsCount && g_uidPeakLots[c-1].uid==uid) return c-1;
   for(int i=0;i<g_uidPeakLotsCount;i++)
     {
      if(g_uidPeakLots[i].uid!=uid) continue;
      g_peakLookup[h]=i+1; // 发生碰撞时直接覆盖
      return i;
     }
   return -1;
  }
```

**机理解析**：
- `CP_PEAK_LOOKUP = 4096`，采用直接映射（Direct-Mapped Cache）；
- 当有两个存活的 UID（例如 $UID_A$ 与 $UID_B$）其哈希值对 4096 取模相同（生日悖论下，在数百个 UID 规模时极易发生）：
  - 查 $UID_A$：Cache Miss，走 O(N) 循环找到，将 `g_peakLookup[h] = pos_A` 写入覆盖；
  - 随后查 $UID_B$：由于被 $UID_A$ 覆盖，Cache Miss，走 O(N) 循环找到，又将 `g_peakLookup[h] = pos_B` 覆盖；
  - 在随后的每次快照对账中，$UID_A$ 与 $UID_B$ 互相踩踏缓存，导致每一次查找都退化为 O(N) 线性遍历。

**优化方案**：
引入带开放寻址（Open Addressing）或线性探测的 2-way 槽位，或者像 `CopierUidIndex` 那样在碰撞时探测下一个空位，消除缓存行乒乓覆盖。

---

### O-03: 100-Sender 突发快照下 ZMQ 接收队列排空上限与端到端延迟控制

**源码定位**：`src/Experts/CopierReceiver.mq4:8740-8790`，`src/Include/Copier/CopierDefs.mqh:245`

**现状**：
- `CP_DRAIN_MAX` 默认为 32；
- 在 100 个 Sender 同时挂载、市场开盘或重连恢复时，各 Sender 几乎在同一秒内向 Hub 投递全量快照，Hub 随之广播；
- 接收端在单次 `OnTimer` 中最多仅提取 32 条帧；
- 剩余的 68 帧被迫积压在底层 ZeroMQ 的 TCP/IPC 套接字接收缓冲区中，需要经过 3~4 个定时器周期才能被应用层全部消费；
- 如果期间穿插了一次耗时 100ms 的券商开仓调用，队列尾部的快照延迟将达到数百毫秒。

**优化方案**：
将 `CP_DRAIN_MAX` 适度提至 128（完全匹配 100 Sender 满配规模单次排空需求），且 `DrainFrames` 已使用轻量栈内临时结构，128 帧排空耗时不超过 0.3ms。

---

### O-04: `EncodeReceiverPositions` 局部格式化中间字符串临时分配优化

**源码定位**：`src/Experts/CopierReceiver.mq4:5048-5060`

**现状**：
在构造发送给 Hub 的持仓遥测时：
```mql4
rec = p.uid + "," + (string)p.ticket + "," + sym + "," + (string)p.side + ","
      + CopierFmtDouble(p.lots, 8) + "," + CopierFmtDouble(p.openPx, 8) + ","
      + CopierFmtDouble(p.sl, 8) + "," + CopierFmtDouble(p.tp, 8) + ","
      + (string)p.magic + "," + (string)p.openTime;
```
每行单条记录通过 12 次 `+` 拼接，产生 11 个 MQL 临时字符串对象。在 2048 个持仓的满仓账户中，单次上报会制造超过 22,000 个瞬时小字符串对象。

**优化方案**：
利用已有的 `CopierStrBuilder` 的流式追加特性，或在循环外部预留行缓冲区，直接进行字段拼接，避免高频触发 MQL 底层的内存分配器。

---

## 5. 第 110 轮修复复核与测试套件缺口分析

### 5.1 第 110 轮修复复核结论

经对当前工作区代码进行完整语义审查与编译测试，第 110 轮落地的 9 项改动复核结果如下：

| 原编号 | 修复内容 | 验证结论 |
|---|---|:---:|
| **N-01** | `CopierTransport::Subscribe` 幂等发送与 `m_subSent` 计数退订 | **有效**，但发现其在 `ConnectExtraHub` 中与 libzmq 底层自动重放存在轻度冗余（见 M-01） |
| **N-02** | Standby 节点对只读命令与全网命令统一返回 409 Conflict | **有效**，消除空转命令；残余为错误 JSON 结构缺少统一的 Primary 提示（见 M-02） |
| **N-04** | 止损覆盖表容量 `CP_MAX_STOPS_OV` 扩容至 2048 并引入 `InsertString` | **有效**，解决了 512 阈值截断问题；残余为尾部清理漏写（见 M-03）与满表空转（见 M-04） |
| **N-05** | `receiver_ok` 放行条件增加 60 秒 warm 窗口限制 | **有效**，成功关闭了新 Hub 启动时的反射注入面 |
| **N-06** | 增加 `CP_REG_REFRESH_HBTS=12` 周期性维护注册帧 | **有效**，双 Hub 单边丢包可在 60 秒内通过心跳自动愈合 |
| **N-08** | MQL 侧新增 `CopierUtf8Bytes()`，配置校验改为 UTF-8 字节比较 | **有效**，与 Rust Hub 端的 `ini.len()` 字节口径完全对齐 |
| **N-09** | `CommandStore::ack()` 改为先落盘再推进内存状态 | **有效**，新增的 Rust 单元测试通过 |
| **N-10** | `PushAction` 新增 `g_pushReject` 细分拒绝原因 | **有效**，命令确认回执不再误报 `queue_full` |
| **N-11** | `g_everOpened` TTL 提升至 7 天（`CP_EVEROPENED_TTL_MS`） | **有效**，跨周末手动平仓单不再被误判为首次入场 |
| **N-12** | 日志由每行 flush 改为每 tick flush，ERROR 保持即时刷盘 | **有效**，74 单突发交易不再造成 CRT 磁盘刷盘风暴 |

---

### 5.2 测试套件缺口 (Test Suite Gaps)

当前测试套件（Rust 172 项单元测试全绿、Python 核心套件覆盖良好）在以下场景存在测试空白：

1. **破帧清理失败后的容错测试 (L-01)**：
   - 现有的 `tools/zmq_bidir_test.py` 仅测试了正常情况下的双发往返，缺少“模拟底层管道阻塞导致首份 Payload 失败且后续帧连续发送”的畸变多帧检测。
2. **多 Sender 场景下峰值手数满表测试 (L-02)**：
   - `CopierSelfTest.mq4` 中的 `TestSizing()` 仅测试了单一 Sender、少量订单的比例减仓，未构造总 UID 超过 2048 的边界用例。
3. **8 位小数手数的微型部分平仓测试 (L-03)**：
   - `CopierSelfTest.mq4` 缺少对手数小于 $10^{-6}$（如 0.00000010 手）的 `CopierClosePartial` 边界断言。
4. **非 ASCII 中文字符配置的端到端超限测试 (N-08 / T-02)**：
   - `tools/hub_config_test.py` 现有用例全为纯 ASCII 配置，缺少含大量中文注释且总大小在 512 KB 临界点时的双端同时拒绝测试。

---

## 6. 排期与实施路线建议

鉴于用户要求“**先不要动手改，列出来供审阅**”，后续修复建议按以下三个批次进行，兼顾交易安全性与系统稳定性：

```mermaid
flowchart TD
    A["第一批次：交易与传输安全核心修复"] --> B["第二批次：架构一致性与接口规范"]
    B --> C["第三批次：性能精细化与测试补齐"]

    subgraph Phase1 ["第一批次：紧急交易安全 (High Priority)"]
        A1["L-01: SendUp 破帧清理失败立即 break"]
        A2["L-03: CopierClosePartial 浮点守卫改为 1e-9 / 步进判定"]
        A3["L-04: MT4 CopierRealizedToday 历史未加载完成前返回 outOk=false"]
    end

    subgraph Phase2 ["第二批次：架构与容量对齐 (Medium Priority)"]
        B1["L-02: g_uidPeakLots 结构分片或按 Sender 隔离扩容"]
        B2["M-01: ConnectExtraHub 移除冗余的 \x01 手动重发"]
        B3["M-02: api.rs 统一 Standby 409 拦截响应结构 (primary/detail)"]
        B4["M-03: StopsPrune 补充尾部槽位 g_stUid[last] = '' 清理"]
    end

    subgraph Phase3 ["第三批次：性能与测试套件完善 (Low-Medium Priority)"]
        C1["O-01: SerializeCurrentConfigToIni 块内线性直推"]
        C2["O-02: PeakFind 缓存冲突探测优化"]
        C3["O-03: CP_DRAIN_MAX 扩容至 128"]
        C4["补齐 L-01/L-02/L-03/N-08 的单测与 Python 回归断言"]
    end
```

### 实施准则总结
1. **交易安全为第一优先级**：L-01（防止向 Hub 广播损坏控制帧）与 L-03（防止加密货币部分平仓误拒单）改动极小、风险极低，应在确认后第一批落地；
2. **大容量多 Sender 隔离**：L-02 涉及 `g_desired` 行内携带初始手数（`initLots`）或分片存储，需要在离线编译与环境确认后严谨修改；
3. **保持端到端零回归**：任何 MQL 修改须在临时 staging 目录完成 6 个目标（MT4/MT5 × Sender/Receiver/SelfTest）的零错零警编译验证，Rust 端须保持 172 项单元测试 100% 通过。

---
*报告生成完毕。文件已安全持久化至 `mt-copier/outputs/mt-copier-fullstack-audit-2026-11-07-r2.md`。*
