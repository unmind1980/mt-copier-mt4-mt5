# mt-copier 全栈审计（2026-11-08 r4）

只读。未改任何生产代码。单线通读，没有子代理。

本轮源码比 `mt-copier-fullstack-audit-2026-11-08-r3.md` 新（客户端与 hub 均在 11:42–12:21 之后改过）。r3 的 N-01（止损交叉容差）、N-05（10016/130 作废品种缓存）、N-06 的维护 REG / 发送端失败限频，当前代码里已经在。下面只记这一轮新对上的问题，以及明确排除的假阳性。

覆盖：`src/Include/Copier` 全部头、`CopierSender.mq4` 全文件、`CopierReceiver.mq4` 的队列 / 收敛 / 止损 / 快照路由、`hub/src` 的 `main.rs` 转发与收据、`commands.rs`、`cluster.rs` 同步、`positions.rs`、`registry.rs` 节点表、`api.rs` 鉴权与快照推送、`config.rs` journal、`CopierCodec.mqh`。未逐行读 `tls.rs`、`notifications.rs`、`users.rs`、`alerts.rs`、`curve.rs`、`service.rs`、dashboard、Python 套件、Scripts。

---

## 结论

两条会直接做错交易或做错命令状态的问题，都是「单模块正确、组合起来错」。

| 编号 | 严重度 | 一句话 |
|---|---|---|
| N-01 | 高 · 交易 | 手动平仓的 ignore 条目在发送端仍持仓时被 GC 清掉，仓位被重新开回来 |
| N-02 | 高 · Hub | 重试阶梯先改内存、后写盘；写盘失败不回滚，重启后重试次数与 unknown 状态丢失 |
| N-03 | 中 · 看板 | Hub 把快照记录的字段顺序读反，持仓明细的品种/方向/手数错位 |
| N-04 | 低 · 延迟 | 收据去重表在 ZMQ 路由线程上每 60 秒全表扫描，且无容量上限 |
| N-05 | 低 · 延迟 | 看板全量 JSON 仍在 ZMQ 路由线程上序列化（r3 N-03 未消失） |

---

## N-01 手动平仓 ignore 被提前清掉

`CopierManualClosedRing` 的设计是：操作员在接收端平掉一张发送端仍持有的仓，环记住这个 UID，收敛循环不再把它当新开仓。GC 只应在「发送端也不再持有」时删除。

两条路径对不上。

1. `HandleCmd` 的单笔 close 把条目记成 `m_sid = ""`（`CopierReceiver.mq4` 约 7498：`g_manualClosed.Add(uid, ticket, "")`）。`closeall` 路径才写入真实 `g_sid[si]`。
2. GC（同文件约 6465–6498）对空 `m_sid` 走「任一发送端的 desired 里都没有这个 UID，且全部 sender 已 ready」就删除。

`g_desired` 的 UID 来自快照解码。`CopierDecodeRec`（`CopierCodec.mqh:223`）把 `cmt` 写成空串。发送端自己的票号在 `ticket` 字段，不在注释里。所以 `anySenderHolds` 对这个 UID 永远是 false。

结果：

- 多发送端：只要有一个 sender 还没收到第一份快照（`g_ready[s]==false`），整段 GC 直接跳过，ignore 一直留着，这是安全方向。
- 全部 sender 都 ready 之后：空 sid 的条目在**下一个收敛周期**就被删掉。发送端仍持仓时，`ConvergeSender` 约 5940 的 `g_manualClosed.Has(d.uid)` 已经为 false，于是重新排队 OPEN。
- `ReopenClosedMirrors=false` 挡不住这一条。`g_everOpened` 只在本机 `CP_ACT_OPEN` 成功时写入（约 3710）。操作员平掉的是发送端原仓在本机的镜像，未必走过本机 OPEN 成功路径；就算走过，注释写明 everOpened 不是这条路径的权威。

`#t<ticket>` 占位条目走另一支，按本地票是否还在或 15 分钟 TTL 回收，这条是对的。坏的是带真实 8 位 UID、但 sid 为空的那一支。

修法：单笔 close 与 closeall 一样写入所属 `g_sid[si]`；空 sid 的遗留条目不要用「desired 里没有」删除，改成和 `#t` 一样等本地票消失或 TTL。desired 比较必须对解码后的 UID，不能对空的 `cmt`。

---

## N-02 命令重试先改内存、写盘失败不回滚

`CommandStore::ack`（`commands.rs:906`）和 `issue_op` / `issue_cfg` 都是先组出候选，写盘成功再改 `commands` map。`due_gated_with`（约 817–900）不是。

循环里对 `inner.commands.get_mut` 直接：

- `attempts += 1`，`next_at` 推到下一档
- 阶梯走完则 `state = unknown`，`ts = now`，并从 `in_flight` 移除

然后才 `append_many`。失败只打一行日志（约 897）。内存已经是 unknown / attempts=N，磁盘仍是上一次 pending。

`load()` 按 journal 重建 `attempts` 和 `state`。一次 fsync 失败之后：

- 进程还活着：内存以为已经 unknown，不再发；磁盘仍是 pending。
- 重启：从磁盘读回 pending、attempts 回到写盘前的值，阶梯从头再走。注释自己写了为什么 attempts 必须落盘——否则 `closeall` 第三次重试会变回第一次，再空等 2 秒。这里失败路径把这个不变量拆了。
- 更坏的是 unknown 转换：内存已从 `in_flight` 删除，磁盘没有这行。重启后命令复活成 pending，操作员在看板上看到的 timeout 告警对不上重启后的真实状态。

