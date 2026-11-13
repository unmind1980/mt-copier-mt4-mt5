# mt-copier 全栈审计报告

- **审计日期**：2026-11-03
- **代码基线**：`89589ce` — `fix: resolve audit-84 findings across command retry replication, manual closed gc, and tls concurrency`
- **审计范围**：仓库内 20 份 Markdown（含历史审计和设计记录）；`src/Experts`、`src/Include/Copier`、`src/Scripts` 中 MQL4/MQL5 共享源码；`hub/src` 全部 Rust 模块；`tools` Python 契约测试和构建/测试入口。
- **审计方式**：单人跨模块只读代码审查；未使用子代理，未修改程序源码。
- **结论摘要**：当前实现覆盖面很高，核心快照验证、停止距离重锚、人工平仓抑制、命令/配置 journal 和 HA 同步都有针对性护栏。复核第 71–84 轮后，没有把历史已修复项目重新报成缺陷。本轮确认 **2 项值得修复的确定性问题**、**2 项需要补齐的高风险正确性缺口**，以及若干不阻断运行的维护/测试改进。

---

## 1. 执行与验证结果

| 项目 | 结果 |
|---|---|
| `bash tools/tests.sh` | **全部通过**。可见 14 个带 PASS 汇总的 Python 套件共 **445 项 PASS、0 FAIL**；另有 6 个无摘要行的脚本（`hub_proto_test.py`、`zmq_topic_test.py`、`ha_probe_test.py`、`hub_cluster_test.py`、`ha_chaos_test.py`、`inputcheck.py`）以退出码通过，但 runner 对其不显示断言总数。`dash_check.py`：252 IDs、138 functions 检查通过；`toolchain_check.py` 通过。 |
| `bash hub/build.sh --test` | **158 passed; 0 failed; 0 ignored**。有一条非阻断编译 warning：`hub/src/tls.rs` 的 `TempChallengeServer.port` 未读取。 |
| MT4/MT5 编译 | 本轮未运行 MetaEditor / 四终端构建，因此不声明本轮 MQL 编译通过。项目日志中的历史 `ALL GREEN` 不等于本轮验证。 |
| 仓库状态 | 程序源码无改动。原有用户修改 `data/certs/hub.pfx` 和 `tls_config.json` 保留未动；测试脚本会删除两个受跟踪夹具 `_test_audit_notif.json`、`_test_audit_users.json`，已恢复到 Git 基线。 |

> `tools/tests.sh` 显示的套件总量是按实际本轮输出计数，不把没有 `pass=` 汇总行的脚本虚报成某个猜测的断言数。测试入口没有运行 `--all`，所以此处的 Rust 状态来自单独的 `hub/build.sh --test`，不是 `tests.sh --all`。

---

## 2. 确定问题

### F-01 — 【P1】standby 命令增量同步忽略 journal 写入失败，仍把内存态报告成已同步

**位置**：`hub/src/commands.rs:358-449`，尤其 `439`；消费者 `hub/src/cluster.rs:734-746, 823-829`。

`CommandStore::apply_delta_lines()` 已将高水位/状态更新到 `inner.commands` 和 `inner.in_flight`，然后调用 `inner.append_many(&to_append)`；该函数返回 `bool`，但调用点丢弃返回值，依旧返回 `Ok(applied)`。若 standby 磁盘满、被占用或写失败：

1. standby 内存 `commands` 已前进，但 journal 文件仍是旧状态；`line_count` 在失败时回退，`max_seq` 却在 `append_many` 的写入前已更新；
2. `cluster.rs` 对增量分支又忽略 `apply_delta_lines()` 的 `Result`，且 `file_sync_err` 不会被设置；
3. 同一个 sync response 后续无论增量是否落盘，都可能把 `sync_status` 写成 `synced`（823–829）；
4. 重启后内存差异消失，命令又从旧 journal 载入。涉及 `closeall` 等操作时，operator 看到已同步/已接管，但 standby 并未持久化它收到的命令状态。

**影响 / 自愈**：目前 `line_count` 若落后，下一轮比较有机会再次触发补同步；但“成功同步”的状态在期间是错误的，且 `max_seq` 前进与 journal 未写的组合会改变下次选择的同步路径。对 HA 命令持久化属于正确性缺口，定 **P1**；不把它升到 P0，因为未发现直接改写交易执行端的路径。

**建议**：将追加写失败向 `apply_delta_lines()` 传播为 `Err`，让 worker 置 `sync_err` 并保留明确错误；只有 journal append + durability barrier 成功后再发布内存态和水位。补一个模拟追加写失败的测试，断言内存和同步状态不会谎报成功。

