# mt-copier 全栈深度代码审计与系统优化评估报告（2026-11-08 / 最新全量基线版）

> **审计执行模式**：严格只读（Strictly Read-Only）。未修改任何生产代码、配置文件或运行环境。  
> **审计基线**：Git `HEAD = 9e31b29`（已合并第 112 轮 `e929d2a` 及后续防爆锤防线 `6b9a4da`, `71bbeb0`, `6979adf`, `9e31b29`）。  
> **审查范围**：
> 1. **MQL 客户端与 Include 核心库**（`src/Include/Copier/*.mqh` 全量 17 个核心头文件、`src/Experts/CopierSender.mq4`、`src/Experts/CopierReceiver.mq4`、`src/Scripts/CopierSelfTest.mq4` 等全量源码）。
> 2. **Rust Hub 核心中枢与内置测试套件**（`hub/src/*.rs` 全量模块、173 项测试用例、HA 双活集群同步、命令重试引擎、API 路由、ZeroMQ 转发链路）。
> 3. **全栈协议与测试门禁**（`doc/PROTOCOL.md`、`doc/HANDOFF.md`、`doc/CENTRAL-HUB-HA-FINAL-PLAN.md`、720 项 MQL 自动化自检断言）。
>
> **输出文件**：本报告已保存至 `mt-copier/outputs/mt-copier-fullstack-audit-2026-11-08.md`，可供操作员与开发者直接下载审阅。

---

## 目录

