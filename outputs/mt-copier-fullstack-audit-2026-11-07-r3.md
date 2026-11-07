# mt-copier 全栈深度代码审计与系统优化评估报告（2026-11-07 / 第 112 轮最终版）

> **审计执行模式**：严格只读（Strictly Read-Only）。未修改任何源码、配置或运行环境。  
> **审计基线**：Git `HEAD = d68bfdc`（含 `87b067c` 对第 110/111 轮的修复及 11:00 上线版本）。  
> **审查范围**：
> 1. **MQL 客户端与 Include 核心库**（`src/Include/Copier/*.mqh` 全部 17 个头文件、`src/Experts/CopierSender.mq4`、`src/Experts/CopierReceiver.mq4`、`src/Scripts/CopierSelfTest.mq4` 等全量源码）。
> 2. **Rust Hub 核心中枢与内置测试套件**（`hub/src/*.rs` 全部 17 个模块、172 项单元测试、HA 双活集群同步、API 路由、Axum WebSocket 状态流、TLS/ACME 引擎）。
> 3. **全栈协议与测试门禁**（`doc/PROTOCOL.md`、`doc/HANDOFF.md`、`doc/CENTRAL-HUB-HA-FINAL-PLAN.md`、715 项 MQL 自动化自检断言）。
>
> **输出文件**：本报告已保存至 `mt-copier/outputs/mt-copier-fullstack-audit-2026-11-07-r3.md`，可直接供操作员与开发者下载审阅。

---

## 目录

