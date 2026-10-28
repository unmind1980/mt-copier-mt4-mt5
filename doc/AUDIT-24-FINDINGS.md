# mt-copier 全栈代码审查报告

> **审查日期**：2026-10-28
> **代码基线**：`master` @ `305f701`（工作区干净）
> **审查范围**：`src/Experts/*.mq4`、`src/Include/Copier/*.mqh`、`src/Scripts/*.mq4`、`hub/src/*.rs`、`hub/src/assets/dashboard.html`、`tools/*.py|*.sh`
> **代码规模**：约 40,000 行（MQL） + 约 23,500 行（Rust） + 1MB dashboard.html
> **状态**：**本报告仅为排查结论，未修改任何源码**。所有条目均给出 `文件:行号` 与可复现的触发路径。

---

## 0. 审查方法说明

本次审查采用**整文件顺序通读**方式，覆盖：

- **文档层**（13 个 MD，约 9,500 行）：README、PROTOCOL、HANDOFF、CENTRAL-HUB-HA-PLAN/PLAN、PHASE1-DESIGN、PILOT/PILOT-MT4、SNAPSHOT-DEMAND-PLAN、AUDIT-22/23-FINDINGS
- **MQL 层**（约 40,000 行）：CopierReceiver.mq4（8,212 行）、CopierSender.mq4（2,218 行）、CopierSelfTest.mq4（2,676 行）、18 个 Include 头文件
- **Rust Hub 层**（约 23,500 行）：main.rs、api.rs、commands.rs、config.rs、cluster.rs、users.rs、notifications.rs、alerts.rs、registry.rs、positions.rs、curve.rs、envelope.rs、stats.rs、audit.rs、lockx.rs
- **测试套件**：CopierSelfTest.mq4（405+ 断言）、hub 内 #[cfg(test)] 单测（142+）、tools/*.py 契约测试

**已确认无问题的领域**（避免后续重复排查）：

1. 止损距离重锚算法（`CopierMirrorStop`/`CopierMirrorStopInverted`）：方向/符号/反转逻辑正确
2. 快照哈希（FNV-1a 32-bit）编解码 + H= 重算校验：MQL/Rust/Python 三方一致
3. 配置哈希（双 lane FNV-1a 64-bit）：MQL/Rust 互认，向量测试对齐
4. 命令重试阶梯（`RETRY_LADDER_SECS`）+ `defer()` 不消耗阶梯：R58-02 修复正确
5. 会话管理/登录限速/Nonce 防 DoS/常量时间比较：安全模型完整
6. CURVE ZAP handler / allow-list / learn mode / 密钥文件双进程竞态：防护到位
7. SSRF 出站白名单（私网/元数据/CGNAT/IPv6-mapped）：覆盖面广
8. 集群 epoch/role 状态机 + handover + failback：核心逻辑正确
9. `CopierStrBuilder` 成对合并：R60-01 修复正确
10. 命令 journal rank 单调性（`state_rank`）：R60-04 修复正确
11. WebUI DOM 静态化 + 过滤按钮持久化：闪烁问题已根治
12. `CopierNormalizeLot`/`CopierComputeLots`：手数归一化/拒绝语义正确

---

## 1. 逻辑缺陷

### 【P1】F-01 配置热重载后，`inverttrades`/`emergencySLPips` 变更不会触发已持仓镜像的止损重算

**位置**
- `src/Experts/CopierReceiver.mq4:3730-3765`（`QueueModifyIfNeeded` 的几何指纹缓存）
- `src/Experts/CopierReceiver.mq4:3739`（`g_stopSig[sh].epoch == g_stOvEpoch` 判断）
- `src/Experts/CopierReceiver.mq4:3779`（唯一的 `g_stOvEpoch++`，仅在 override 被快照追上时）
- `src/Experts/CopierReceiver.mq4:1348`、`1402`（`g_stOvEpoch++` 已加，本条已闭环）