---

### F-02 — 【P2】HA epoch 的 `+1` 使用普通整数加法，`u64::MAX` 可在 release 构建溢出并终止 worker

**位置**：
- `hub/src/cluster.rs:329-334`：`promote(None)` 使用 `self.state.epoch + 1`。
- `hub/src/cluster.rs:934-935`：自动 failback 的 `max(...)+1`。
- `hub/src/api.rs:3468-3470`、`3603-3607`：人工 promote / failback 同类计算。
- `hub/src/api.rs:3409-3410`：handover 的 epoch 路径。

启动/状态文件中的 epoch 是 `u64`；在 release profile，普通整数溢出会环绕。`u64::MAX` epoch 可来自持久化的集群状态 JSON（`load_or_create` 反序列化既有状态），而不是只来自 wire。到任一 `+1` 位置时会从最大值回到 0；debug/test 则 panic。后台 cluster worker panic 后，该 hub 将不再执行 HA 探测/同步/回切，或管理 API 的该次请求失败。

**影响 / 自愈**：正常部署几乎不可能自然积累到此值，但损坏/人为配置的 `cluster_state.json` 可触发；epoch 是 fencing 核心元数据，安全处理必须定义。定 **P2**。

**建议**：集中实现 checked/saturating epoch increment；在加载状态时拒绝无效或已耗尽 epoch 并给出明确启动错误。测试 `u64::MAX` 及边界转换，保证不能 wrap 到低 epoch。

---

## 3. 高风险正确性缺口（建议列为高优先级补测/设计确认）

### F-03 — 【P1，需业务决策】多 Hub 共用的 XSUB uplink 按“发送两份”假定 round-robin 均分；故障时/连接管线不对称可能使关键控制帧两份都进同一 Hub

**位置**：`src/Include/Copier/CopierTransport.mqh:479-528`；相关拓扑：`src/Experts/CopierSender.mq4:891-980`、`CopierReceiver.mq4:7369-7405`。

双 Hub `@` 控制消息复制两次的实现，建立在 XSUB 多 pipe 的轮询发送行为上，希望两份分别抵达主备。代码明确将“两个 send 落到两个 hub”作为设计保证，但单条调用只检查 `sendMore(topic)` 和 `send(payload)` 的即时结果，不能确认每一条完整 multipart 最终发给了哪个已连接 pipe。不同 endpoint 的 connect 握手时序、其中一条链路离线/重连、HWM 背压、上一次 multipart 半失败等情况下，copy 计数并不等于“Primary 和 Standby 各收到一份”。

目前数据面有双路广播及 receiver SEQ 去重，控制面则更敏感：例如 `ACK` 只由 Primary 消费并更新命令状态；若该份只到 Standby，Primary 会走重试到 `unknown`。`REG` 虽有重复注册/WHO 自愈，但管理状态存在收敛延迟。

**注意**：这不是说当前双 send 在正常稳定状态一定失效；问题是代码把 ZMQ 发送调度当作可靠的角色寻址/fanout，却没有做端到端证据。`doc/PROTOCOL.md` 和 HA 设计文档自身都把 uplink round-robin 当成既定测量结果，本轮 `tools/tests.sh` 不涵盖双 Hub 一条失联/一条重连/连接建立不同步的控制面混沌场景。

**建议**：把 control uplink 设计为明确的主备寻址和确认机制，或验证并记录每条链路都可送达的协议保证；至少在 chaos test 中分别 kill/reconnect 一个 Hub，并对 REG、STAT/RCPT、ACK、CFG/CMD 逐一核对主备日志与 journal 状态。不要只凭发两次推断一次/每端。

---

### F-04 — 【P1，覆盖缺口】receiver 的“解码数必须等于 `N=`”误平仓保护只有解码器单测，没有实际触发 Converge 门禁的测试

**位置**：`src/Experts/CopierReceiver.mq4:5685-5831`（`HandleSnapshot`），资金执行消费者 `ConvergeSender()`；MQL fixture 在 `src/Scripts/CopierSelfTest.mq4:135-230`。

代码中的核心门禁当前存在且逻辑上看似正确：先校验 `N=`、有 `H=` 时校验摘要，再要求 `n == min(N, CP_MAX_POSITIONS)`，在通过后才替换 `g_desired` / 置 `g_ready`。但是 SelfTest 只覆盖 `CopierDecodeSnapshot()` 和编解码往返；它没有调用 EA 中的 `HandleSnapshot`，也没有断言 `N` 与解析结果不符时 `g_desired` 保持旧值、`g_snapHash` 不前进、不会排 CLOSE。Python `snapshot_repair_test.py` 是纯 Python 复刻，也不执行 MQL 消费函数。