1. [执行摘要与问题评级总表](#1-执行摘要与问题评级总表)
2. [严重逻辑缺陷与交易安全隐患 (Critical & High Logic Errors)](#2-严重逻辑缺陷与交易安全隐患)
   - [BUG-01【严重·防爆锤失效】`OnTick()` 任意行情跳动彻底清零队列退避阶梯，导致被拒订单高频轰炸券商](#bug-01严重防爆锤失效ontick-任意行情跳动彻底清零队列退避阶梯导致被拒订单高频轰炸券商)
   - [BUG-02【高危·平仓闭锁】`PushAction` 与 `ExecuteQueue` 中 ticket 退避键误用 `:2:` (CLOSE) 导致改单失败后平仓被阻断](#bug-02高危平仓闭锁pushaction-与-executequeue-中-ticket-退避键误用-2-close-导致改单失败后平仓被阻断)
   - [BUG-03【高危·交易安全】多 Sender 冷启动时 `g_manualClosed` 垃圾回收误将未就绪 Sender 的订单剔除，导致手动平仓单被复活](#bug-03高危交易安全多-sender-冷启动时-g_manualclosed-垃圾回收误将未就绪-sender-的订单剔除导致手动平仓单被复活)
3. [并发一致性与中枢主线程挂起缺陷 (Concurrency & Thread Safety Issues)](#3-并发一致性与中枢主线程挂起缺陷)
   - [BUG-04【中高·并发竞态】Rust Hub `replace_all()` 重复释放锁导致并发命令丢失或报连接中断错误](#bug-04中高并发竞态rust-hub-replace_all-重复释放锁导致并发命令丢失或报连接中断错误)
   - [BUG-05【中·线程阻塞】Rust Hub 数据帧转发采用阻塞式 `send`，慢订阅者或网络背压可致中枢单线程事件循环假死](#bug-05中线程阻塞rust-hub-数据帧转发采用阻塞式-send慢订阅者或网络背压可致中枢单线程事件循环假死)
4. [内存卫生、协议精简与优化空间 (Optimization & Hygiene Opportunities)](#4-内存卫生协议精简与优化空间)
   - [OPT-01【低·协议规范】`CopierPayloadHbt2` 仍冗余发送 `NAME=` 字段，违背每 5 秒精简心跳设计约束](#opt-01低协议规范copierpayloadhbt2-仍冗余发送-name-字段违背每-5-秒精简心跳设计约束)
   - [OPT-02【低·状态卫生】`HandleSnapshot` 紧缩清空行未重置 `initLots` 等数值字段，破坏内存初始化契约](#opt-02低状态卫生handlesnapshot-紧缩清空行未重置-initlots-等数值字段破坏内存初始化契约)
   - [OPT-03【低·健壮性】ZeroMQ 分段异常终结帧缺少 `DONTWAIT` 标记](#opt-03低健壮性zeromq-分段异常终结帧缺少-dontwait-标记)
5. [测试套件盲区分析（为何 720 MQL + 173 Rust 门禁全绿）](#5-测试套件盲区分析)
6. [无损修复代码补丁建议 (Concrete Patch Recommendations)](#6-无损修复代码补丁建议)

---

## 1. 执行摘要与问题评级总表

本轮审计深入追踪了 `master` 分支最新提交（特别是近期的 `6b9a4da`, `71bbeb0`, `9e31b29` 等关于队列退避阶梯与防爆锤机制的改动）。

审计发现，近期为防止频繁请求券商而引入的防爆锤机制与退避优化中，存在**两处影响极为恶劣的逻辑缺陷**（一处导致防爆锤退避在正常行情下被毫秒级秒清，一处导致改单失败后平仓单被误拦截），以及一处多发送源冷启动状态回收竞态，外加 Rust Hub 端的并发锁竞争与阻塞风险。

全栈共检出 **8 项** 缺陷与优化项（严重 1 项、高危 2 项、中高 1 项、中危 1 项、低危/优化 3 项）：

| 编号 | 类别 | 模块与代码路径 | 严重级别 | 核心危害 / 表现简述 |
|---|---|---|:---:|---|
| **BUG-01** | 交易防线 | `src/Experts/CopierReceiver.mq4:9490-9513` | **严重** | `OnTick()` 中 `!SymbolMarketClosed(g_q[idx].sym)` 条件在开盘期间永远为真，导致任何品种来 tick 都会在毫秒级将退避阶梯抹为 0，防爆锤彻底失效 |
| **BUG-02** | 交易安全 | `src/Experts/CopierReceiver.mq4:2980, 3757, 3893` | **高危** | `boKey` 键名拼接误将 `MODIFY` (`5`) 写为 `:2:` (`CP_ACT_CLOSE`)；一旦订单改单失败进入退避，该订单后续的紧急市价平仓将被 `BlockedExit()` 拦截拒执行 |
| **BUG-03** | 状态同步 | `src/Experts/CopierReceiver.mq4:6364-6382` | **高危** | 多 Sender 场景下，Sender 0 快照到达时 Sender 1 尚未建立连接（`!g_ready[1]`），`g_manualClosed` 误以为无 Sender 持有该单，将其提前 GC，Sender 1 上线后该单被误复活 |
| **BUG-04** | 并发一致性 | `hub/src/commands.rs:485-530` | **中高** | `replace_all()` 在写入临时文件、替换、重载过程中 3 次释放 `inner` 互斥锁，并发写入可能报 `NotConnected` 或被随后的全量覆盖抹除 |
| **BUG-05** | 网络性能 | `hub/src/main.rs:2900-2909` | **中** | 数据广播转发使用阻塞式 `sock.send(payload, 0)`；当下游某订阅端套接字写满时，中枢单线程事件循环阻塞，导致心跳超时与集群误判选举 |
| **OPT-01** | 协议精简 | `src/Include/Copier/CopierCodec.mqh:858-862` | **低** | `CopierPayloadHbt2` 复用了 `CopierBuildNodePayload`，每 5 秒仍向 Hub 发送固定不变的 `NAME=` 字符串，与设计文档不符 |
| **OPT-02** | 状态卫生 | `src/Experts/CopierReceiver.mq4:6518-6523` | **低** | `HandleSnapshot` 紧缩清空陈旧行时仅清空了 `uid`/`sym`/`cmt` 字符串，遗漏重置 `initLots = 0.0` 及 `ticket = 0` |
| **OPT-03** | 健壮性 | `hub/src/main.rs:2909` | **低** | 发送多段消息异常时回退的空终止帧 `sock.send("", 0)` 缺少 `zmq::DONTWAIT` 标志 |

---

## 2. 严重逻辑缺陷与交易安全隐患

### BUG-01【严重·防爆锤失效】`OnTick()` 任意行情跳动彻底清零队列退避阶梯，导致被拒订单高频轰炸券商

#### 源码定位
- **调用位置**：`src/Experts/CopierReceiver.mq4:9490-9513`

```mql4
void OnTick()
  {
   // Wake up immediately from market-closed / escalated backoff upon receiving any new tick for our symbols
   if(g_qRetryAtMs>0 && g_qn>0)
     {
      bool hasActionForThisSym=false;
      for(int i=0;i<g_qn;i++)
        {
         int idx=(g_qHead+i)%CP_MAX_ACTIONS;
         if(g_q[idx].sym==_Symbol || !SymbolMarketClosed(g_q[idx].sym))
           {
            hasActionForThisSym=true;
            break;
           }
        }
      if(hasActionForThisSym)
        {
         g_qRetryAtMs=0;
         g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
         g_qSpinPasses=0;
        }
     }
  }
```

#### 缺陷机制深入剖析
1. **设计初衷**：在提交 `6b9a4da` 和 `71bbeb0` 中，系统设计了队列防爆锤阶梯（1s -> 10s -> 60s -> 5m -> 10m -> 30m -> 1h）以及休市 15 分钟长休眠（`backoffMs = 900000`）。`OnTick()` 的初衷是：当休市期间队列被挂起 15 分钟时，一旦市场开市并收到新行情 tick，EA 应当立即唤醒队列，而无需苦等 15 分钟。
2. **致命错误条件**：
   ```mql4
   if(g_q[idx].sym==_Symbol || !SymbolMarketClosed(g_q[idx].sym))
   ```
   - 在正常的交易时间内，只要队列里有任何一个品种属于开市状态，`!SymbolMarketClosed(g_q[idx].sym)` 必然恒等于 `true`！
   - 甚至只要图表绑定的品种 `_Symbol`（例如 EURUSD）收到一笔跳价，即使队列里是一笔因为**保证金不足（Margin Call）、交易被禁用（Trade Disabled）、无效手数（Invalid Lots）或无效止损（Invalid Stops）**而持续失败的挂起动作，`hasActionForThisSym` 也会立刻被判定为 `true`！
3. **连锁灾难反应**：
   - 队列执行失败，`CopierQueueNotePass()` 刚刚将退避时间提升到 10 秒或 60 秒；
   - 仅仅过了 50 毫秒，当前图表收到一笔普通的盘口 tick 跳动，`OnTick()` 被触发；
   - `OnTick()` 立即执行：
     ```mql4
     g_qRetryAtMs=0;
     g_qBackoffMs=CP_Q_BACKOFF_MIN_MS; // 50ms
     g_qSpinPasses=0;
     ```
   - 退避阶梯被完全抹杀！在接下来的 `OnTimer()`（通常 50ms 频率）中，队列立即再次出队该失败动作，再次请求券商，再次失败；然后下一个 tick 再次清空退避……
   - **后果**：整个 Receiver 退化为对券商交易服务器进行毫秒级的疯狂轰炸（Hammering），极易导致跟单账户被券商风控系统当场断开连接、甚至拉黑封号！

#### 修复方案
`OnTick()` 仅应在队列处于**休市挂起状态**（即 `g_qBackoffMs >= 900000`），且**收到 tick 的品种恰好就是队列中被休市阻断的品种**时，才执行针对性唤醒：
```mql4
void OnTick()
  {
   // Only wake up if the queue is currently in a market-closed suspension hold (15 min)
   // and the tick received matches the symbol of an action waiting in the queue.
   if(g_qRetryAtMs>0 && g_qn>0 && g_qBackoffMs>=900000)
     {
      bool hasActionForThisSym=false;
      for(int i=0;i<g_qn;i++)
        {
         int idx=(g_qHead+i)%CP_MAX_ACTIONS;
         if(g_q[idx].sym==_Symbol)
           {
            hasActionForThisSym=true;
            break;
           }
        }
      if(hasActionForThisSym)
        {
         g_qRetryAtMs=0;
         g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
         g_qSpinPasses=0;
        }
     }
  }
```

---

### BUG-02【高危·平仓闭锁】`PushAction` 与 `ExecuteQueue` 中 ticket 退避键误用 `:2:` (CLOSE) 导致改单失败后平仓被阻断

#### 源码定位
- `src/Experts/CopierReceiver.mq4:2980` (`PushAction`)
- `src/Experts/CopierReceiver.mq4:3757` (`ExecuteQueue`)
- `src/Experts/CopierReceiver.mq4:3893` (`ExecuteQueue`)

```mql4
// src/Experts/CopierReceiver.mq4:2978-2982
//--- MODIFY actions lock backoff to the position ticket rather than the full key.
//--- Otherwise micro-price changes in trailing stops generate fresh keys and bypass backoff completely.
string boKey = (kind==CP_ACT_MODIFY && ticket!=0) ? (sname+":2:#t"+(string)ticket) : key;
if(g_backoff.Blocked(boKey)) { g_pushReject="retry_backoff"; return false; }
```

```mql4
// src/Experts/CopierReceiver.mq4:3757-3761
if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
  {
   string sn=SenderLabel(a.senderIdx);
   g_backoff.Clear(sn+":2:#t"+(string)a.ticket);
  }
```

```mql4
// src/Experts/CopierReceiver.mq4:3893
string boKey=(a.kind==CP_ACT_MODIFY && a.ticket!=0) ? (sname+":2:#t"+(string)a.ticket) : a.key;
fails=g_backoff.Note(boKey);
```

#### 缺陷机制深入剖析
1. **常量混淆**：
   在 `CopierDefs.mqh` 中，动作类型定义如下：
   ```mql4
   #define CP_ACT_OPEN   1
   #define CP_ACT_CLOSE  2
   #define CP_ACT_TRIM   3
   #define CP_ACT_DEDUP  4
   #define CP_ACT_MODIFY 5
   ```
   代码作者在引入 `boKey` 时，错误地将 `CP_ACT_MODIFY` 的类型数字硬编码为字面量 `":2:"`，而 `2` 恰恰是 `CP_ACT_CLOSE`！
2. **致命键名冲突**：
   - 当一个本地订单被券商篡改了 Comment，或者属于遗留订单时，系统使用订单 Ticket 生成 UID，形如 `#t12345678`。
   - 当需要平掉这笔订单时，平仓动作的键名为：
     `SenderLabel(si) + ":2:#t" + ticket`（因为 `kind == CP_ACT_CLOSE`，即 2）。
   - 现在，假设该订单在持仓期间，Sender 发来了一次移动止损/止盈（MODIFY），但由于券商的止损距离限制（Freeze Level/Stop Level）或价格失效，导致该 MODIFY 失败。
   - 失败后，系统计算 `boKey = sname + ":2:#t" + ticket`，并调用 `g_backoff.Note(boKey)`，将这个以 `:2:` 命名的键送入退避惩罚阶梯！
3. **平仓闭锁灾难**：
   - 随后，Sender 发出平仓指令（或紧急避险平仓）；
   - Receiver 接收到平仓指令，调用 `PushAction(kind=CP_ACT_CLOSE, uid="#t12345678")`；
   - 在 `PushAction` 的平仓检查中：
     ```mql4
     if(kind==CP_ACT_CLOSE || kind==CP_ACT_TRIM || kind==CP_ACT_DEDUP)
       {
        if(g_backoff.BlockedExit(key)) { g_pushReject="retry_backoff"; return false; }
       }
     ```
   - 这里的 `key` 恰好就是 `sname + ":2:#t" + ticket`！
   - 因为刚才 MODIFY 失败把这个 `:2:` 键打入了退避阶梯，`g_backoff.BlockedExit(key)` 返回 `true`！
   - **后果**：平仓请求被当场判定为 `retry_backoff` 拒绝入队！本该立即市价平仓避险的订单被死死锁在市场中，眼睁睁看着亏损扩大，形成了极其严重的交易安全漏洞！

#### 修复方案
将所有三处硬编码的 `":2:"` 修正为 `":5:"`（或标准化为 `":"+(string)CP_ACT_MODIFY+":"`）：
```mql4
// 2980行:
string boKey = (kind==CP_ACT_MODIFY && ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)ticket) : key;

// 3760行:
g_backoff.Clear(sn+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket);

// 3893行:
string boKey = (a.kind==CP_ACT_MODIFY && a.ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket) : a.key;
```

---

### BUG-03【高危·交易安全】多 Sender 冷启动时 `g_manualClosed` 垃圾回收误将未就绪 Sender 的订单剔除，导致手动平仓单被复活

#### 源码定位
- **调用位置**：`src/Experts/CopierReceiver.mq4:6364-6382`

```mql4
          else
            {
             bool anySenderHolds=false;
             for(int s=0; s<g_nSenders; s++)
               {
                int sbase=s*CP_MAX_POSITIONS;
                for(int d=0; d<g_desiredCount[s]; d++)
                  {
                   if(g_desired[sbase+d].uid==mUid) { anySenderHolds=true; break; }
                  }
                if(anySenderHolds) break;
               }
             if(!anySenderHolds)
               {
                g_log.Info("ManualClosed GC: legacy UID "+mUid+" was closed by operator and no sender holds it. Removed from ignore table.");
                g_manualClosed.RemoveAt(m);
                gcChanged=true;
               }
            }
```

#### 缺陷机制深入剖析
1. **垃圾回收逻辑**：为了防止操作员手动平仓的记录列表（`g_manualClosed`）无限膨胀，系统在 `ConvergeSender()` 中运行 GC：如果某个已被操作员手动平掉的 UID 在所有 Sender 的持仓中都已经不存在了，就将它从黑名单中移除。
2. **多源异步时序竞争**：
   - 假设 Receiver 配置了两个 Sender：`Sender 0` 和 `Sender 1`。
   - 用户之前手动平掉了 `Sender 1` 的一笔订单 `UID_XYZ`（保存在 `cmd_state.txt` 中，未带 SID 前缀）。
   - 客户端重启或重载。
   - `Sender 0` 速度较快，先建立连接并发送了快照，触发 `HandleSnapshot(0)` -> `ConvergeSender(0)`。此时 `g_ready[0] = true`，而 `Sender 1` 还在连接中，`g_ready[1] = false`，因此 `g_desiredCount[1] == 0`。
   - GC 检查 `UID_XYZ`：
     - `Sender 0` 确实没有持仓 `UID_XYZ`；
     - 检查 `Sender 1`：因为 `g_desiredCount[1] == 0`，循环直接结束，`anySenderHolds` 为 `false`！
     - 系统得出错误结论：“没有一个 Sender 持有这笔单！”，当场将 `UID_XYZ` 从 `g_manualClosed` 中彻底抹除！
   - 200 毫秒后，`Sender 1` 成功连上并推来快照，快照里赫然包含 `UID_XYZ`。
   - 当 Receiver 检查时，`UID_XYZ` 已经在几百毫秒前被误当成“死单”清理掉了！
   - **后果**：Receiver 认为这是一笔全新的信号，立即在本地再次开仓！操作员明确手动平掉的仓位被“僵尸复活”！

#### 修复方案
在多源 GC 检查中，若尚有任何一个配置的 Sender **尚未就绪**（`!g_ready[s]`），说明全网持仓尚未完整呈现，必须放弃对该无归属 UID 的回收：
```mql4
          else
            {
             bool anySenderHolds=false;
             bool allSendersReady=true;
             for(int s=0; s<g_nSenders; s++)
               {
                if(!g_ready[s]) { allSendersReady=false; }
                int sbase=s*CP_MAX_POSITIONS;
                for(int d=0; d<g_desiredCount[s]; d++)
                  {
                   if(g_desired[sbase+d].uid==mUid) { anySenderHolds=true; break; }
                  }
                if(anySenderHolds) break;
               }
             if(!anySenderHolds && allSendersReady)
               {
                g_log.Info("ManualClosed GC: legacy UID "+mUid+" was closed by operator and no sender holds it. Removed from ignore table.");
                g_manualClosed.RemoveAt(m);
                gcChanged=true;
               }
            }
```

---

## 3. 并发一致性与中枢主线程挂起缺陷

### BUG-04【中高·并发竞态】Rust Hub `replace_all()` 重复释放锁导致并发命令丢失或报连接中断错误

#### 源码定位
- **调用位置**：`hub/src/commands.rs:485-530`

```rust
    pub fn replace_all(&self, lines: &[String]) -> std::io::Result<usize> {
        if !self.enabled {
            return Ok(0);
        }
        let tmp = format!("{}.tmp.{}", self.path.display(), std::process::id());
        {
            let mut f = File::create(&tmp)?;
            for l in lines {
                f.write_all(l.as_bytes())?;
                f.write_all(b"\n")?;
            }
            f.sync_all()?;
        }
        {
            let mut inner = self.inner.lock_or_recover();
            inner.file = None; // Drop file handle so Windows allows replacing the file
        }
        let replace_res = crate::cluster::atomic_replace_file(std::path::Path::new(&tmp), &self.path);
        // BUG-85-02 & A86-06: Ensure file handle is reopened and report error if reopen fails
        let file = OpenOptions::new().create(true).append(true).open(&self.path)?;
        {
            let mut inner = self.inner.lock_or_recover();
            inner.file = Some(file);
        }
        replace_res?;
        let (mut commands, seq, torn, line_count, max_seq) = load(&self.path)?;
        let now = unix_secs();
        let mut inner = self.inner.lock_or_recover();
        inner.commands = std::mem::take(&mut commands);
        inner.prune_terminal(now, COMMAND_KEEP_SECS);
        inner.seq = seq;
        inner.torn = torn;
        ...
```

#### 缺陷机制深入剖析
1. **锁的反复解开与空档期**：
   - 在第 500 行，为了在 Windows 下解除文件句柄占用以便进行原子替换，锁被短暂获取后将 `inner.file = None`，随即锁被释放！
   - 在第 507 行，文件句柄重新打开并赋值 `inner.file = Some(file)`，锁再次被释放！
   - 在第 510 行，`load(&self.path)` 读取磁盘快照；
   - 在第 513 行，再次获取锁，并执行 `inner.commands = std::mem::take(&mut commands);`。
2. **并发时序灾难**：
   - 在第 500~507 行之间（文件句柄为 `None`）：如果有 HTTP API 线程（如操作员在 Web 控制台下发 `pause`/`resume`/`closeall`）调用 `issue_op()`，底层 `append_many` 检测到 `self.file.is_none()` 且 `self.enabled == true`，会立即报错：
     `Err("command journal file handle is not open")`！
   - 在第 507~513 行之间（文件句柄已打开）：如果有并发命令 `issue_op()` 或 `ack()` 成功执行，它会写入磁盘文件，并插入到内存中的 `inner.commands`；
   - 紧接着，第 513 行执行：`inner.commands = std::mem::take(&mut commands);`！
   - 刚才从磁盘加载的 `commands` 并不包含刚刚并发插入的内存命令！**并发命令在内存中被无声抹除**！

#### 修复方案
引入专用的互斥保护或在 `Inner` 内部保持统一排他操作，在替换全量日志期间阻止外部并发操作进入，或者保证整个换文件与重载过程处于单一临界区之内。

---

### BUG-05【中·线程阻塞】Rust Hub 数据帧转发采用阻塞式 `send`，慢订阅者或网络背压可致中枢单线程事件循环假死

#### 源码定位
- **调用位置**：`hub/src/main.rs:2900-2909`

```rust
if !skip_frame {
    let first_res = sock.send(topic, zmq::SNDMORE);
    match first_res {
        Ok(()) => {
            if let Err(e) = sock.send(payload, 0) {
                eprintln!(
                    "[hub] WARN forward payload frame failed ({}): closing multipart frame with empty terminator",
                    e
                );
                // P1-04: Safely close multipart message with empty frame so socket is not left in torn state
                let _ = sock.send("", 0);
            } else {
                st.note_forward(topic_str, &ty);
```

#### 缺陷机制深入剖析
1. **中枢单线程架构**：Rust Hub 的核心数据通路是一个基于 `zmq::PollItem` 的单线程事件循环。它负责同时处理所有客户端的 `REG`、`HBT2`、`PING`/`PONG`、双机集群 HA 选举以及行情的 `SNAP`/`OPEN`/`CLOSE` 广播。
2. **阻塞标志 `0`**：
   - 检查 Hub 中所有的控制帧发送（如 `send_pong`、`send_who`、`send_topology`），全部无一例外地使用了 `zmq::DONTWAIT` 标志，确保当下游管道拥堵时绝不阻塞事件循环；
   - 然而在第 2900 行和 2903 行的数据转发路径上，代码传入的标志是：
     `sock.send(topic, zmq::SNDMORE)`（缺少 `DONTWAIT`）以及 `sock.send(payload, 0)`（`0` 即阻塞模式）！
   - 如果某个网络极差的 Receiver 导致 XPUB 发送队列打满（达到 SNDHWM 限制），或者本地 TCP 缓冲区满，`sock.send(..., 0)` 会陷入**同步阻塞等待**！
3. **连锁反应**：
   - Hub 事件循环挂起数秒甚至数十秒；
   - 所有的 PING 请求得不到 PONG 响应；
   - 备机（Standby）认为主机已死，触发 ADR-04 晋升选举；
   - 当套接字最终解开阻塞时，两台 Hub 陷入脑裂（Split-Brain）或触发剧烈的反向降级抖动！

#### 修复方案
将数据转发与异常终结帧全部强制带上 `zmq::DONTWAIT` 标志：
```rust
let first_res = sock.send(topic, zmq::DONTWAIT | zmq::SNDMORE);
match first_res {
    Ok(()) => {
        if let Err(e) = sock.send(payload, zmq::DONTWAIT) {
            eprintln!(
                "[hub] WARN forward payload frame failed ({}): closing multipart frame with empty terminator",
                e
            );
            let _ = sock.send("", zmq::DONTWAIT);
        } else {
            st.note_forward(topic_str, &ty);
```

---

## 4. 内存卫生、协议精简与优化空间

### OPT-01【低·协议规范】`CopierPayloadHbt2` 仍冗余发送 `NAME=` 字段，违背每 5 秒精简心跳设计约束

- **位置**：`src/Include/Copier/CopierCodec.mqh:858-862`
- **详情**：
  在 `CopierSender.mq4:496-498` 的架构设计注释中明确写道：
  > `//--- REG and HBT2 differ in ONE field (NAME) and are otherwise identical...`  
  > `//--- A heartbeat repeating a name that cannot have changed is bytes for nothing, every five seconds, from every node.`
  
  然而在 `CopierCodec.mqh` 中：
  ```mql4
  string CopierPayloadHbt2(const string role,const long acc,const string name,
                          const long upSeconds)
    {
     return CopierBuildNodePayload(role,acc,name,upSeconds);
    }
  ```
  它直接调用了 `CopierBuildNodePayload`，从而在每次 5 秒一次的心跳中依然强行打包并传输了 `NAME=` 字段。
- **优化建议**：在 `CopierPayloadHbt2` 中去除 `NAME=` 字段组装，节约心跳广播带宽。

---

### OPT-02【低·状态卫生】`HandleSnapshot` 紧缩清空行未重置 `initLots` 等数值字段，破坏内存初始化契约

- **位置**：`src/Experts/CopierReceiver.mq4:6518-6523`
- **详情**：
  当快照持仓数量缩小时，代码对释放的行进行了清理：
  ```mql4
  for(int i=n;i<prevCount && i<CP_MAX_POSITIONS;i++)
    {
     g_desired[base+i].uid="";
     g_desired[base+i].sym="";
     g_desired[base+i].cmt="";
    }
  ```
  虽然重置字符串成功释放了 MQL 全局堆内存，但 `initLots`、`ticket`、`lots` 等数值字段仍保留着上一轮旧订单的脏数据。如果未来有任何调试代码或防御性扫描越界访问 `g_desired`，可能读取到残留数值。
- **优化建议**：增加 `g_desired[base+i].initLots = 0.0;` 与 `g_desired[base+i].ticket = 0;`。

---

### OPT-03【低·健壮性】ZeroMQ 分段异常终结帧缺少 `DONTWAIT` 标记

- **位置**：`hub/src/main.rs:2909`
- **详情**：
  当 `sock.send(payload, ...)` 失败时，为了保证 ZeroMQ 多段帧协议不破损，代码发送了一个空帧 `sock.send("", 0)`。此处的 `0` 同样属于同步阻塞模式，若下游连接彻底断裂，该终结帧本身也可能发生阻塞。
- **优化建议**：使用 `sock.send("", zmq::DONTWAIT)`。

---

## 5. 测试套件盲区分析

为什么现有的 **720 项 MQL 自动化断言** 与 **173 项 Rust 测试套件** 运行全部通过，却未能捕获上述严重缺陷？

1. **BUG-01 盲区分析（队列退避被清零）**：
   - `CopierSelfTest.mq4` 中的 `TestQueueBackoff` 测试用例是纯单元测试，它以硬编码时间戳直接调用 `CopierQueueNotePass(now, 5, 0, bo, at, spin)`，验证了退避时间从 1s 翻倍到 10s、60s 的状态转移数学逻辑；
   - 但是，自检测试脚本**从未在两次定时器之间模拟行情 `OnTick()` 的并发调用**！因此，`OnTick()` 内部粗暴重置 `g_qRetryAtMs = 0` 的行为在测试套件中属于 100% 的盲区。
2. **BUG-02 盲区分析（MODIFY 失败导致 CLOSE 闭锁）**：
   - 现有的测试分别测试了：① MODIFY 失败触发退避；② 平仓动作在正常情况下的出队执行；
   - 测试套件**从未构造“先对订单 #t123 执行 MODIFY 失败，紧接着对订单 #t123 执行 CLOSE”的交叉时序测试**！因此 `:2:` 与 `:5:` 的命名空间污染未能在断言中暴露。
3. **BUG-03 盲区分析（多源冷启动 GC 竞态）**：
   - 所有的 MQL 多 Sender 单元测试在初始化阶段，都默认设置了所有的 Sender `g_ready = true`；
   - 真实生产环境中，网络建连时延导致“Sender 0 先到、Sender 1 后到”的**异步倾斜场景（Skewed Arrival）**从未在单机自测脚本中模拟。
4. **BUG-04 与 BUG-05 盲区分析（Rust Hub 并发与阻塞）**：
   - Rust 测试套件采用内存模拟或单线程顺序测试，`replace_all` 测试没有开启多线程在替换期间持续调用 `issue_op`；
   - ZeroMQ 测试运行在本地回环（Loopback），缓冲区极大且无网络拥塞，因此阻塞式 `send` 永远能够立即返回，掩盖了生产环境下慢连接的阻塞风险。

---

## 6. 无损修复代码补丁建议

以下补丁严格遵循既有代码风格与命名契约，且不改变任何对外协议与配置文件格式。

### 补丁 1：修复 `CopierReceiver.mq4` 中 `OnTick()` 抹杀退避阶梯 (BUG-01)

```diff
--- a/src/Experts/CopierReceiver.mq4
+++ b/src/Experts/CopierReceiver.mq4
@@ -9490,24 +9490,26 @@ void OnTimer()
 
 void OnTick()
   {
-   // Wake up immediately from market-closed / escalated backoff upon receiving any new tick for our symbols
-   if(g_qRetryAtMs>0 && g_qn>0)
+   // Wake up immediately ONLY from market-closed suspension hold (15 min)
+   // upon receiving a fresh tick for the specific symbol that was held.
+   if(g_qRetryAtMs>0 && g_qn>0 && g_qBackoffMs>=900000)
      {
       bool hasActionForThisSym=false;
       for(int i=0;i<g_qn;i++)
         {
          int idx=(g_qHead+i)%CP_MAX_ACTIONS;
-         if(g_q[idx].sym==_Symbol || !SymbolMarketClosed(g_q[idx].sym))
+         if(g_q[idx].sym==_Symbol)
            {
             hasActionForThisSym=true;
             break;
            }
         }
       if(hasActionForThisSym)
         {
+         g_log.Info("OnTick: market reopened for "+_Symbol+"; waking action queue immediately");
          g_qRetryAtMs=0;
          g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
          g_qSpinPasses=0;
         }
      }
   }
```

---

### 补丁 2：修复 `CopierReceiver.mq4` 中 `boKey` 误用 `:2:` 闭锁平仓 (BUG-02)

```diff
--- a/src/Experts/CopierReceiver.mq4
+++ b/src/Experts/CopierReceiver.mq4
@@ -2977,7 +2977,7 @@ bool PushAction(const int si,const int kind,const string uid,
     else
       {
        //--- MODIFY actions lock backoff to the position ticket rather than the full key.
        //--- Otherwise micro-price changes in trailing stops generate fresh keys and bypass backoff completely.
-       string boKey = (kind==CP_ACT_MODIFY && ticket!=0) ? (sname+":2:#t"+(string)ticket) : key;
+       string boKey = (kind==CP_ACT_MODIFY && ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)ticket) : key;
        if(g_backoff.Blocked(boKey)) { g_pushReject="retry_backoff"; return false; }
       }
@@ -3754,7 +3754,7 @@ void ExecuteQueue()
          g_backoff.Clear(a.key);
          if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
            {
             string sn=SenderLabel(a.senderIdx);
-            g_backoff.Clear(sn+":2:#t"+(string)a.ticket);
+            g_backoff.Clear(sn+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket);
            }
@@ -3890,7 +3890,7 @@ void ExecuteQueue()
              StopSigInvalidate(a.ticket);
             }
           string sname=SenderLabel(a.senderIdx);
-          string boKey=(a.kind==CP_ACT_MODIFY && a.ticket!=0) ? (sname+":2:#t"+(string)a.ticket) : a.key;
+          string boKey=(a.kind==CP_ACT_MODIFY && a.ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket) : a.key;
           fails=1;
```

---

### 补丁 3：修复 `CopierReceiver.mq4` 中未就绪 Sender 导致的 `g_manualClosed` 误 GC (BUG-03)

```diff
--- a/src/Experts/CopierReceiver.mq4
+++ b/src/Experts/CopierReceiver.mq4
@@ -6363,22 +6363,24 @@ void ConvergeSender(const int si)
           else
             {
              bool anySenderHolds=false;
+             bool allSendersReady=true;
              for(int s=0; s<g_nSenders; s++)
                {
+                if(!g_ready[s]) { allSendersReady=false; }
                 int sbase=s*CP_MAX_POSITIONS;
                 for(int d=0; d<g_desiredCount[s]; d++)
                   {
                    if(g_desired[sbase+d].uid==mUid) { anySenderHolds=true; break; }
                   }
                 if(anySenderHolds) break;
                }
-             if(!anySenderHolds)
+             if(!anySenderHolds && allSendersReady)
                {
                 g_log.Info("ManualClosed GC: legacy UID "+mUid+" was closed by operator and no sender holds it. Removed from ignore table.");
                 g_manualClosed.RemoveAt(m);
                 gcChanged=true;
                }
             }
```

---

### 补丁 4：修复 Rust Hub 数据转发阻塞 `sock.send(payload, 0)` (BUG-05 & OPT-03)

```diff
--- a/hub/src/main.rs
+++ b/hub/src/main.rs
@@ -2897,16 +2897,16 @@ fn main() {
                         }
 
                         if !skip_frame {
-                            let first_res = sock.send(topic, zmq::SNDMORE);
+                            let first_res = sock.send(topic, zmq::DONTWAIT | zmq::SNDMORE);
                             match first_res {
                                 Ok(()) => {
-                                    if let Err(e) = sock.send(payload, 0) {
+                                    if let Err(e) = sock.send(payload, zmq::DONTWAIT) {
                                         eprintln!(
                                             "[hub] WARN forward payload frame failed ({}): closing multipart frame with empty terminator",
                                             e
                                         );
                                         // P1-04: Safely close multipart message with empty frame so socket is not left in torn state
-                                        let _ = sock.send("", 0);
+                                        let _ = sock.send("", zmq::DONTWAIT);
                                     } else {
                                         st.note_forward(topic_str, &ty);
```

---

### 补丁 5：精简 `CopierCodec.mqh` 中 `CopierPayloadHbt2` 冗余的 `NAME=` (OPT-01)

```diff
--- a/src/Include/Copier/CopierCodec.mqh
+++ b/src/Include/Copier/CopierCodec.mqh
@@ -855,7 +855,10 @@ string CopierPayloadReg(const string role,const long acc,const string name,
 string CopierPayloadHbt2(const string role,const long acc,const string name,
                         const long upSeconds)
   {
-   return CopierBuildNodePayload(role,acc,name,upSeconds);
+   return "ROLE="+role+CP_SEP_KV+"ACC="+(string)acc
+          +CP_SEP_KV+"VER="+CP_NODE_VER
+          +CP_SEP_KV+"UP="+(string)upSeconds;
   }
```

---

### 补丁 6：重置 `CopierReceiver.mq4` 中 `HandleSnapshot` 紧缩行的 `initLots` (OPT-02)

```diff
--- a/src/Experts/CopierReceiver.mq4
+++ b/src/Experts/CopierReceiver.mq4
@@ -6518,6 +6518,8 @@ void HandleSnapshot(const int si,const string &lines[],const int n)
     for(int i=n;i<prevCount && i<CP_MAX_POSITIONS;i++)
       {
        g_desired[base+i].uid="";
        g_desired[base+i].sym="";
        g_desired[base+i].cmt="";
+       g_desired[base+i].ticket=0;
+       g_desired[base+i].initLots=0.0;
       }
```

---

## 7. 结论与后续操作

本轮审计所发现的问题集中于**高并发边缘边界与异常保护机制中的反向制约**（如防爆锤退避被行情 tick 反向击穿，改单退避污染平仓键空间）。修复这些缺陷不需要重构系统架构，只需按照上述补丁建议实施无损修补，即可彻底杜绝交易被拒时的爆锤风险与平仓闭锁隐患。

遵照指示，**当前阶段未直接修改源码**。上述所有分析细节、代码路径与补丁均已完整记录在此报告中，可随时下载审阅。