**问题**

第 23 轮审计 F-01 已指出：`g_stOvEpoch` 仅在 override 被快照追上时自增，配置热重载（`ApplyCommonConfig`/`InitSenderSettings`）后 `inverttrades`/`emergencySLPips`/`emergencyTPPips`/`stopLevel` 变化不会失效缓存。**本次复核确认该问题已修复**（`ApplyCommonConfig` 末尾 1348 行、`InitSenderSettings` 末尾 1402 行均有 `g_stOvEpoch++`）。

**但仍有残余缺口**：`g_stopSig` 几何指纹缓存的签名（`v[0..10]`）**不包含 `g_senderCfg[si].inverttrades`**。当 `inverttrades` 热切换时，`MQL-04` 的运行时检测（4918-4931 行）会关闭并重开镜像，但 `QueueModifyIfNeeded` 的 `actualInverted = (local.side != desired.side)` 派生逻辑与 `g_stopSig` 签名中的 `local.side` 不同步 — 如果 side 被 MQL-04 翻转但 `desired.side` 未变，`g_stopSig` 可能仍缓存旧几何。

**影响**：P1（残余）。仅在 `inverttrades` 热切换 + 已持仓 + `g_stopSig` 命中时触发，且 MQL-04 的 close/reopen 路径会兜底，但可能多付一次 spread。

**建议**：将 `g_senderCfg[si].inverttrades`/`emergencySLPips`/`emergencyTPPips` 三项并入 `g_stopSig` 签名（`v[8..11]`），或在 `ApplyCommonConfig`/`InitSenderSettings` 中对所有 sender 清空 `g_stopSig`（`g_stopSig[sh].ticket=0`）。

---

### 【P1】F-02 `queuedCloseOrTrim` 静态数组在多 sender 并发 converge 时可能残留旧数据

**位置**
- `src/Experts/CopierReceiver.mq4:4862`（`static string queuedCloseOrTrim[CP_MAX_ACTIONS];`）
- `src/Experts/CopierReceiver.mq4:4863-4876`（填充与 `g_qCloseIdx.BuildFromStrings`）

**问题**

`queuedCloseOrTrim` 是 `static` 局部数组，在 `ConvergeSender` 入口填充。但 `ConvergeSender` 是**按 sender 循环调用**的（OnTimer 7842 行 `for(int i=0;i<g_nSenders;i++) ConvergeSender(i);`）。每次调用都会：

1. 重置 `queuedCloseOrTrimCount=0`（4863 行）
2. 遍历 `g_q` 填充本次 sender 的 CLOSE/TRIM UID（4866-4874 行）
3. 调用 `g_qCloseIdx.BuildFromStrings(queuedCloseOrTrim, queuedCloseOrTrimCount)`（4878 行）

`BuildFromStrings` 会重建哈希索引，**但不会清除 `queuedCloseOrTrim` 数组本身**。如果 sender A 的 converge 填充了 `queuedCloseOrTrim[0..2]`，sender B 的 converge 填充 `queuedCloseOrTrim[0..1]`，则 `queuedCloseOrTrim[2]` 仍保留 sender A 的 UID。虽然 `queuedCloseOrTrimCount=1` 时 `BuildFromStrings` 只读 `queuedCloseOrTrim[0..1]`，但 `FindInStrings(queuedCloseOrTrim, uid)` 的实现（`CopierState.mqh`）是否严格按 `count` 边界遍历？

**验证**：查看 `FindInStrings` 实现（`CopierState.mqh:789-820`）：

```cpp
int FindInStrings(const string &arr[],const int n,const string uid) const
  {
   // ...
   for(int i=0;i<n;i++)
     {
      if(arr[i]==uid) return i;
     }
   return -1;
  }
```

严格按 `n` 遍历，**不会越界读旧数据**。但 `queuedCloseOrTrim` 数组本身在 `CP_MAX_ACTIONS`（256）槽位上**永远不会被清空**，长期运行后字符串引用堆积。