这条闸门的故障后果是有效快照被拒后收敛不再应用；错误放行则可能把未解出的 UID 当作 sender 已平，进而排平仓。历史测试报告也指出这是主要资金安全测试空白，但这轮未把“无测试”等同“当前实现有 bug”。

**建议**：把纯判定部分抽为 MQL 可测函数并让 SelfTest 驱动；至少覆盖缺 N、坏 H、解压失败、N 大/小于实解码数、`N>CP_MAX_POSITIONS` 的合法截断，以及 rejection 后 `desired/hash/close queue` 不变化。再保留至少一条 MT4/MT5 集成验证。

---

## 4. 性能与可维护性改进

### O-01 — 【P2】风险全平路径仍可能每秒全账户扫描并重复排队

**位置**：`CopierReceiver.mq4:4780-4860, 4869-4874, 8080-8100`。

首次风险触发后，`RiskCloseEverything()` 仅在 `CloseAllOurs()` 报 queue-full 时设置 `g_riskCloseAllPending=true`。若进入 queue 的 CLOSE 后由 broker 失败并从队列移除（由 backoff 暂缓），而 `failedCount` 初次为 0，`g_riskCloseAllPending` 可能没有开启；队列的逐 UID失败重试依靠 Converge/新快照再派生。另一条路径是 queue-full，此时背景任务每 1 秒重新读取全账户持仓并扫描所有 sender。可针对“queue-full 一次后大量 CLOSE 失败/重试”的压力场景测量重复扫描、队列占用和关闭延迟。当前看到 64 close actions/tick、1s retry throttle，因此不是无界 CPU，但超大账户下是可避免的 O(account positions × retry cadence) 工作。

**建议**：让全平操作维持显式的待完成状态，按未关闭 ticket/UID 增量追踪，而非每秒全表重扫；测试并报告上限内的关闭时长和满队列恢复行为。仅作为优化，不称现有行为已必然丢失平仓。

### O-02 — 【P2】Python 契约测试 runner 对未打印汇总的脚本只显示“ran”，测试通过信息不可审计

**位置**：`tools/tests.sh:95-119`。

Runner 对所有测试统一尝试找 `pass=`，找不到时输出 `ran (no summary line)`。因此 `hub_proto_test.py`、`zmq_topic_test.py`、HA probe/chaos/cluster 等通过退出码的脚本，其断言个数/测试输出被隐藏；失败时虽然会显示 tail，但成功时看不到断言数，无法从总结果读出实际覆盖。该次运行前失败的输出现在已重跑并确认整套 runner 通过，故本项不是当前测试失败。

**建议**：对每个测试脚本统一约定 JSON/`pass=... fail=...` 摘要，或在 runner 中输出完整 stdout（不改动这些程序测试本身也可先做 runner 改进）。

### O-03 — 【P3】MQL 的几个边界/自愈模块缺少直接失败注入测试

1. `CopierConfig.mqh:616-719` 的 `.tmp` 仅在主文件**不存在**时由 `CopierIniReadAll` 回退；若崩溃/断电发生在删除主文件后重新创建主文件、但只写入了部分内容，重启时主文件“存在”，先尝试其内容，只有解析失败的调用方可能再读 `.bak`；通用 `CopierIniReadAll` 本身不会比较 `.tmp` 与主文件完整性。注意新 `CopierIniWriteAtomic()` 在成功 copy 后删 tmp，计划中主文件缺失恢复是已实现的，但“主文件存在但半成品、tmp 更完整”路径没有 SelfTest。
2. `CopierState.mqh:1213-1365` state 文件 successor `.tmp` 回退和 delete/copy 中途断电属于另一套实现，当前 SelfTest 涵盖撕裂 END marker，却未模拟半覆盖期间恢复文件。

不把这两项升为确定的生产缺陷：这里是缓存/配置恢复故障注入未覆盖，且 CFG 路径有 `.bak` 和 30 秒重新拉取路径。建议分别模拟主文件不存在、主文件被截断仍存在、tmp 完整与否、备份恢复与重新推送，并界定哪份文件具有优先权。

### O-04 — 【P3】`hub/src/tls.rs:635` 有一条低噪声构建 warning

`TempChallengeServer.port` 当前被写入但未读取；Rust 单测 158 项全过，但编译器提示 dead-code。可删除字段或在运维状态中使用它，不影响运行。

---