1. [执行摘要与问题评级总表](#1-执行摘要与问题评级总表)
2. [关键逻辑错误与交易安全缺陷 (Critical & High Logic Errors)](#2-关键逻辑错误与交易安全缺陷)
   - [BUG-01【高危·交易安全】`HandleSnapshot` 原地覆写 `g_desired` 导致哈希索引探测失效，FIXED 比例减仓静默停摆](#bug-01高危交易安全handlesnapshot-原地覆写-g_desired-导致哈希索引探测失效fixed-比例减仓静默停摆)
   - [BUG-02【高危·核心性能】`OPEN`/`CLOSE`/`MODIFY` 事件丢失 `g_convergeDirty` 标记，导致实时跟单退化为 250ms 轮询延迟](#bug-02高危核心性能openclosemodify-事件丢失-g_convergedirty-标记导致实时跟单退化为-250ms-轮询延迟)
   - [BUG-03【高危·并发一致性】Rust Hub `ack()` 在落盘前过早剔除 `in_flight`，磁盘写失败致重试阶梯永久失效](#bug-03高危并发一致性rust-hub-ack-在落盘前过早剔除-in_flight磁盘写失败致重试阶梯永久失效)
3. [中危业务逻辑与架构边界缺陷 (Medium Architecture & Protocol Issues)](#3-中危业务逻辑与架构边界缺陷)
   - [BUG-04【中高·风控精度】`ConvergeSender` 粗糙容差 `0.0001` 与 8 位小数手数冲突，引发微手数减仓重复开仓/重复出队](#bug-04中高风控精度convergesender-粗糙容差-00001-与-8-位小数手数冲突引发微手数减仓重复开仓重复出队)
   - [BUG-05【中·网络带宽】Sender 挂单改价 `ppriceDiff` 计入 `otherDiff`，引发 4Hz 高达 380KB 的快照风暴](#bug-05中网络带宽sender-挂单改价-ppricediff-计入-otherdiff引发-4hz-高达-380kb-的快照风暴)
   - [BUG-06【中·状态竞争】`g_manualClosed` GC 误删无 SID 归属的条目，多 Sender 下已被平仓单被兄弟 Sender 误复活](#bug-06中状态竞争g_manualclosed-gc-误删无-sid-归属的条目多-sender-下已被平仓单被兄弟-sender-误复活)
   - [BUG-07【中·状态机冷启动】MT4 `CopierRealizedToday` 异步历史就绪竞态虚报 `outOk=true`，导致日内风控基线锁死错误值并持久化](#bug-07中状态机冷启动mt4-copierrealizedtoday-异步历史就绪竞态虚报-outoktrue导致日内风控基线锁死错误值并持久化)
   - [BUG-08【中·前端遥测】Axum WebSocket `Lagged` 丢帧未补发全量快照，致 Web 控制台界面永久显示脏数据](#bug-08中前端遥测axum-websocket-lagged-丢帧未补发全量快照致-web-控制台界面永久显示脏数据)
   - [BUG-09【中·接口规范】Standby 备机高危写端点 409 拦截响应结构缺失 `primary` 与 `detail` 引导字段](#bug-09中接口规范standby-备机高危写端点-409-拦截响应结构缺失-primary-与-detail-引导字段)
4. [内存卫生、协议规范与性能优化空间 (Performance & Hygiene Opportunities)](#4-内存卫生协议规范与性能优化空间)
   - [OPT-01【中低·内存驻留】`StopsForget`、`MapClear`、`HandleCloseEvent` 数组紧缩与清空未解引用 MQL 字符串](#opt-01中低内存驻留stopsforgetmapclearhandlecloseevent-数组紧缩与清空未解引用-mql-字符串)
   - [OPT-02【中低·状态卫生】`CopierPosTable::Clear()` 遗漏重置 N-03 新增的 `initLots` 字段](#opt-02中低状态卫生copierpostableclear-遗漏重置-n-03-新增的-initlots-字段)
   - [OPT-03【低·协议规范】`CopierPayloadHbt2` 仍冗余发送 `NAME=` 字段，与文档及设计约束不一致](#opt-03低协议规范copierpayloadhbt2-仍冗余发送-name-字段与文档及设计约束不一致)
   - [OPT-04【低·通信鲁棒性】XSUB `Subscribe` 饱和静默丢弃计数 & `ConnectReceiver` 重置缺口 & `ConnectExtraHub` 冗余重放](#opt-04低通信鲁棒性xsub-subscribe-饱和静默丢弃计数--connectreceiver-重置缺口--connectextrahub-冗余重放)
   - [OPT-05【低·并发鲁棒性】Rust Hub `replace_all()` 重建过程置空 `inner.file` 导致并发写被误判为内存模式而丢失](#opt-05低并发鲁棒性rust-hub-replace_all-重建过程置空-innerfile-导致并发写被误判为内存模式而丢失)
5. [测试套件盲区分析（为何既有 715 MQL + 172 Rust 门禁全绿）](#5-测试套件盲区分析)
6. [排期与无损修复实施建议](#6-排期与无损修复实施建议)

---

## 1. 执行摘要与问题评级总表

本轮审计采用**单进程整文件端到端串联审查方式**，重点穿透 MQL 客户端与 Rust Hub 之间的跨进程状态机契约、ZMQ 帧序列交互、多发送源并发边界以及容灾一致性。

全栈共检出 **14 项** 缺陷与优化项（高危 3 项、中危 6 项、低危/优化 5 项）：

| 编号 | 类别 | 模块与代码路径 | 严重级别 | 核心危害 / 表现简述 |
|---|---|---|:---:|---|
| **BUG-01** | 交易逻辑 | `src/Experts/CopierReceiver.mq4:6362-6382` | **高危** | `HandleSnapshot` 边查旧索引边覆写 `g_desired`，UID 顺序变动导致散列复核探测链断裂，`carry` 归零，FIXED 比例减仓静默失效 |
| **BUG-02** | 延迟性能 | `src/Experts/CopierReceiver.mq4:7680-7686` | **高危** | 收到 `OPEN`/`CLOSE`/`MODIFY` 实时事件后未置位 `g_convergeDirty[si]`，跟单执行被迫等待 250ms 定时扫频，违背 <10ms 设计目标 |
| **BUG-03** | 并发一致性 | `hub/src/commands.rs:905-953` | **高危** | `ack()` 在执行 `inner.append()` 前先行将 ID 从 `in_flight` 集合抹除；若磁盘日志写入失败，重试阶梯将彻底遗忘该命令，永久卡在 PENDING |
| **BUG-04** | 交易精度 | `src/Experts/CopierReceiver.mq4:5589, 3309` | **中高** | `0.0001` 手数硬编码容差比 8 位加密货币/微型碎股手数大 500 倍，减仓未完成时被误判为"已达标"，导致 `g_seen` 被提早清空并重复下发多笔平仓 |
| **BUG-05** | 网络流量 | `src/Include/Copier/CopierState.mqh:268`, `Sender.mq4:2189` | **中** | 挂单触发价 `ppriceDiff` 被归入 `otherDiff`，导致移动挂单价时伴随 4Hz 的全量快照广播（单次最高 380KB），A2 优化被击穿 |
| **BUG-06** | 交易安全 | `src/Experts/CopierReceiver.mq4:6243-6250` | **中** | `g_manualClosed` 在多 Sender 下清理无 SID 的 UID 时，只要 Sender 0 未持有该单就地删除，导致持有该单的 Sender 1 在下一 tick 重新开仓 |
| **BUG-07** | 状态机安全 | `src/Include/Copier/CopierModel.mqh:236, 259`, `Receiver:5180` | **中** | MT4 历史异步拉取未就绪时 `OrdersHistoryTotal() == 0`，`CopierRealizedToday` 误报 `outOk=true`，冷启动将早盘亏损归零抹除并持久化至磁盘 |
| **BUG-08** | 遥测展示 | `hub/src/api.rs:842, 860` | **中** | WebSocket 发生 `Lagged` 丢帧后仅 `continue`；因心跳已被轻量化为 Ping，前端永远收不到全量快照补偿，控制台显示陈旧订单数据 |
| **BUG-09** | 接口规范 | `hub/src/api.rs:2235, 2385, 1500, 3136...` | **中** | Standby 上配置、用户、告警、TLS 等高危变更拦截响应仅有 `error`，缺少 N-02 在命令端点统一提供的 `primary` 和 `detail` 字段 |
| **OPT-01** | 内存卫生 | `Receiver.mq4:6408, 1235, 7252` | **中低** | `StopsForget`、`MapClear`、`HandleCloseEvent` 在出队/重载时未重置尾部字符串为空字符串，造成 MQL 内部全局字符串池引用驻留 |
| **OPT-02** | 状态卫生 | `src/Include/Copier/CopierState.mqh:170-190` | **中低** | `CopierPosTable::Clear()` 逐字段清理时遗漏 `initLots = 0.0`，虽当前路径有初始化，但破坏了底层状态容器的原子清空契约 |
| **OPT-03** | 协议冗余 | `src/Include/Copier/CopierCodec.mqh:849-853` | **低** | `CopierPayloadHbt2` 实现与文档和注释矛盾，每 5 秒仍然向 Hub 发送不变的 `NAME` 字符串，浪费中枢网络带宽 |
| **OPT-04** | 协议鲁棒性 | `src/Include/Copier/CopierTransport.mqh:307, 444, 484` | **低** | XSUB 前缀表满 256 后无记账发包、`ConnectReceiver` 缺少重置计数、`ConnectExtraHub` 与 libzmq 自带重放叠加形成多倍引用计数 |
| **OPT-05** | 存储鲁棒性 | `hub/src/commands.rs:500, 1004` | **低** | `replace_all()` 临时将 `inner.file = None`，微秒窗口内若有并发 `append_many` 触发，会被误判为"纯内存模式"而返回 `Ok(())` 并丢弃写入 |

---

## 2. 关键逻辑错误与交易安全缺陷

### BUG-01【高危·交易安全】`HandleSnapshot` 原地覆写 `g_desired` 导致哈希索引探测失效，FIXED 比例减仓静默停摆

#### 源码定位
- **调用方**：`src/Experts/CopierReceiver.mq4:6362-6382`
- **索引实现**：`src/Include/Copier/CopierState.mqh:901-912`

```mql4
// src/Experts/CopierReceiver.mq4:6362-6372
if(prevCount>0) g_desIdx.Build(g_desired,base,prevCount);
for(int i=0;i<n;i++)
  {
   double carry=0.0;
   if(prevCount>0)
     {
      int prevRow=g_desIdx.Find(g_desired,g_scratch[i].uid);
      if(prevRow>=base && prevRow<base+prevCount) carry=g_desired[prevRow].initLots;
     }
   g_desired[base+i]=g_scratch[i];          // <--- 致命逻辑：在循环迭代中就地改写数组内容！
   if(carry<=0.0) carry=GetOrUpdateSenderPeakLots(g_scratch[i].uid,g_scratch[i].lots);
   g_desired[base+i].initLots=CopierNextInitLots(carry,g_scratch[i].lots);
  }
```

```mql4
// src/Include/Copier/CopierState.mqh:901-912
int Find(const CopierPos &arr[],const string uid) const
  {
   if(StringLen(uid)!=CP_UID_LEN) return -1;
   uint hf=HashOf(uid);
   int  s=(int)(hf&m_mask);
   for(int p=0;p<CP_UIDIDX_SLOTS;p++)
     {
      int k=(int)((s+p)&m_mask);
      if(m_slot[k]==0) return -1;
      // 复核：检查散列槽指向的数组行内容是否与待查 UID 一致！
      if(m_hash[k]==hf && arr[m_slot[k]-1].uid==uid) return m_slot[k]-1;
     }
   return -1;
  }
```

#### 缺陷深度推导
1. **哈希复核机制**：`CopierUidIndex::Find()` 属于开放寻址哈希表。为了防御哈希碰撞，它在命中槽位后，必须通过 `arr[m_slot[k]-1].uid == uid` 校验**数组底层的实际内容**。
2. **原地覆写污染**：在第 6363 行开启的循环中，代码一边使用 `g_desIdx.Find(g_desired, ...)` 查询旧快照数据，一边在第 6371 行直接执行 `g_desired[base+i] = g_scratch[i]`。
3. **真实业务崩溃场景**：
   - 设旧快照中有两笔订单：Slot 0 为 `UID_A`（`initLots=2.0, lots=1.0` 已减仓），Slot 1 为 `UID_B`（`initLots=1.0`）。
   - 在新快照中，由于 Sender 端成交或排序变化，`UID_B` 排在第 0 位，`UID_A` 排在第 1 位。
   - **迭代 i = 0**：处理 `UID_B`。查找旧 Slot 1 成功，拿到 `carry=1.0`。接着，代码将 `UID_B` 覆写到 `g_desired[base + 0]`。此时 Slot 0 原有的 `UID_A` 被彻底破坏！
   - **迭代 i = 1**：处理 `UID_A`。调用 `g_desIdx.Find(g_desired, "UID_A")`。哈希表指示 `UID_A` 在旧 Slot 0。
   - 此时 `Find()` 去检查 `g_desired[base + 0].uid`，发现它**已经被覆写成了 `UID_B`**！
   - 字符串比对不匹配，`Find` 沿着线性探测链向前搜索，遇到空槽返回 `-1`（查找失败）。
4. **资金损失链**：
   - `carry` 退化为 `0.0`。
   - 代码回退调用 `GetOrUpdateSenderPeakLots`，但该全局单表仅 2048 槽位，在多 Sender 活跃时极易满表或已被 Prune 清理，同样返回当前的手数 `1.0`。
   - `g_desired[base+i].initLots` 被错误重置为 `1.0`（而不是开仓峰值 `2.0`）。
   - 在 `ComputeTargetLotsForMirror`（`CopierReceiver.mq4:4109`）中：
     $$\text{ratio} = \frac{\text{lots}}{\text{initLots}} = \frac{1.0}{1.0} = 1.0$$
   - **发送端后续再次减仓时，接收端因分子分母恒等而停止等比例缩减，仓位敞口超标，且系统全程没有任何报错！**

#### 推荐修复方案
严禁在索引查询未结束前破坏底层数组。可在计算阶段将新快照的 `initLots` 先行暂存到 `g_scratch[i].initLots`，或者采用独立的临时数组暂存，全部计算完成后再批量拷贝至 `g_desired`：

```mql4
// 方案：先完整计算出 carry，暂存入 g_scratch，最后统一赋值
if(prevCount>0) g_desIdx.Build(g_desired,base,prevCount);
for(int i=0;i<n;i++)
  {
   double carry=0.0;
   if(prevCount>0)
     {
      int prevRow=g_desIdx.Find(g_desired,g_scratch[i].uid);
      if(prevRow>=base && prevRow<base+prevCount) carry=g_desired[prevRow].initLots;
     }
   if(carry<=0.0) carry=GetOrUpdateSenderPeakLots(g_scratch[i].uid,g_scratch[i].lots);
   g_scratch[i].initLots=CopierNextInitLots(carry,g_scratch[i].lots);
  }
// 查找完全结束后，再覆盖 g_desired
for(int i=0;i<n;i++)
  {
   g_desired[base+i]=g_scratch[i];
  }
```

---

### BUG-02【高危·核心性能】`OPEN`/`CLOSE`/`MODIFY` 事件丢失 `g_convergeDirty` 标记，导致实时跟单退化为 250ms 轮询延迟

#### 源码定位
- `src/Experts/CopierReceiver.mq4:7680-7686` (`DispatchCentralMessage`)
- `src/Experts/CopierReceiver.mq4:8899-8907` (`OnTimer` 扫频门禁)
- `src/Include/Copier/CopierState.mqh:1539-1545` (`CopierConvergeDue`)

```mql4
// src/Experts/CopierReceiver.mq4:7680-7686
if(e.type==CP_T_SNAP)        HandleSnapshot(si,e);      // 内部调用了 g_convergeDirty[si]=true;
else if(e.type==CP_T_OPEN)   HandleOpenEvent(si,e);     // 仅插入 g_desired，未置 dirty！
else if(e.type==CP_T_CLOSE)  HandleCloseEvent(si,e);    // 仅删除 g_desired，未置 dirty！
else if(e.type==CP_T_MODIFY) HandleModifyEvent(si,e);   // 仅记录 StopsOv，未置 dirty！
```

```mql4
// src/Experts/CopierReceiver.mq4:8899-8907
long nowMs=CopierNowMs();
bool dirtyAny=g_convergeDirtyAll;
if(!dirtyAny)
  {
   for(int di=0;di<g_nSenders;di++)
     {
      if(g_convergeDirty[di]) { dirtyAny=true; break; }
     }
  }
bool doConverge=CopierConvergeDue(nowMs,g_lastConvergeSweepMs,dirtyAny,g_convergeSweepMs);
// ... 若 doConverge 为 false，本次 OnTimer 完全跳过 ConvergeSender！
```

```mql4
// src/Include/Copier/CopierState.mqh:1539-1545
bool CopierConvergeDue(const long nowMs,const long lastMs,const bool dirty,const int sweepMs)
  {
   if(dirty) return true;       // dirty 为 true 时立即返回 true 触发对齐
   if(sweepMs<=0) return true;
   return (nowMs-lastMs>=sweepMs); // dirty 为 false 时，必须等待 250ms 扫频周期！
  }
```

#### 缺陷深度推导
1. **架构契约**：系统宣传与协议设计的基石是 **"Events deliver sub-10ms execution; snapshots enforce absolute eventual consistency"**。`OPEN`、`CLOSE`、`MODIFY` 是发送端即时推送的实时事件帧。
2. **事件未置脏**：当 Sender 端发来 `OPEN` 事件时，Receiver 的 `HandleOpenEvent()` 将新订单写入 `g_desired`，**但遗漏了 `g_convergeDirty[si] = true;`**。同理，`HandleCloseEvent` 和 `HandleModifyEvent` 也未置脏。
3. **延迟劣化至 250ms**：
   - 在该 Tick 中，`dirtyAny` 评估为 `false`。
   - `CopierConvergeDue` 检查 `nowMs - g_lastConvergeSweepMs >= 250`。
   - 如果距离上次常规扫频不足 250ms，`doConverge` 判定为 `false`。
   - 接收端主线程直接退出，**新订单在内存中闲置，必须等待下一个 250ms 定时器触发才执行开仓！**
4. **滑点与行情风险**：在快速波动的非农、加息行情下，250ms 的延迟足以让黄金或指数产生几十个点子的价差滑点，甚至直接导致滑点超限被拒单。

#### 推荐修复方案
在 `HandleOpenEvent`、`HandleCloseEvent`、`HandleModifyEvent` 成功解析处理后，无条件置位 `g_convergeDirty[si] = true;`，确保当个 Tick 立即唤醒 `ConvergeSender` 进行下单操作。

---

### BUG-03【高危·并发一致性】Rust Hub `ack()` 在落盘前过早剔除 `in_flight`，磁盘写失败致重试阶梯永久失效

#### 源码定位
- `hub/src/commands.rs:904-954` (`CommandStore::ack`)
- `hub/src/commands.rs:815-860` (`CommandStore::due_gated_with`)

```rust
// hub/src/commands.rs:904-916
pub fn ack(&self, id: &str, ok: bool, rev: u64, err: &str) -> bool {
    let mut inner = self.inner.lock_or_recover();
    inner.in_flight.remove(id); // <--- 隐患：在确认成功落盘前，过早从飞线集合中剔除！
    
    let updated = match inner.commands.get(id) {
        None => return false,
        Some(c) => {
            // 构建候选状态...
        }
    };
    if !inner.append(&updated) {
        eprintln!(
            "[hub] COMMAND JOURNAL WRITE FAILED on ACK for {} - leaving it pending so the ladder retries",
            id
        );
        return false; // 返回失败，期望命令保持 PENDING 并由 ladder 重试
    }
    inner.commands.insert(updated.id.clone(), updated);
    true
}
```

```rust
// hub/src/commands.rs:815-826
fn due_gated_with<F>(&self, now: Instant, writes_enabled: bool, is_reachable: F) -> Vec<Command>
where
    F: Fn(&str) -> bool,
{
    let mut inner = self.inner.lock_or_recover();
    // 重试阶梯严密依赖 in_flight 遍历待处理命令集合！
    let ids: Vec<String> = inner.in_flight.iter().cloned().collect();
    // ...
```

#### 缺陷深度推导
1. **代码注释的自我矛盾**：第 907-914 行与 948 行明确注释写道：`"N-09: ... A failed append now leaves the command pending and returns false, so the retry ladder keeps walking and the next ACK records it."`（磁盘追加失败时保持 pending，以便重试阶梯继续尝试重发）。
2. **集合已被清空**：然而在第 906 行，代码在尚未调用 `inner.append(&updated)` 之前，就无条件执行了 `inner.in_flight.remove(id);`！
3. **阶梯永久丢失**：
   - 假如此时磁盘发生短时 I/O 阻塞或满盘，`inner.append()` 返回 `false`。
   - 内存中的 `inner.commands.get(id)` 状态确实保持为 `STATE_PENDING`。
   - 但负责驱动重试阶梯的 `due_gated_with()` **只遍历 `inner.in_flight` 集合**。
   - 由于该 `id` 已经被第 906 行永久抹除，`due_gated_with` 再也扫描不到此命令！
   - 该命令在内存中永远处于 `pending`，但 Hub 再也不会向节点发起任何重发重试，直至 Hub 重启。

#### 推荐修复方案
将 `inner.in_flight.remove(id);` 移动至 `inner.append(&updated)` 成功返回之后执行：

```rust
if !inner.append(&updated) {
    eprintln!("[hub] COMMAND JOURNAL WRITE FAILED on ACK for {} - leaving it pending so the ladder retries", id);
    return false;
}
inner.in_flight.remove(id); // 仅在日志持久化落盘成功后，方可移出飞线重试池
inner.commands.insert(updated.id.clone(), updated);
true
```

---

## 3. 中危业务逻辑与架构边界缺陷

### BUG-04【中高·风控精度】`ConvergeSender` 粗糙容差 `0.0001` 与 8 位小数手数冲突，引发微手数减仓重复开仓/重复出队

#### 源码定位
- `src/Experts/CopierReceiver.mq4:5589`
- `src/Experts/CopierReceiver.mq4:3309`

```mql4
// src/Experts/CopierReceiver.mq4:5587-5593
double targetLots=ComputeTargetLotsForMirror(si,d,g_locScratch[li].sym);
if(!hasQueued)
  {
   // 致命：0.0001 的粗糙容差！
   if(targetLots>0.0 && g_locScratch[li].lots<=targetLots+0.0001)
      g_seen.ForgetUidActions(g_sid[si],d.uid);
   else
      g_seen.ForgetPrefix(g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid);
  }
```

```mql4
// src/Experts/CopierReceiver.mq4:3309
if(targetLots > 0.0 && a.lots > targetLots + 0.0001)
```

#### 缺陷深度推导
1. **精度标准**：项目在 `CopierDefs.mqh:121` 明确定义 `CP_DIGITS_LOTS = 8`，以适配加密货币（如 BTC 0.00000010 手）及碎股交易。并在 `87b067c` 将部分平仓判定从 `1e-7` 收敛至 `1e-9`。
2. **粗糙阈值失效**：
   - 假设本地持有微型加密货币仓位 `lots = 0.00000020`，发送端减仓后计算出目标手数 `targetLots = 0.00000010`。
   - 本地发起了 `CP_ACT_TRIM`，但在券商完成成交回执前（`g_locScratch[li].lots` 仍为 `0.00000020`）：
   - 代码判定：
     $$0.00000020 \le 0.00000010 + 0.0001 \quad (0.00000020 \le 0.00010010 \implies \text{true})$$
   - 代码误以为"持仓手数已经成功收敛到目标手数"，直接执行 `g_seen.ForgetUidActions`！
3. **危害**：清空 `g_seen` 的防重守卫后，下一 Tick `QueueTrimIfNeeded` 发现持仓依然是 0.00000020 > 0.00000010，**再次推入一笔重复的 `CP_ACT_TRIM`**。导致券商执行连续两次部分平仓，将订单平多甚至完全平掉。

#### 推荐修复方案
将硬编码的 `0.0001` 替换为以交易品种步进为基准的动态容差或高精度常量（如 `CP_LOT_EPS = 1e-9`）：

```mql4
if(targetLots>0.0 && g_locScratch[li].lots<=targetLots+1e-9)
```

---

### BUG-05【中·网络带宽】Sender 挂单改价 `ppriceDiff` 计入 `otherDiff`，引发 4Hz 高达 380KB 的快照风暴

#### 源码定位
- `src/Include/Copier/CopierState.mqh:266-273` (`CheckSlot`)
- `src/Experts/CopierSender.mq4:2185-2208` (`OnTimer`)

```mql4
// src/Include/Copier/CopierState.mqh:266-268
ppriceDiff=(cur.kind==CP_ORD_PENDING && MathAbs(m_p[i].pprice-cur.pprice)>0.0000001);
otherDiff=(MathAbs(m_p[i].openPx-cur.openPx)>0.0000001
          || ppriceDiff                           // <--- 致命根因：把改价直接并入 otherDiff
          || MathAbs(m_p[i].pstop-cur.pstop)>0.0000001
          // ...
```

```mql4
// src/Experts/CopierSender.mq4:2188-2196
if(otherDiff) MarkSnapshotDirty();                // <--- 触发 g_snapDirty = true
if(stopsDiff || ppriceDiff)
  {
   // 注释声称：MODIFY already delivers the new levels; No full broadcast.
   MarkLatestDirty();
   Emit(CP_T_MODIFY, ...);                        // 发出轻量事件
  }
```

```mql4
// src/Experts/CopierSender.mq4:2342
if(dueSnap || (g_snapDirty && now-g_lastSnapMs>=250))
  {
   BroadcastSnapshot(now);                        // <--- 250ms 后全量广播！
  }
```

#### 缺陷深度推导
1. **A2 设计原则**：A2 优化的核心是**订单止损、止盈或挂单改价只需通过轻量级的 `MODIFY` 事件（约 60 字节）广播，严禁触发全量 SNAPSHOT 广播**。
2. **状态污染**：在 `CheckSlot` 中，`ppriceDiff` 被错误地并入了 `otherDiff`。
3. **风暴产生**：当 Sender 端开启跟踪挂单（Trailing Buy-Stop/Sell-Stop）时，价格以 4Hz~10Hz 高频变动。每次改价虽然正确触发了 `Emit(CP_T_MODIFY)`，但同时通过 `otherDiff` 将 `g_snapDirty` 置为 `true`。
4. 在 2048 仓位规格下，一次全量快照最坏可达 380KB，导致 4Hz 的挂单改价伴随 1.5MB/s 的无谓全量数据洪峰，严重挤占 VPS 带宽与 CPU 解析算力。

#### 推荐修复方案
从 `otherDiff` 中剔除 `ppriceDiff`（改价事件由 `ppriceDiff` 自身独立触发 `MarkLatestDirty()` 与 `CP_T_MODIFY` 即可，与 `stopsDiff` 保持同等待遇）：

```mql4
// src/Include/Copier/CopierState.mqh:267-273
otherDiff=(MathAbs(m_p[i].openPx-cur.openPx)>0.0000001
          // 移除 || ppriceDiff
          || MathAbs(m_p[i].pstop-cur.pstop)>0.0000001
          || m_p[i].ptype!=cur.ptype
          || m_p[i].pexpire!=cur.pexpire
          || m_p[i].sym!=cur.sym
          || m_p[i].side!=cur.side);
```

---

### BUG-06【中·状态竞争】`g_manualClosed` GC 误删无 SID 归属的条目，多 Sender 下已被平仓单被兄弟 Sender 误复活

#### 源码定位
- `src/Experts/CopierReceiver.mq4:6243-6250` (`ConvergeSender` 中的 GC 逻辑)

```mql4
// src/Experts/CopierReceiver.mq4:6243-6250
// curSid 是当前执行 ConvergeSender 的 si 对应的 sender id
if(StringLen(mSid)>0 && mSid!=curSid) continue;

bool senderStillHolds=false;
for(int d=0; d<g_desiredCount[si]; d++)
  {
   if(g_desired[base+d].uid==mUid) { senderStillHolds=true; break; }
  }
if(!senderStillHolds)
  {
   // 认为信号源已平仓，从人工平仓表中移除！
   g_manualClosed.RemoveAt(m);
   gcChanged=true;
  }
```

#### 缺陷深度推导
1. **多信号源并发模型**：Receiver 支持同时监听多个 Sender（如 Sender 0 与 Sender 1）。
2. **条目缺少 SID 的场景**：当从旧版状态文件加载、或者通过 WebUI/CMD 下发手动平仓而未能关联到具体 Sender 时，`mSid` 允许为空字符串 `""`（见 `CopierReceiver.mq4:2502` `g_manualClosed.Add(v,0,"")`）。
3. **跨 Sender 交叉误杀**：
   - 设操作员手动平掉了属于 Sender 1 的订单 `mUid = "A1B2C3D4"`（此时该记录 `mSid = ""`）。
   - 在当个 Tick 中，Receiver 首先对 Sender 0 执行 `ConvergeSender(0)`。
   - 代码检查 `StringLen(mSid) > 0 && mSid != curSid`：由于 `mSid` 为空，**守卫失效，未执行 `continue`**！
   - 代码进而遍历 Sender 0 的 `g_desired`：Sender 0 当然没有持有属于 Sender 1 的 `A1B2C3D4`，于是判定 `senderStillHolds = false`。
   - **Sender 0 的对齐过程立即将该 `mUid` 从 `g_manualClosed` 中彻底删除！**
   - 紧接着，当执行到 `ConvergeSender(1)` 时，Sender 1 仍然持有着 `A1B2C3D4`。此时 `g_manualClosed.Has(d.uid)` 返回 `false`！
   - **Receiver 以为这是一笔需要开仓的新单，瞬间在本地重新下单开仓！操作员刚刚手动平掉的单据被系统自行复活。**

#### 推荐修复方案
当 `StringLen(mSid) == 0` 时，必须检查**全网所有 Sender**的 `g_desired`，只有确认没有任何一个 Sender 持有该 UID 时，方可执行 `RemoveAt`：

```mql4
if(StringLen(mSid)>0)
  {
   if(mSid!=curSid) continue;
   // 单一 Sender 检查
  }
else
  {
   // mSid 为空时，必须遍历所有 ready 的 Sender
   bool anyHolds=false;
   for(int s=0;s<g_nSenders;s++)
     {
      int b=s*CP_MAX_POSITIONS;
      for(int d=0;d<g_desiredCount[s];d++)
        {
         if(g_desired[b+d].uid==mUid) { anyHolds=true; break; }
        }
      if(anyHolds) break;
     }
   if(anyHolds) continue; // 只要还有任意 Sender 持有，就决不能清理
  }
```

---

### BUG-07【中·状态机冷启动】MT4 `CopierRealizedToday` 异步历史就绪竞态虚报 `outOk=true`，导致日内风控基线锁死错误值并持久化

#### 源码定位
- `src/Include/Copier/CopierModel.mqh:234-269`
- `src/Experts/CopierReceiver.mq4:5180-5222`

```mql4
// src/Include/Copier/CopierModel.mqh:234-269
double CopierRealizedToday(const long dayStart,bool &outOk)
  {
   outOk=true; // <--- 默认无条件返回 true！
   double sum=0.0;
#ifdef __MQL5__
   // MQL5 具备 HistorySelect 校验，失败返回 outOk=false
   if(!HistorySelect(from,to)) { outOk=false; return 0.0; }
   // ...
#else
   // MT4 分支完全没有异步就绪检查！
   int total=OrdersHistoryTotal();
   for(int i=0;i<total;i++) { ... }
#endif
   return sum;
  }
```

#### 缺陷深度推导
1. **MT4 异步机制**：MT4 终端在重启、断线重连或账号切换初期，`OrdersHistoryTotal()` 立即返回 `0`，历史订单是在后台线程通过网络向经纪商请求并逐步填充的。
2. **冷启动误吞亏损**：
   - 盘中重启 EA，此时早盘已经发生了 \$500 的实际亏损（账户余额从 \$10,000 降为 \$9,500）。
   - 冷启动触发 `wasColdStart = true`，调用 `CopierRealizedToday`。
   - MT4 返回 `total = 0`，`sum = 0.0`，**但 `outOk` 却被写死为 `true`**！
   - `trueStartBal = curBal - 0.0 = $9,500`。
   - 代码把 \$9,500 误当成了"今日起始资金"，并直接调用 `RiskPeakSave(true)` **刷入磁盘文件 `copier_risk_<acc>.dat`**！
3. **风控敞口放大**：
   - 若配置了 5% 日内最大亏损（原本应在权益低于 \$9,500 时直接停机熔断）：
   - 由于基线被错误下修到 \$9,500，熔断线退化为 $9500 \times 0.95 = \$9,025$。
   - **早盘已发生的 \$500 亏损被彻底免除，账户被允许额外多亏损 \$475！**
   - 即使 60 秒后触发重新校准，若此期间发生交易或再次崩溃重启，错误的基线便永远固化。

#### 推荐修复方案
在 MT4 分支增加终端连接与历史可用性校验，当未连接或处于冷启动首跳且 `OrdersHistoryTotal() == 0` 时，保守返回 `outOk = false`，阻止错误基线被初始化并保存：

```mql4
#else
   if(!IsConnected()) { outOk=false; return 0.0; }
   int total=OrdersHistoryTotal();
   // 若历史为 0 且启动不足 10 秒，标记为未就绪
   if(total==0 && (GetTickCount()-g_bootMs)<10000) { outOk=false; return 0.0; }
```

---

### BUG-08【中·前端遥测】Axum WebSocket `Lagged` 丢帧未补发全量快照，致 Web 控制台界面永久显示脏数据

#### 源码定位
- `hub/src/api.rs:839-844` (`handle_socket`)
- `hub/src/api.rs:859-864` (`beat.tick`)

```rust
// hub/src/api.rs:839-844
changed = rx.recv() => {
    match changed {
        Ok(s) => {
            if socket.send(Message::Text((*s).clone())).await.is_err() {
                break;
            }
        }
        // 注释写道：A slow client missed some. It is about to be sent the current state anyway...
        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue, // 仅执行 continue！
        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
    }
}
```

#### 缺陷深度推导
1. **历史遗留注释与代码脱节**：注释声称"慢速客户端丢包无妨，因为它马上会收到当前最新全量状态"。这在早期版本成立，因为旧代码在心跳周期中会周期性广播 `snapshot_text(&st)`。
2. **轻量心跳破坏了补偿机制**：在 N49-09 优化中，为了降低 CPU 占用，心跳被改成了轻量级的空帧 Ping（`socket.send(Message::Ping(Vec::new()))`）。
3. **脏数据永久驻留**：当网络微抖动导致某浏览器端 WebUI 发生 `broadcast::Lagged` 时，该客户端跳过了中间的状态推送。由于 `continue` 后再没有任何逻辑去拉取全量快照，且后续心跳只有 Ping，**该客户端的界面将永久停留在错乱或缺失的订单状态，直到用户手动 F5 强制刷新浏览器**。

#### 推荐修复方案
在捕获 `RecvError::Lagged(_)` 时，立即主动向该 WebSocket 连接补发一帧最新快照：

```rust
Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
    let snap = snapshot_text(&st);
    if socket.send(Message::Text(snap)).await.is_err() {
        break;
    }
    continue;
}
```

---

### BUG-09【中·接口规范】Standby 备机高危写端点 409 拦截响应结构缺失 `primary` 与 `detail` 引导字段

#### 源码定位
- `hub/src/api.rs:2235` (`put_node_config`)
- `hub/src/api.rs:2385` (`rollback_node_config`)
- `hub/src/api.rs:1500, 1606, 1658` (`users_upsert`, `user_delete`, `change_password`)
- `hub/src/api.rs:3136, 3273` (`alerts_save_channels`, `test_channel`)
- `hub/src/api.rs:4136, 4270, 4307, 4343, 4386` (TLS 证书管理)

#### 表现与危害
在 `post_command`（`api.rs:2604`）中，Standby 拦截命令时返回规范的导流 JSON：
```json
{
  "error": "Standby node does not dispatch commands (read-only queries included).",
  "detail": "Issue it against the Primary at http://127.0.0.1:6010.",
  "primary": "http://127.0.0.1:6010"
}
```
但在上述其余所有写操作端点中，返回的 JSON 仅仅是截断的一句话：
```json
{ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." }
```
**影响**：自动化运维脚本、跨机房部署客户端或 Web 控制台无法通过解析 `primary` 字段实现自动透明重定向，造成前端在主备切换时弹出笼统报错，用户体验和自动化能力分裂。

---

## 4. 内存卫生、协议规范与性能优化空间

### OPT-01【中低·内存驻留】`StopsForget`、`MapClear`、`HandleCloseEvent` 数组紧缩与清空未解引用 MQL 字符串

#### 源码定位
- `src/Experts/CopierReceiver.mq4:6408-6416` (`StopsForget`)
- `src/Experts/CopierReceiver.mq4:1235-1238` (`MapClear`)
- `src/Experts/CopierReceiver.mq4:7251-7255` (`HandleCloseEvent`)

#### 机制解析
1. **`StopsForget`**：在 commit `87b067c` 中，修复 M-03 时仅给 `StopsPrune`（第 6528 行）补齐了 `g_stUid[g_stCount] = "";`。然而 `StopsForget` 是订单出队平仓时的同类紧缩出口（第 6416 行），移位缩容后遗漏了清空尾部槽位 `g_stUid[last] = ""`。
2. **`MapClear`**：整个函数仅有 `g_nMap = 0;`。静态数组 `g_mapFrom` 与 `g_mapTo` 容量高达 6400 个字符串，配置热重载时未释放旧字符串引用。
3. **`HandleCloseEvent`**：订单平仓时，第 7252 行仅执行了 `g_desired[base+g_desiredCount[si]-1].uid = ""`，遗漏了 `.sym = ""` 与 `.cmt = ""`。
4. **影响**：破坏了项目规范中"所有淘汰槽位显式解除 MQL 内部全局字符串引用"的内存卫生准则。

---

### OPT-02【中低·状态卫生】`CopierPosTable::Clear()` 遗漏重置 N-03 新增的 `initLots` 字段

#### 源码定位
- `src/Include/Copier/CopierState.mqh:167-196`

#### 机制解析
在 `CopierPosTable::Clear()` 中，对 `used, uid, sym, cmt, side, lots, openPx, sl, tp, ticket, magic, openTime, kind, ptype, pprice, pstop, pexpire, profit, swap` 全部 19 个字段逐一清零，**唯独遗漏了新增的 `m_p[i].initLots = 0.0;`**。虽然现有上层业务多采用全结构赋值覆盖，但若未来通过 `UpdateNumericAt` 复用旧槽位，将残留上笔订单的手数峰值，产生脏状态继承风险。

---

### OPT-03【低·协议规范】`CopierPayloadHbt2` 仍冗余发送 `NAME=` 字段，与文档及设计约束不一致

#### 源码定位
- `src/Include/Copier/CopierCodec.mqh:849-853`

```mql4
string CopierPayloadHbt2(const string role,const long acc,const string name,const long upSeconds)
  {
   // 直接调用了 CopierBuildNodePayload，内含 NAME 拼接！
   return CopierBuildNodePayload(role,acc,name,upSeconds);
  }
```

#### 机制解析
注释第 822 行明确要求：`"HBT2 does not carry NAME: a heartbeat repeating a name that cannot have changed is bytes for nothing"`。当前实现与文档规范相悖，各终端每 5 秒在心跳中无谓重复传输静态终端名称，增加解析与传输开销。

---

### OPT-04【低·通信鲁棒性】XSUB `Subscribe` 饱和静默丢弃计数 & `ConnectReceiver` 重置缺口 & `ConnectExtraHub` 冗余重放

#### 源码定位
- `src/Include/Copier/CopierTransport.mqh:444-455, 484-495, 307-340`

#### 机制解析
1. **`Subscribe` 满表发包**：当 `m_nSubPrefixes >= CP_MAX_XSUB_SUBS (256)` 时，前缀未入表但底层仍调用了 `m_sub.send("\x01"+prefix, true)`。该订阅由于未入表记账，后续 `Unsubscribe` 永远无法退订该前缀。
2. **`ConnectReceiver` 缺少计数重置**：直连模式重建 XSUB socket 时，没有像 `ConnectHub` 那样清空 `m_subPrefixes` 和 `m_subSent`，也没有记录 `m_connectedHubs`。
3. **`ConnectExtraHub` 订阅膨胀**：libzmq 底层在 XSUB socket 执行 `connect(ep)` 时，会自动将已建立的订阅前缀树推送到新管道；MQL 侧再次手动循环重发 `\x01` 导致全网 Hub 收到双倍引用计数。

---

### OPT-05【低·并发鲁棒性】Rust Hub `replace_all()` 重建过程置空 `inner.file` 导致并发写被误判为内存模式而丢失

#### 源码定位
- `hub/src/commands.rs:498-508, 1002-1005`

#### 机制解析
在 Windows 上为了避免文件被占用导致 `atomic_replace_file` 失败，`replace_all()` 主动将 `inner.file = None`。在释放锁执行文件替换到重新打开文件的微秒级窗口期内，如果主线程或 API 线程恰好调用了 `append_many()`，`append_many()` 检测到 `inner.file` 为 `None`，会触发为 `--commands none` 准备的容错分支（`return Ok(())`），使得该条日志被误判为写入成功而实际丢失。

---

## 5. 测试套件盲区分析

### 为什么 MQL 715 项 SelfTest 无法拦截上述缺陷？
1. **BUG-01 盲区**：`CopierSelfTest` 中仅对纯算术函数 `CopierNextInitLots(carry, lots)` 编写了 3 个单元断言（第 3212 行），从未在脚本中模拟过调用 `HandleSnapshot` 时快照数据 UID 发生乱序重排的真实数组状态。
2. **BUG-02 盲区**：测试套件全部基于离线批处理，缺少对 ZMQ 事件接收后 `g_convergeDirty[si]` 标记置位及 `OnTimer` 门禁连通性的集成断言。
3. **BUG-04 盲区**：既有用例测试手数均为 `0.1`、`1.0` 等标准大单，从未覆盖 8 位小数（如 `0.00000020` 手）的加密货币微手数减仓场景。

### 为什么 Rust 172 项单元测试全绿？
1. **BUG-03 盲区**：`test_ack_propagates_journal_error_and_keeps_the_command_pending` 用例只验证了 `s.command(&c.id).unwrap().state == STATE_PENDING`，**遗漏了断言 `s.inner.lock().unwrap().in_flight.contains(&c.id)`**。
2. **BUG-08 盲区**：WebSocket 测试均在理想网络下进行，从未在模拟慢速客户端触发 `Lagged` 丢帧后断言是否收到了全量快照帧。

---

## 6. 排期与无损修复实施建议

按照**"先交易安全、后网络性能、再内存代码卫生"**的优先级，建议分阶段排期处理：

### 阶段一：交易安全与执行延迟加固（紧急修复，最高优先级）
1. **修复 BUG-01**：重构 `HandleSnapshot`，先将所有快照订单的 `carry` 与 `initLots` 计算完成存入 `g_scratch`，查找完全结束后再统一写入 `g_desired`，并在 `CopierSelfTest` 增补"快照 UID 逆序重排下峰值手数不丢失"的自检断言。
2. **修复 BUG-02**：在 `HandleOpenEvent`、`HandleCloseEvent`、`HandleModifyEvent` 处理末尾显式置位 `g_convergeDirty[si] = true;`，打通微秒级事件流驱动。
3. **修复 BUG-03**：将 `commands.rs: ack()` 中的 `inner.in_flight.remove(id)` 移至 `inner.append()` 成功之后，并在单元测试中补齐 `in_flight.contains()` 断言。
4. **修复 BUG-04**：将 `ConvergeSender` 中的 `0.0001` 粗糙容差收敛为 `1e-9`。

### 阶段二：集群容灾与网络遥测优化（中优先级）
1. **修复 BUG-05**：在 `CopierState.mqh: CheckSlot` 中将 `ppriceDiff` 从 `otherDiff` 剔除，终结挂单改价时的 4Hz 快照风暴。
2. **修复 BUG-06**：在 `ConvergeSender` 的 `g_manualClosed` GC 中，对无 SID 的条目实行跨全部 Sender 的联合持有检查。
3. **修复 BUG-07**：在 MT4 `CopierRealizedToday` 中增加冷启动就绪保护，避免盘中重启抹除早盘亏损基线。
4. **修复 BUG-08**：在 Axum WebSocket 捕获 `Lagged` 时主动向客户端下发 `snapshot_text(&st)`。
5. **修复 BUG-09**：在 Standby 写拦截响应中统一附加 `primary` 与 `detail` 引导字段。

### 阶段三：内存卫生与协议精简（常规维护）
1. **修复 OPT-01 & OPT-02**：补齐 `StopsForget`、`MapClear`、`HandleCloseEvent` 的尾部字符串清空，并在 `CopierPosTable::Clear()` 中重置 `initLots = 0.0`。
2. **修复 OPT-03 & OPT-04**：剥离 `CopierPayloadHbt2` 的 `NAME=` 字段，加固 `Subscribe` 与 `ConnectReceiver` 订阅记账逻辑。
3. **修复 OPT-05**：在 `replace_all()` 执行期间设置显式的 `is_replacing` 状态守卫，避免并发写落入内存静默分支。

---
*(报告完毕。本文件由全栈只读审计流程自动生成并归档。)*