**影响**：P2（内存泄漏隐患，非逻辑错误）。每个 `string` 槽位长期持有旧 UID 引用，GC 不会回收。

**建议**：在 `ConvergeSender` 入口（4863 行）增加 `ArrayInitialize(queuedCloseOrTrim,"")`，或改用 `static string queuedCloseOrTrim[CP_MAX_ACTIONS]; ArrayResize(queuedCloseOrTrim,0);` 后按需增长。

---

### 【P1】F-03 `g_fillGraceRing` 的 `GetTime` 在未命中时返回 0，与"从未设置"不可区分

**位置**
- `src/Include/Copier/CopierState.mqh:565-580`（`GetTime`）
- `src/Experts/CopierReceiver.mq4:4947-4960`（`PendingFillGraceSeconds` 逻辑）

**问题**

`GetTime(key)` 在 key 不存在时返回 `0`，在 key 存在但 `m_t[i]==0` 时也返回 `0`。`CopierReceiver.mq4:4952` 判断：

```cpp
long firstMs=g_fillGraceRing.GetTime(graceKey);
if(firstMs==0)
  {
   g_fillGraceRing.Add(graceKey);
   g_log.Info("uid "+d.uid+" ... waiting up to "+...);
   continue;
  }
else if(nowMs-firstMs < (long)(graceSec*1000.0))
  {
   continue; // still within grace window
  }
```

`CopierNowMs()` 是 `GetTickCount()`，在终端启动后可能为 `0`（前几毫秒）。如果 `g_fillGraceRing.Add(graceKey)` 在 `CopierNowMs()==0` 时执行，则 `m_t[i]=0`，下一次 `GetTime` 返回 `0`，逻辑重新走 `firstMs==0` 分支，**无限重置宽限窗口**。

**影响**：P2（边界条件）。仅在终端启动后 `PendingFillGraceSeconds` 窗口内挂单触发时可能出现，且 `GetTickCount()` 为 0 的窗口极短（<1ms）。但长期运行中 `GetTickCount()` 在 2^32 毫秒（约 49.7 天）后回绕到 0，此时同样触发。

**建议**：`GetTime` 返回 `-1` 表示未命中（区别于 `0` 表示命中但时间戳为 0），或在 `Add` 时强制 `m_t[i]=MathMax(1, CopierNowMs())`。

---

### 【P1】F-04 `StopsPrune` 的 `PruneSenderPeakLots` 在遍历中修改数组导致遗漏

**位置**
- `src/Experts/CopierReceiver.mq4:5695`（`PruneSenderPeakLots` 调用）
- `src/Experts/CopierReceiver.mq4:866-890`（`PruneSenderPeakLots` 实现）

**问题**

`PruneSenderPeakLots`（866-890 行）：

```cpp
void PruneSenderPeakLots()
  {
   for(int i=g_uidPeakLotsCount-1;i>=0;i--)
     {
      string uid=g_uidPeakLots[i].uid;
      bool isAlive=false;
      for(int s=0;s<g_nSenders;s++)
        {
         int base=s*CP_MAX_POSITIONS;
         for(int d=0;d<g_desiredCount[s];d++)
           {
            if(g_desired[base+d].uid==uid) { isAlive=true; break; }
           }
         if(isAlive) break;
        }
      if(!isAlive)
        {
         for(int k=0;k<g_acctAllPosCount;k++)
           {
            if(g_acctAllPos[k].uid==uid) { isAlive=true; break; }
           }
        }
      if(isAlive) continue;
      int last=g_uidPeakLotsCount-1;
      string moved=(i!=last)?g_uidPeakLots[last].uid:"";
      g_uidPeakLots[i]=g_uidPeakLots[last];
      g_uidPeakLots[last].uid="";
      g_uidPeakLots[last].peakLots=0.0;
      g_uidPeakLotsCount--;
     }
  }
```