## 5. 本轮核销的历史高风险项（确认当前已修，不重复报缺陷）

- **交易/跟单硬规则**：`CopierMirrorStop*` 仍按发送端 `|SL-open|` 重锚到本地开仓价；反向跟单且发送端 TP=0 保持 `wantSl=0`，没有擅自造硬 SL。`osl/otp` pending gate 和 `CopierMapInvertedStops` 仍按设计保留。
- **微手数**：`CopierLotEncodable()` 直接调用真实 `CopierFmtDouble(...,8)`；`RebuildSnapshotPayload()` 在编码前过滤。SelfTest `N72-01/N73-08` 边界覆盖仍在；不复述早期阈值问题。
- **坏快照守门**：`HandleSnapshot` 当前要求 `N` 合法、可选 H 格式/内容匹配、解码记录数等于 `min(N,CP_MAX_POSITIONS)`，有效后才改写 desired 和 receipt。发现的是 EA 级测试触达不足，而不是守门逻辑已被移除。
- **旧 SSID 延迟包**：`AcceptSeq` 对 abandoned SSID 有拒绝门，避免主备延迟旧 session 把状态回拨。
- **人工平仓**：`g_manualClosed` 已按 UID+ticket+SID 持久化，GC 只有 owner sender ready 才定向移除；UID 仍由当前 sender 持有时阻止重新开仓。
- **BlockedCapped**：CLOSE/TRIM/DEDUP 在 `PushAction()` 都套 `BlockedCapped(key,1000)`，旧的遗漏 DEDUP 路径已修。当前仍需压力测，但不是“DEDUP 未覆盖”的旧问题。
- **通知 SSRF**：通知渠道请求路径使用 `resolve_pinned_client()`，所有解析地址走 `check_single_ip()`；DNS 超时、pin all addresses、禁重定向和 URL parser query edge 均有实现/测试。本轮未确认旧 DNS rebinding 报告仍成立。
- **TLS**：`tls_configure`/`tls_renew` 有 in-progress 防重入，enroll failure wrapper 清 `in_progress`，TLS 配置通过 atomic replacement；本轮不重复此前已修 TLS 状态机问题。
- **commands journal**：同时间戳同状态重试行按 attempts 前进，新增的 N84-01 测试通过；terminal reactivation、绝对 unreachable timeout、unknown 转换刷新 ts 都在代码中。
- **HA 锁与数据**：主要 journal/config 读取和 SHA256 已移出 SharedState 粗锁；集群同步全量替换有批次完整性检查；Failback 时钟以 `sync_status == synced` 为条件。仍发现 F-01 中 `apply_delta_lines` 的写失败被忽略，这是不同于“截断保护/锁内 IO”的剩余故障路径。

---

## 6. 测试覆盖观察与边界

- `tools/tests.sh` 是 Python suite runner，不等于全平台构建：它默认不编译四终端 MQL EA；`--all` 会再运行 hub release、Rust tests、EA build。当前报告只声明实际运行过的 suite。
- Rust 有 158 个单元测试，覆盖位置解析、命令阶梯/恢复、配置 journal、audit 轮转、认证、通知脱敏/SSRF 等；关键编排主循环和 HTTP 大量业务组合更多依赖端到端测试。
- `CopierSelfTest.mq4` 包含 570+ 断言及较新的 `N72-01/N73-08` 微手数边界，但项目聚合 runner 不自动运行它；MQL 运行期的 `HandleSnapshot`、多 Hub 收据/配置状态及 risk-close-all 仍缺少可自动重放的集成级测试。
- 外部 MetaTrader / broker 行为（MT4 ticket rollover、MT5 pending fill/partial close、交易权限与 stop-level）不能仅凭 Rust/Python 单测证明；生产发布仍需实际 EA build 与 demo 终端演练。

---

## 7. 优先级建议

1. **先修 F-01**：standby 增量 journal append 失败必须使 sync 失败，不应更新成功状态。
2. **再修 F-02**：epoch 递增统一使用 checked arithmetic 并拒绝溢出状态。
3. **给 F-03 加故障注入证据**：重点断开一条 Hub pipe，验证每类 `@` 控制帧至少有一个正确 Primary 处理者，且 HA 复制状态不会错误地变为 terminal/unknown。
4. **补 F-04 的 EA chokepoint 测试**：不仅测解析器，而要检查 bad snapshot 从未改写 desired、receipt 或排出仓指令。
5. **随后优化 O-01/O-02**；对 `.tmp` 写入/恢复做明确的故障注入测试。

**本轮未改动任何 MQL/Rust/Python 程序代码。**