`ack()` 的注释还写「issue_cfg / issue_op / due_gated 都是先落盘再提交」。issue 两条是；due_gated 不是。

修法：与 `ack` 相同——锁内只组候选行，`append_many` 成功后再写回 map 和 `in_flight`；失败则保持原 pending 与原 attempts，下一拍再试。

---

## N-03 Hub 快照明细字段错位

发送端记录（`CopierEncodeRec`，`CopierCodec.mqh:140`）顺序是：

```
UID, TICKET, SYMBOL, SIDE, LOTS, OPENPX, SL, TP, MAGIC, OPENTIME [, KIND...]
```

Hub `parse_snap`（`positions.rs:329`）按：

```
f0=uid, f1=ticket, f2=symbol, 然后 side 用 it.next()（实际是 LOTS）
lots 用下一个（实际是 OPENPX）
```

`side` 读到的是手数字符串（`0.10` → 0，不是 1/-1）。`lots` 读到开仓价（1.0845 被当成手数）。`open_px` 读到止损价。后面 SL/TP/MAGIC/时间整段错一位。`kind` 经常落到 0，挂单被显示成市价单。

看板 `positions_detail` 用的就是这个 `PositionItem`。汇总的 `records` / `lots` 也把开仓价加进了手数，`/nodes` 的 Pos 列会离谱。转发本身仍是原字节，接收端镜像不受影响——坏的是 Hub 的读模型。

Rust 侧如果已有「按这个顺序拆记录」的测试，那个测试和线上编码器不是同一份格式。修解析顺序，并用一条 `CopierEncodeRec` 的真实样例锁住。

---

## N-04 收据去重表无上限，修剪在路由线程

`relay_receipts`（`main.rs:1091`）每 60 秒对 `last_rcpt_relayed` 做一次 `retain`。键是 `(receiver login, sender sid)`。100 个接收端 × 100 个发送端 = 1 万条，每条含两个 String。

- 修剪条件只看「最后一次中继时间 < 600 秒」。一个仍在每秒上报、但被 3 秒去重挡住的 pair 会一直留着。这是对的。
- 没有任何容量上限。伪造或配错的 STAT（`receiver_ok` 在 warm 窗口或空注册表时放行）可以往这张表里塞新键。
- `retain` 跑在 ZMQ 转发线程上，和 OPEN/CLOSE 转发同一条循环。1 万条 String 比较每分钟一次，平时无感；表被撑大之后会在转发路径上打一个可见的停顿。

修法：硬上限（例如 4096），超限时丢掉最旧的；修剪移出路由线程，或只在插入时做 O(1) 淘汰。

---

## N-05 看板序列化仍在转发线程

`main.rs:3375–3386`：`poke_pending` 到期后，转发循环自己调 `api::snapshot_text`，再把 `Arc<String>` 丢进 broadcast。有看板连接时，每次状态变化最多每 200ms 做一次全量 JSON（节点表 + 持仓 + 告警 + 集群）。

snap-worker 里还有一份同样的序列化（约 1958）。两处都在「有订阅者」时做。r3 的 N-03 后半（WebSocket 逐客户端 `(*s).clone()`，`api.rs:854`）也还在：N 个看板 = N 份全量 String 拷贝。

交易转发不会算错，但 OPEN/CLOSE 路径上会多出周期性的分配。把 `snapshot_text` 只留在 snap-worker 或 API 任务里；路由线程只投递版本号。

---

## 本轮排除（不是问题）

- **止损交叉。** `QueueModifyIfNeeded` 已用 `noiseTol = max(3×stopLevel, 10×point)` 区分噪声与真实击穿；击穿过容差走 `CopierFitStop` 夹紧。`local.sl==0` 且配了 `emergencySLPips` 时用紧急止损，不再静默留 0。r3 N-01 已修。
- **平仓 vs 休市。** `ExecuteQueue` 对 CLOSE/TRIM/DEDUP 跳过 `SymbolMarketClosed`。队列里全是非退出动作且判定休市时，`CopierQueueNotePass(..., allMarketClosed=true)` 挂 15 分钟，但 OnTick 仍会唤醒。退出单不会被这 15 分钟卡住。
- **CFG/CMD 水位。** `RouteMessage` 在 `AcceptSeq` 之前拒绝数据通道上的 CFG/CMD。
- **快照 all-or-nothing。** 解码条数与 `N=` 不一致整包拒绝，和 PROTOCOL.md 的 false-close-all 防线一致。Hub 对 `N>0 && records==0` 保留上一份视图。
- **Standby 不跑 `due_gated`。** `main.rs` 约 3284 有 `is_prim` 门。
- **`ack()` 写盘失败。** 失败返回 false，内存保持 pending。问题只在 `due_gated_with`。

---

## 建议顺序

1. N-01：手动平仓 ignore 的 sid 与 GC 规则。这是会把已平仓位开回来的路径。
2. N-02：`due_gated_with` 改成先落盘再提交。补一条「append_many 失败则 attempts 不变、unknown 不生效」的单测。
3. N-03：`parse_snap` 字段顺序与 `CopierEncodeRec` 对齐，用一条真实快照字节锁测试。
4. N-04 / N-05 随下一轮性能改动一起做。