**倒序遍历 + 交换压缩**的模式是正确的（`i` 递减，交换 `last` 到 `i` 后 `count--`，`last` 的内容移到 `i` 位置，下一次迭代检查 `i-1`）。但注意 `moved` 变量（885 行）**从未被使用**——它记录了被移动的 UID，但后续没有任何代码更新 `g_peakLookup` 哈希索引。

`g_peakLookup`（836-855 行）是 `PeakFind` 的哈希索引：

```cpp
int PeakFind(const string uid)
  {
   if(StringLen(uid)!=CP_UID_LEN) return -1;
   uint h=2166136261;
   for(int c=0;c<CP_UID_LEN;c++) { h^=(uint)StringGetCharacter(uid,c); h*=16777619; }
   int s=(int)(h&(CP_PEAK_LOOKUP-1));
   for(int p=0;p<CP_PEAK_LOOKUP;p++)
     {
      int k=(s+p)&(CP_PEAK_LOOKUP-1);
      int c=g_peakLookup[k];
      if(c==0) return -1;
      if(c>0 && c<=g_uidPeakLotsCount && g_uidPeakLots[c-1].uid==uid) return c-1;
     }
   return -1;
  }
```

`PruneSenderPeakLots` 交换压缩后，`g_peakLookup` 中的索引指向**旧位置**，但 `g_uidPeakLots[c-1].uid` 已被覆盖为另一个 UID。`PeakFind` 的命中验证（`g_uidPeakLots[c-1].uid==uid`）会失败并继续探测，**但探测链上的后续条目仍指向正确位置**，所以 `PeakFind` 最终会通过线性回退找到正确条目（或返回 -1）。

**影响**：P2（性能退化，非正确性）。`g_peakLookup` 哈希索引在 `PruneSenderPeakLots` 后部分失效，`PeakFind` 退化为线性扫描（最坏 O(CP_PEAK_LOOKUP)）。第 23 轮审计 F-03 已指出 `CopierBackoff::Clear` 的同类问题（已修复为 `EraseHashSlot` backward-shift），但 `PruneSenderPeakLots` 的同类问题未修。

**建议**：在 `PruneSenderPeakLots` 的交换压缩后调用 `g_peakLookup` 重建（`ArrayInitialize(g_peakLookup,0)` + 重新哈希所有存活条目），或改用与 `CopierBackoff::EraseHashSlot` 相同的 backward-shift deletion。

---

### 【P1】F-05 `CopierTradingTimes::DayOfWeek7` 使用 UTC 算术，与 R48-05 的 `TimeToStruct` 修复不一致

**位置**
- `src/Include/Copier/CopierFilter.mqh:307-309`（`SecOfDay`/`DayOfWeek7`）
- `src/Include/Copier/CopierModel.mqh:279-290`（`CopierServerDayStart`，R48-05 已改用 `TimeToStruct`）
- `src/Include/Copier/CopierSymbol.mqh:80-85`（`CopierInTradingSession`，R48-07 已改用 `TimeToStruct`）

**问题**

R48-05/R48-07 修复了 `CopierServerDayStart` 和 `CopierInTradingSession` 的时区问题（改用 `TimeToStruct` 提取券商服务器当地日的 `day_of_week` 和 `secOfDay`）。但 `CopierTradingTimes::DayOfWeek7`（Filter.mqh:308-309）**仍使用 UTC 算术**：

```cpp
static int DayOfWeek7(const datetime t)
  { return (int)((((long)t/86400)+4)%7); }
```

`datetime` 是 UTC 时间戳，`(t/86400+4)%7` 计算的是 **UTC 的星期几**。券商服务器时间（如 EET UTC+3）的星期几在 UTC 午夜前后 3 小时内会与 UTC 不同。

**影响**：P1。对 EET 券商，UTC 21:00-24:00（券商当地 00:00-03:00）期间，`DayOfWeek7` 返回的星期几比券商当地时间**晚一天**。`DayTradingTimes` 配置的跨日时段（如 `Mon=22:00-24:00;Tue=00:00-02:00`）在 UTC 21:00-24:00 期间会错误地用周一的规则判断（实际券商已是周二凌晨）。

**复现**：EET 券商（UTC+3），`DayTradingTimes="Mon=22:00-24:00;Tue=00:00-02:00"`，UTC 2026-10-27 21:30（券商 2026-10-28 00:30 周二）。`DayOfWeek7` 返回 1（周一），`SecOfDay` 返回 78300（21:45 UTC），`Allows()` 检查 `m_daySet[1]`（周一）的 `22:00-24:00` → 21:45 不在 22:00-24:00 内 → 返回 false。但券商实际是周二 00:30，应检查 `m_daySet[2]`（周二）的 `00:00-02:00` → 应返回 true。

**建议**：`DayOfWeek7`/`SecOfDay` 改用 `TimeToStruct` 提取 `dt.day_of_week` 和 `dt.hour*3600+dt.min*60+dt.sec`，与 R48-05/R48-07 保持一致。同时更新 `TestTradingTimes`（SelfTest:2279）中的 `datetime` 测试向量（当前用 `86400*4` 作为"周一午夜"是 UTC 算术，与 `TimeToStruct` 的券商本地时间语义不符）。

---

### 【P1】F-06 `CopierRealizedToday` MT4 分支遗漏 `OrderCommission` 的 `OrderSwap` 分离计费

**位置**
- `src/Include/Copier/CopierModel.mqh:258-267`（MT4 分支）

**问题**

MT4 分支：

```cpp
sum+=OrderProfit()+OrderSwap()+OrderCommission();
```

MT5 分支（252-256 行）：

```cpp
sum+=HistoryDealGetDouble(t,DEAL_PROFIT)
    +HistoryDealGetDouble(t,DEAL_SWAP)
    +HistoryDealGetDouble(t,DEAL_COMMISSION)
    +HistoryDealGetDouble(t,DEAL_FEE);
```

MT5 分支包含 `DEAL_FEE`（手续费），MT4 分支遗漏。MT4 的 `OrderCommission()` 是否包含 fee？MQL4 文档说 `OrderCommission()` 返回佣金，**不含手续费**（手续费在部分券商中单独计费，通过 `OrderProfit()` 间接包含或完全不体现）。

**影响**：P2。仅影响日亏风控基准（`balance - realizedToday`）的精确性。遗漏 fee 会导致基准偏高，日亏开关略微提前触发（保守方向）。

**建议**：MT4 分支无法直接获取 fee（MQL4 无 `DEAL_FEE` 等价物），但可在注释中标注此偏差，或在 `RefreshRisk` 中对 MT4 平台额外扣除当日出入金（已在 R48-06 中通过 `cashFlow` 校准缓解）。

---

### 【P1】F-07 `EncodeReceiverWaitList` 的 `g_q[g_qHead+i].pprice` 对市价单无意义

**位置**
- `src/Experts/CopierReceiver.mq4:4488-4500`（`EncodeReceiverWaitList`）

**问题**

```cpp
string rec=g_q[g_qHead+i].uid+CP_SEP_ITEM
           +g_q[g_qHead+i].sym+CP_SEP_ITEM
           +(string)g_q[g_qHead+i].side+CP_SEP_ITEM
           +CopierFmtDouble(g_q[g_qHead+i].lots,2)+CP_SEP_ITEM
           +CopierFmtDouble(MathMax(0.0,g_q[g_qHead+i].pprice),5)+CP_SEP_ITEM
           +"queued"+CP_SEP_ITEM
           +"Queued in broker dispatch";
```

对于 `CP_ACT_OPEN` 的市价单（`ordKind==CP_ORD_MARKET`），`pprice` 为 `0.0`（未设置）。`MathMax(0.0, 0.0)` = `0.0`，`CopierFmtDouble(0.0, 5)` = `"0"`。WebUI 的等待列表会显示市价单的"入场价"为 `0`，具有误导性。

**影响**：P3（展示问题，非交易逻辑）。WebUI 等待列表中市价单的 `open_px` 显示为 `0`。

**建议**：市价单的 `pprice` 字段传 `0` 并在 WebUI 中显示为 `"-"`，或改传 `desired.openPx`（发送端入场价，仅作参考）。

---

## 2. 性能与可扩展性

### 【P2】F-08 `EncodeReceiverPositions`/`EncodeReceiverWaitList` 每分钟一次 O(n²) 字符串拼接（第 23 轮 F-02 已修，但 `EncodeReceiverWaitList` 仍是 `sb.Add` 循环）

**位置**
- `src/Experts/CopierReceiver.mq4:4488-4520`（`EncodeReceiverWaitList`）

**问题**

第 23 轮审计 F-02 已指出 `EncodeReceiverPositions`/`EncodeReceiverWaitList` 使用 `out+=` 导致 O(n²) 拷贝。本次复核确认 `EncodeReceiverPositions`（4442-4486 行）**已改用 `CopierStrBuilder`**（B1 优化落地）。但 `EncodeReceiverWaitList`（4488-4520 行）**也已改用 `CopierStrBuilder`**（`sb.Add` 循环）。

但 `EncodeReceiverWaitList` 的 `g_q` 遍历部分（4490-4505 行）**每条记录仍做 7 次 `g_q[g_qHead+i]` 数组访问 + 6 次字符串拼接**：

```cpp
string rec=g_q[g_qHead+i].uid+CP_SEP_ITEM
           +g_q[g_qHead+i].sym+CP_SEP_ITEM
           +(string)g_q[g_qHead+i].side+CP_SEP_ITEM
           +CopierFmtDouble(g_q[g_qHead+i].lots,2)+CP_SEP_ITEM
           +CopierFmtDouble(MathMax(0.0,g_q[g_qHead+i].pprice),5)+CP_SEP_ITEM
           +"queued"+CP_SEP_ITEM
           +"Queued in broker dispatch";
```

`CopierAction` 结构体的 `uid`/`sym` 是 `string` 成员，每次 `g_q[g_qHead+i].uid` 都是结构体数组访问 + 字符串引用。MQL 的结构体数组访问本身是 O(1)，但字符串成员的引用计数操作（复制/释放）在 MQL 中是隐式成本。

**影响**：P3。`g_qn` ≤ 256，每分钟一次，最坏 256×7 ≈ 1,800 次字符串操作，可忽略。

**建议**：无需修改，已达标。

---

### 【P2】F-09 `StopsPrune` 每 60 秒对 `g_uidPeakLots` 做 O(n×m×k) 扫描

**位置**
- `src/Experts/CopierReceiver.mq4:5691-5745`（`StopsPrune`）
- `src/Experts/CopierReceiver.mq4:866-890`（`PruneSenderPeakLots`）

**问题**

`StopsPrune`（每 60 秒调用一次）内部调用 `PruneSenderPeakLots`，后者对每个 `g_uidPeakLots[i]` 遍历所有 `g_desired[base+d]`（`g_nSenders × g_desiredCount[s]`）和 `g_acctAllPos[0..g_acctAllPosCount]`。最坏情况：100 senders × 2048 desired + 2048 acctAllPos × `g_uidPeakLotsCount`（≤2048）= 约 4 亿次字符串比较。

**影响**：P2。60 秒一次，但 100 senders × 2000 positions 的极端场景下每次扫描约 4 亿次比较，在 1GHz VPS 上约 1-2 秒，可能阻塞 EA 主线程。

**建议**：`PruneSenderPeakLots` 改用与 `g_desIdx`/`g_locIdx` 相同的哈希索引（`CopierUidIndex`），将 O(n×m) 降为 O(n+m)。

---

### 【P2】F-10 `Snapshot` 解码后 `GetOrUpdateSenderPeakLots` 对每条记录做 O(n) 线性查找

**位置**
- `src/Experts/CopierReceiver.mq4:5627`（`HandleSnapshot` 中的 `GetOrUpdateSenderPeakLots`）
- `src/Experts/CopierReceiver.mq4:851-935`（`GetOrUpdateSenderPeakLots`/`PeakFind`）

**问题**

`HandleSnapshot` 对快照中的每条记录调用 `GetOrUpdateSenderPeakLots(uid, lots)`（5627 行），后者内部调用 `PeakFind(uid)`。`PeakFind` 使用 `g_peakLookup` 哈希索引（836-855 行），但 `g_peakLookup` 在 `PruneSenderPeakLots` 后部分失效（见 F-04），退化为线性扫描。

**影响**：P2。2048 条记录 × 最坏 O(CP_PEAK_LOOKUP=4096) 线性扫描 = 800 万次比较/快照。快照频率 15 秒一次，约 53 万次/秒。

**建议**：修复 F-04（`g_peakLookup` 重建）后，此问题自动缓解。

---

## 3. 安全与鲁棒性

### 【P1】F-11 `CopierDecodeSnapshot` 的 `N=0` 与 `R=` 空值边界检查不完整

**位置**
- `src/Include/Copier/CopierCodec.mqh:538-547`（`N=0` 分支）

**问题**

```cpp
if(countLong==0)
  {
   string recsCheck="";
   if(CopierKvGet(payload,"R",recsCheck) && StringLen(recsCheck)>0)
     {
      if(recsCheck!="0:" && recsCheck!="1:") return -1;
     }
   return 0;
  }
```

`recsCheck!="0:" && recsCheck!="1:"` 检查的是**前缀**，但 `R=` 的值可能为 `"0:"` 或 `"1:"`（仅前缀，无实际内容）。如果 `R=0:AAAA1111,1,EURUSD,...`（前缀 + 记录），`recsCheck` 为完整字符串 `"0:AAAA1111,1,EURUSD,..."`，不等于 `"0:"`，会被拒绝 — 这是正确的（`N=0` 不应携带记录）。

但 `R=0:`（仅前缀，无记录）时，`recsCheck=="0:"`，**通过检查并返回 0**。这与 `R=`（空值）的语义一致（无记录），正确。

**但**：`R=1:XXXX...`（压缩但解压后为空）时，`recsCheck=="1:XXXX..."`，不等于 `"1:"`，会被拒绝。而实际解压后可能为 0 条记录（空快照），应返回 0 而非 -1。

**影响**：P3。空快照用 `R=1:`（压缩空内容）编码时会被误拒。但 `CopierEncodeSnapshot` 在 `count==0` 时**不写 `R=` 字段**（498-501 行），所以此场景不会出现。仅在第三方构造的畸形快照中可能触发。

**建议**：无需修改，现有编码器不会产生此场景。

---

### 【P2】F-12 `CopierKvGet` 的 `StringFind` 从头扫描，对长 payload 是 O(n×m)

**位置**
- `src/Include/Copier/CopierDefs.mqh:752-780`（`CopierKvGet`）

**问题**

`CopierKvGet` 每次调用都从 `payload` 开头 `StringFind` 扫描，找到第一个 `key=` 后验证前缀是否为 `;` 或开头。对 STAT payload（约 500-1000 字符，含 15-20 个 key），每个 `CopierKvGet` 调用最坏扫描 1000 字符。

`HandleSnapshot` 对每条快照记录调用 `CopierKvGet` 10 次（UID/TKT/SYM/SIDE/LOTS/OPN/SL/TP/MAGIC/OTS），2048 条记录 = 20,480 次 × 1000 字符 = 2000 万次字符比较/快照。

**影响**：P2。快照频率 15 秒一次，约 133 万次/秒字符比较。在 1GHz VPS 上约 10-20ms/快照。

**建议**：`HandleSnapshot` 改用 `CopierDecodeRec` 的单遍扫描（已优化为 `StringSplit` 替代，见第 22 轮 B2），或为 `CopierKvGet` 增加 `startPos` 参数支持增量扫描。

---

## 4. 测试套件缺口

### 【P3】F-13 `TestTradingTimes` 的测试向量使用 UTC 算术，与 F-05 的修复不一致

**位置**
- `src/Scripts/CopierSelfTest.mq4:2285`（`datetime monMidnight=(datetime)(86400*4);`）

**问题**

测试用 `86400*4` 作为"周一午夜"，这是 UTC 算术（1970-01-01 是周四，+4 天 = 周一）。但 F-05 修复后 `DayOfWeek7` 将改用 `TimeToStruct`，此时 `86400*4` 对应的 `TimeToStruct.day_of_week` 取决于终端的时区设置，**测试结果不确定**。

**影响**：P3。F-05 修复后需同步更新测试向量（用 `StringToTime("2026-10-27 00:00")` 或明确时区的 datetime）。

**建议**：F-05 修复时同步更新 `TestTradingTimes` 的所有 `datetime` 向量。

---

### 【P3】F-14 `TestR47R48Regressions` 未覆盖 R60-01（`CopierStrBuilder` 成对合并）

**位置**
- `src/Scripts/CopierSelfTest.mq4:2558-2617`（`TestR47R48Regressions`）

**问题**

R60-01（`CopierStrBuilder::Result()` 成对合并时 `m_parts[0]` 被过早清空）是 P0 级缺陷，修复后**无回归测试**。`TestSnapshot` 中的 `CopierEncodeSnapshot` 使用 `CopierStrBuilder`，但测试数据量小（3 条记录 < 4KB），不会触发 `>=2 chunks` 的路径。

**影响**：P3。R60-01 修复正确，但无测试防止回归。

**建议**：在 `TestR47R48Regressions` 中增加：

```cpp
CopierStrBuilder sb;
for(int i=0;i<1000;i++) sb.Add("0123456789");  // 10KB > 2 chunks
string r=sb.Result();
Ok("strbuilder: large string survives pairwise merge",StringLen(r)==10000);
```

---

## 5. 建议修复优先级

| 批次 | 项 | 预计改动量 | 风险 |
|---|---|---|---|
| 第 1 批 | F-05（`DayOfWeek7`/`SecOfDay` 改用 `TimeToStruct`） | 10 行 + 测试向量 | 低 |
| 第 2 批 | F-04（`PruneSenderPeakLots` 后重建 `g_peakLookup`） | 5 行 | 低 |
| 第 3 批 | F-03（`GetTime` 返回 -1 区分未命中） | 5 行 | 低 |
| 第 4 批 | F-02（`queuedCloseOrTrim` 入口清空） | 2 行 | 低 |
| 第 5 批 | F-01（`g_stopSig` 签名扩展） | 5 行 | 低 |
| 第 6 批 | F-13/F-14（测试补充） | 20 行 | 无 |

---

## 6. 附：复现与验证建议

1. **F-05**：EET 券商 + `DayTradingTimes="Mon=22:00-24:00;Tue=00:00-02:00"`，UTC 21:30 运行，检查 `Allows()` 返回值是否正确。
2. **F-04**：配置 100 senders × 20 positions，触发 `StopsPrune`，观察 `g_uidPeakLotsCount` 与 `PeakFind` 命中率。
3. **F-03**：终端启动后 1ms 内触发 `PendingFillGraceSeconds`，观察宽限窗口是否无限重置。
4. **F-02**：配置 2 senders，观察 `queuedCloseOrTrim` 数组长期运行后字符串引用数。
5. **F-01**：热切换 `inverttrades`，观察已持仓镜像的止损是否重算。

---

*报告完毕。所有条目均为排查结论，未修改任何源码。*
