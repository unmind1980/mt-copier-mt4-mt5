# mt-copier 全栈只读审计报告

- 审计日期：2026-11-05
- 审计对象：`E:\WorkBuddyAI\2026-10-04-23-18-48\mt-copier`
- 范围：`src/`（MQL4/MQL5 EA、Include 头文件、自检脚本）、`hub/src/`（Rust Hub）、`tools/`（Python 合约测试与构建脚本）、`doc/` 与根目录 Markdown
- 约束：**未修改任何程序代码、配置或部署脚本；未连接经纪商；未下单；未启停任何生产服务。**
- 方法：先通读文档建立协议与不变量，再按「发送端 → 传输 → Hub → 接收端 → 执行/风控 → 持久化/HA」的数据流顺序读源码，最后用跨模块不变量反查消费端实际读值。Rust 侧运行了离线单测（见第 6 节）。

---

## 1. 总体结论

代码整体质量高于同类项目：状态表全部有硬上界、哈希索引与代数戳替代了热点线性扫描、协议解析对恶意输入做了长度与边界防护、HA 有 epoch 围栏与两阶段回切、CURVE 用 ZAP 在握手期执行白名单、通知 URL 做了 DNS 固定与重定向禁用。历史审计中记录过的问题，绝大多数在当前代码里能看到对应的修复与回归测试。

本轮仍发现 **4 个高优先级逻辑问题**、**6 个中优先级/条件风险**，以及若干可优化的热点与文档漂移。最严重的一条不在交易执行路径上，而在**「按需快照」模式**：`SnapshotSeconds=0` 时，发送端会把「已广播的旧哈希」永久视为有效收据，导致内容变更（尤其是部分平仓）永远不会被修复。这条与代码自身的注释直接矛盾，属于实现遗漏而非设计取舍。

| 编号 | 级别 | 问题 | 影响面 |
|---|---|---|---|
| H1 | 高 | `SnapshotSeconds=0` 时快照哈希冻结，收敛永久停在上一次广播 | 所有按需模式部署；部分平仓/手数变化丢失 |
| H2 | 高 | TLS 配置为启用但 acceptor 缺失时，HTTPS 端口回退为明文 HTTP | 证书损坏/缺失/重载失败时的凭据泄露 |
| H3 | 中高 | Hub 持仓视图按 NID 存储、按原始账号查询，10 位账号查不到 | 10 位及以上账号的仪表盘持仓列为空 |
| H4 | 中高 | 复制的用户密码变更不会撤销既有会话 | 主备切换后旧会话仍可登录 |
| M1 | 中 | HA 日志「逻辑行数」可超过物理行数，触发多余全量重同步 | 备用端水位失真、周期性全量同步 |
| M2 | 中 | 配置热重载保留的 CLOSE/TRIM 动作携带旧 `senderIdx` | 风控计数错记、TRIM 注释 magic 错误 |
| M3 | 中 | `CopierIniWriteAll` 未检查写入返回值，可能落盘截断的 ini | 磁盘满/句柄耗尽时配置损坏 |
| M4 | 中 | WebSocket 升级后不再校验会话 | 会话被撤销后仍持续收到持仓推送 |
| M5 | 中 | 配置下发接口在命令日志写失败时仍返回 202 并记审计成功 | 操作员误以为已入队，重启后命令消失 |
| M6 | 低中 | 接收端 `HELD=0` 时 Hub 可能清空含手工持仓的明细 | 仪表盘明细与 POS 不一致（待实测复核） |

> 说明：H3/H5 这类问题不影响下单与平仓，只影响可观测性与安全边界；H1/M2/M3 会影响交易结果，建议优先处理。

---

## 2. 高优先级问题

### H1. `SnapshotSeconds=0`（按需快照）会让收敛永久冻结

**位置**

- `src/Experts/CopierSender.mq4:183` — `input int SnapshotSeconds = 15; // 0=off`
- `src/Experts/CopierSender.mq4:1642-1683` — `RebuildSnapshotPayload()`
- `src/Experts/CopierSender.mq4:1685-1693` — `BroadcastSnapshot()`
- `src/Experts/CopierSender.mq4:2218`、`2244-2258` — `dueSnap` 与按需重建分支
- `src/Experts/CopierSender.mq4:318-329` — `IsRecentSnapHash()`
- `src/Experts/CopierSender.mq4:1341-1434` — `SnapRepairMaybe()`

**机制**

1. `RebuildSnapshotPayload()` 每次都更新 `g_latestSnapPayload` / `g_latestSnapHash`，但**只在 `g_snapPayload` 或 `g_snapHash` 为空时**才把它们同步到「已广播」那一份：

```cpp
g_latestSnapPayload=CopierEncodeSnapshot(dense,dn);
g_latestSnapHash=CopierSnapshotHash(g_latestSnapPayload);
// Do not overwrite g_snapHash without broadcasting, otherwise receivers
// reporting the broadcast hash will be falsely deemed BEHIND.
if(StringLen(g_snapPayload)==0 || StringLen(g_snapHash)==0)
  {
   g_snapPayload=g_latestSnapPayload;
   g_snapHash=g_latestSnapHash;
   NoteRecentSnapHash(g_snapHash);
  }
```

2. 只有 `BroadcastSnapshot()` 会执行 `g_snapPayload=g_latestSnapPayload; g_snapHash=g_latestSnapHash;`。而 `dueSnap` 的条件是 `SnapshotSeconds>0`（第 2218 行）。所以 `SnapshotSeconds=0` 时，**除了待挂单成交的 500ms 缓冲那一次**，`BroadcastSnapshot()` 永不执行，`g_snapHash` 停留在启动后第一次构建的值。

3. 接收端回显的正是这个冻结的 `H`。`IsRecentSnapHash()` 第 321 行：

```cpp
if(h==g_snapHash || h==g_latestSnapHash) return true;
```

于是「旧哈希」永远判为 in-step，`g_snapStaleN` 恒为 0，`SnapRepairMaybe()` 永远不会被调用。代码在第 1352-1355 行的注释写的是：

> When `SnapshotSeconds` is 0 the periodic broadcast is off, so repairs are the only way state moves.

**但这条路径实际上进不去**——收据永远「正确」，所以永远不修。

**触发条件**

- `SnapshotSeconds <= 0`（输入说明是 `0=off`，运维很容易理解为「关闭周期快照、需要时才发」）；
- 接收端在线并已回执过第一份快照；
- 之后发生**只体现在快照里、没有对应事件**的变化。

**影响**

- `lotsDiff`（部分平仓）只调用 `MarkStateDirty()`，**不发任何事件**（`CopierSender.mq4:2126-2134`）。因此在按需模式下，发送端部分平仓后接收端永远不会 TRIM，仓位会一直偏大。
- 同理，重启后新接入的**直连**接收端：`SnapRepairMaybe()` 的 direct 分支固定 `Emit(CP_T_SNAP, g_snapPayload, ...)`（第 1420 行），拿到的是冻结的启动快照，而不是 `g_latestSnapPayload`；它 ACK 这个旧哈希后同样被判 in-step，于是**永远停在启动状态**。Hub 模式因为有 `isBootstrap` 特判（第 1389-1390 行用 `g_latestSnapPayload`）而部分幸免，但在线接收端仍然收不到后续变化。
- 发送端面板/日志不会报错：收据全部「正常」，这是最危险的静默失败。

**建议方向（不在本次修改）**

- 修复的关键不是「修 repair 时重建」，而是让 repair **发送 `g_latestSnapPayload`** 并同步推进 `g_snapHash`。`NoteRecentSnapHash` + `IsRecentSnapHash` 的 16 项历史环本来就是为「哈希移动但其他接收端不应被判 BEHIND」设计的，测试 `snapshot_repair_test.py` 第 8 节也明确断言了 `latest_hash` 应被接受。当前实现只对 bootstrap 用了 latest，属于半程修复。
- 若担心历史环被高频脏重建冲掉（`SnapshotSeconds=0` 时 TTL 只有 15s），可让按需模式在内容变化后**主动广播一次**（带最小间隔），或把「脏重建」纳入历史环并延长 TTL。
- 至少在 `SnapshotSeconds<=0` 且 `SyncHeartbeatSeconds<=0` 时于启动日志给出明确警告：此组合下没有任何收敛通道。

**验证建议**

离线可验证：构造 `SnapshotSeconds=0`，令 `g_snapPayload` 非空后修改 `g_prev` 的手数，推进 3 个 tick，断言 `g_snapHash` 不变且没有任何 `CP_T_SNAP` 被 `Emit`。这条不需要终端，可作为 MQL 自检的新用例（或 Python 侧的行为镜像测试）。

---

### H2. TLS 启用但证书/acceptor 不可用时，HTTPS 端口静默回退为明文

**位置**

- `hub/src/api.rs:1904-1906` — `let _ = tls_mgr.reload_from_disk();`
- `hub/src/api.rs:1925-1933` — `is_tls` 判定与启动横幅
- `hub/src/api.rs:1942-1963` — 每连接选择 acceptor，`None` 时直接 `serve_stream_with_router(tcp_stream, app)`

**机制**

`reload_from_disk()` 的返回值被丢弃。随后每个连接独立判断：

```rust
let is_https_on_main = { c.enabled && c.https_port == current_port };
let acceptor_opt = if is_https_on_main {
    tls_mgr.acceptor.read_or_recover().clone()
} else { None };
...
if let Some(acceptor) = acceptor_opt {
    match acceptor.accept(tcp_stream).await { ... }
} else {
    crate::tls::serve_stream_with_router(tcp_stream, app).await;   // 明文
}
```

只要配置 `enabled=true` 且端口匹配，但 `acceptor` 为 `None`（证书文件缺失、PEM 损坏、权限不足、重载失败、首次部署尚未导入证书），**该端口就以明文 HTTP 接受请求**，包括 `POST /api/v1/login` 的密码与 `Set-Cookie` 会话。

**与「fail closed」的差距**

启动横幅会打印 `http://` 而不是 `https://`（`is_tls` 要求 acceptor 存在），所以并非完全无声；但它只出现一次，且端口仍然可用，运维很容易忽略。对「本来配了 HTTPS」的部署，这构成降级；对通过反代/负载均衡转发的部署，后端明文这一段可能跨越主机网络。

**建议方向**

- `reload_from_disk()` 失败且 `config.enabled` 时，拒绝启动（与 `--curve on` 空白名单同样的 fail-closed 策略），或在 accept 循环里对该端口直接关闭连接并限速告警，绝不 `serve_stream_with_router` 明文。
- `is_https_on_main && acceptor_opt.is_none()` 应视为配置错误，而不只是「这次没有 TLS」。
- 补一条集成测试：写入 enabled 配置 + 删除证书文件 + 启动，断言端口不接受明文登录。

---

### H3. Hub 持仓视图按 NID 存储、按原始账号查询：10 位及以上账号查不到

**位置**

- `src/Include/Copier/CopierDefs.mqh:1091-1114` — `CopierNid()`：`account >= 1e9` 时取 `account % 1e9`
- `hub/src/main.rs:2652-2656` — SNAP 的 `sid = envelope_hdr(payload,"SID")`，而发送端 `e.sid=(string)g_nid`
- `hub/src/positions.rs:161` — `view_for(&self, sid: &str)`
- `hub/src/api.rs:362`、`hub/src/api.rs:482` — `pos.view_for(&n.acc)`

**机制**

发送端在快照信封里用的 `SID` 是 **NID**（账户截断到 9 位），Hub 的 `Positions` 也以这个 `SID` 为键。但 API 序列化节点时传入的是**原始账号** `n.acc`：

```rust
let pv = if n.role == Role::Sender {
    pos.view_for(&n.acc)      // acc 是 REG 里的原始账号
```

对 9 位及以下账号，`CopierNid(acc) == acc`，两者相同，问题不显现。对 10 位账号（例如 `1234567890`），NID 为 `234567890`，`view_for("1234567890")` 必然 miss。

**影响**

- `/api/v1/nodes` 的 `positions` 字段为 `null`，节点表的 POS 列为空；
- `/api/v1/nodes/<key>` 的 `positions` 为 `null`，看不到 symbol 分布、逐笔明细、`snaps`；
- Hub 控制台 `print_positions` 与 `positions` 顶层数组是按视图键遍历的，通常仍能看到数据——于是出现「顶层有、节点行没有」的自相矛盾，比全空更难排查；
- 不影响下单/平仓（Hub 只读转发），但会让 10 位账号的运维失去主要监控面。

**建议方向**

- 在 `Node` 上保存 `sid`（注册时用 `CopierNid` 计算一次），API 用 `n.sid` 查询；或让 `view_for` 同时接受 `acc` 与 `nid`（先精确匹配，再按 `acc % 1e9` 回退）。
- 更稳妥：`on_snap` 落库时同时记录 `sid` 与 `acc` 的映射，避免在 Rust 侧重实现 MQL 的截断规则（两份实现容易漂移）。
- 补一条单测：`acc="1234567890"` 的节点 + `sid="234567890"` 的视图，断言 `nodes_json_list` 的 `positions` 非空。

---

### H4. 复制的用户密码变更不会撤销既有会话

**位置**

- `hub/src/users.rs:305-315` — `apply_loaded_users()`
- 对照 `hub/src/users.rs` 中 `upsert()`（密码变更会清 session，测试 `a_password_change_replaces_the_hash_and_ends_other_sessions`）

**机制**

```rust
pub fn apply_loaded_users(&mut self, users: Vec<User>) {
    self.users = users;
    self.sessions.retain(|_, s| {
        if let Some(u) = self.users.iter().find(|u| u.id == s.user_id) {
            !u.disabled && u.role == s.role
        } else { false }
    });
}
```

只比较 `disabled` 与 `role`，**不比较密码哈希**。主库上管理员重置某用户密码时，`upsert()` 会清掉该用户的会话；但这条变更通过 `users.json` 复制到备用端后，备用端的 `apply_loaded_users()` 认为「id/role/enabled 未变」，保留旧会话。

**影响**

- 旧 cookie 在备用端仍然有效；一旦发生提升（failover），备用端成为权威，旧会话可以继续访问，密码重置并未真正生效。
- 若攻击者已持有会话，主库的「重置密码 + 撤销会话」在集群层面不完整。
- 角色变更/禁用是会复制的，所以问题只落在「密码变更」这一条。

**建议方向**

- `Session` 记录创建时的 `pass` 哈希指纹（或用户版本号），`apply_loaded_users` 在不匹配时删除会话；这与 `upsert()` 的语义一致。
- 或者让 `User` 带 `session_epoch`，密码变更时递增并随 `users.json` 复制。
- 补测试：主库改密 → 导出 users → 备用端 `apply_loaded_users` → 断言旧 token 解析失败。

---

## 3. 中优先级与条件风险

### M1. HA 日志「逻辑行数」可超过物理行数，触发多余的全量重同步

**位置**

- `hub/src/config.rs:288-299`
- `hub/src/commands.rs:453-465`
- `hub/src/cluster.rs:665-672`、`688-695` — `needs_sync` / `full_*_resync` 判定

**机制**

两端在应用复制行时，都有一段「补计数」：

```rust
if parsed_valid_lines > to_append.len() {
    inner.count += (parsed_valid_lines - to_append.len()) as u64;
}
```

被跳过的行（重复、低 rank、旧时间戳）**没有写进文件**，但内存里的 `count` / `line_count` 被加上了。于是内存水位 > 物理行数。而 `read_lines_from_path()` 的 `total` 是**按物理文件重新数**的，`replace_all()` 也会用 `load()` 的物理计数覆盖内存值。

**影响链**

1. 备用端 `sync_stats()` 返回虚高行数 → `/cluster/status` 上报虚高 → 主端 `remote.cfg_lines < my_cfg` 判为 lagging。
2. 备用端下一次 `needs_sync` 里 `remote.cfg_lines < cfg_lines_count` 为真 → `full_cfg_resync`，从 0 拉全量 → `replace_all` → 计数被物理值纠正。
3. 所以是「一次多余的全量重同步」而非永久死循环；但在重复行较多的链路上会反复发生，与代码注释里「prevent infinite full resync oscillation」的意图相反。
4. 被提升的备用端在第一次同步前会以虚高水位对外服务，`/cluster/status` 的数字不可信。

**说明**

这不是数据丢失：被跳过的行本来就是重复/过期行，主端的物理文件仍完整。风险在可用性与可观测性，以及「水位」这个本该单调可信的量被污染。

**建议方向**

- 区分 `physical_lines`（只由 append/replace 增加）与 `logical_lines`（可跳过），对外只报物理值；`from_line` 游标也必须用物理值。
- 若确实需要「逻辑对齐」来避免重复请求，用一个单独的 `peer_expected_lines` 字段，不要复用游标。
- 补测试：连续两次 apply 同一批 delta，断言 `sync_stats().0` 不变，且 `read_lines_from(n-1)` 仍能取到行。

---

### M2. 配置热重载保留的 CLOSE/TRIM/MODIFY 动作携带旧 `senderIdx`

**位置**

- `src/Experts/CopierReceiver.mq4:2796-2825` — `ClearQueueExceptRiskReducing()`
- `src/Experts/CopierReceiver.mq4:6614-6616` — `reload` 分支
- `src/Experts/CopierReceiver.mq4:2927-2932` — 越界丢弃
- `src/Experts/CopierReceiver.mq4:3255-3259` — TRIM 使用 `g_magic[a.senderIdx]`

**机制**

重载时为了不丢失减仓动作，保留了 `CLOSE / TRIM / DEDUP / MODIFY`，但 `CopierAction.senderIdx` 是**数组下标**。`LoadConfig()` 会按 ini 的 `[senderN]` 顺序重建 `g_sid[]`；删除或插入一个 sender 会让其后所有 sender 的下标平移。

- 越界：`ExecuteQueue` 会打错误并丢弃（有防护，不会崩）。
- 仍在范围内但指向了**另一个 sender**：TRIM 的平仓注释会写入错误 magic（`CopierClosePartial` 的 `req.magic`）；同一 tick 的 `sAddedCount[a.senderIdx]` / `sAddedLots` 会计到错误 sender 的风控桶里，可能让某个 sender 的 `MaxOpenPositions` / `MaxTotalLots` 在本 tick 误判。
- 平仓本身用 `a.ticket`（接收端自己的持仓标识），所以**不会平错仓**，这是最重要的安全属性，已确认。

**触发条件**

- Hub 推送了 sender 顺序变化的新 ini（删除/新增 sender 最常见），且队列里恰有未执行的减仓动作；
- 或 `reload` 命令与 CFG 推送叠加。

**建议方向**

- 动作里存稳定的 sender 键（`g_sid` 字符串或 `magic`），执行时再解析下标；解析失败则按「sender 已移除」处理（CLOSE 仍应执行，TRIM 用 0 magic）。
- 或者在 `LoadConfig()` 成功后按旧 `sid → 新 index` 映射重写保留动作的 `senderIdx`。
- 补测试：构造 3 个 sender 的队列 → 删除 sender1 → 断言原 sender2 的 TRIM 归属正确。

---

### M3. `CopierIniWriteAll` 未检查 `FileWriteString` 返回值，可能落盘截断的 ini

**位置**

- `src/Include/Copier/CopierConfig.mqh:702-721`

```cpp
bool CopierIniWriteAll(const string path,const string text)
  {
   string tmp=path+".tmp";
   FileDelete(tmp);
   int th=FileOpen(tmp,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(th==INVALID_HANDLE) return false;
   FileWriteString(th,text);      // 返回值未检查
   FileFlush(th);
   FileClose(th);

   FileDelete(path);
   int h=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return false;
   FileWriteString(h,text);       // 返回值未检查
   FileFlush(h);
   FileClose(h);
   FileDelete(tmp);               // 名义成功后删除唯一的后备
   return true;
  }
```

**影响**

- 磁盘满、配额限制、句柄异常时可能短写，函数仍返回 `true`；随后 `.tmp` 被删除，主文件是截断的。
- `CopierIniWriteAtomic()` 只做「能否解析」校验，不比对字节数。一个在值中间被截断的 ini 仍可能通过 `CopierIniValidate`（例如 `[sender0]\nid=alp` 仍是合法 `k=v`）。
- 后果：接收端少加载 sender 段 → 该 sender 的既有镜像变成孤儿；同时 `IH` 与 Hub 持有的配置不一致 → Hub 反复 `reqcfg` / 报 `config.drift`。
- 只在异常 I/O 下触发，正常磁盘不会显现。

**建议方向**

- 检查两次 `FileWriteString` 的返回值是否等于 `StringLen(text)`；不等则 `FileDelete(path)` 并从 `.tmp` 恢复（或至少保留 `.tmp` 并返回 false）。
- 写入后重新读取并比对长度/内容，而不是只验证可解析。
- 在 `CopierIniWriteAtomic` 的日志里区分「解析失败」与「长度不符」。

---

### M4. WebSocket 升级后不再校验会话

**位置**

- `hub/src/api.rs` 的 `/api/v1/ws` 处理：升级时鉴权一次，随后循环推送快照
- 会话撤销路径：`users.rs` 的 `upsert` / `remove` / `logout`

**机制**

WebSocket 在 HTTP Upgrade 时校验 `mtc_session`，之后只按 `poke` 推流，不再查询 `users.session()`。因此：

- 管理员禁用用户、删除用户、改密、或用户主动 logout 后，**已建立的 WS 不会断开**；
- 该连接仍持续收到 `snapshot_text`（节点、持仓、权益、告警）。

**影响**

被撤销的会话在 socket 生命周期内仍可读取实时持仓与账户数据。REST 侧已经会在每次请求校验，所以这是「同一条会话在两条通道上语义不一致」。

**建议方向**

- 在每次推送前（或每 30s 一次）用 `users.session(token)` 复核，失败则发 close frame 并结束任务；
- 或者给会话加 `revoked_at`/版本号，WS 任务持有版本，推送前比较；
- 补测试：建立 WS → 删除用户 → 断言下一帧前连接关闭。

---

### M5. 配置下发接口在命令日志写失败时仍返回 202 并记审计成功

**位置**

- `hub/src/api.rs` 的 `put_node_config()` / rollback 分支
- 对照 `post_command()` 中对 `issue_cfg()` 写失败的处理

**机制**

`put_node_config()` 在调用 `issue_cfg()` 之后直接构造 202 响应并写 `config.pushed` 审计，没有检查命令是否真正落到 `commands.jsonl`。而 `post_command()` 在同样位置有写失败检查。

**影响**

- `CommandStore::append()` 失败时只 `eprintln!`，命令仅存在于内存；
- 操作员看到 202 + 审计「成功」，Hub 重启后该命令消失，节点永远收不到配置；
- 由于 `config_revisions.jsonl` 里已经有这条 revision，下一次 REG 比较会判节点「behind」并重新 `issue_cfg`——多数情况下能自愈，但**首次下发的成功回执是假的**，且审计记录与事实不符。

**建议方向**

- 让 `issue_cfg()` / `issue_op()` 返回 `Result`（或在 `Command` 上带 `persisted: bool`），API 在失败时返回 503 并记 `config.push_failed`；
- 审计只在确认落盘后写 `ok`。

---

### M6. 接收端 `HELD=0` 时 Hub 可能清空含手工持仓的明细（待实测复核）

**位置**

- `hub/src/registry.rs` 的 `note_stat()` 摘要清理分支
- 接收端 `EncodeReceiverPositions()` 使用 `g_acctAllPos`（含手工持仓），而 `HELD` 是 `g_ourCount`（仅 copier 持仓）

**机制（待复核）**

清理条件大致为：

```rust
} else if (e.held == Some(0) && e.orphaned.unwrap_or(0) == 0)
    || (role == "sender" && e.held_lots == 0.0) {
    e.held_items = Arc::new(Vec::new());
}
```

接收端在「只有手工持仓、没有 copier 持仓」时会发 `HELD=0; ORPHAN=0`，但同一帧的 `POS=` 里仍有手工持仓行。若清理发生在写入 `held_items` 之后，明细会被清空，仪表盘出现「HELD=0 且明细为空」，而 `POS` 明明带了行。

**为什么标为待复核**

需要一条真实 STAT（含 `POS=` 与 `HELD=0`）跑过 `note_stat` 才能确认赋值/清理顺序；仅凭静态阅读可能是「先清后写」而非「先写后清」。不影响交易，只是监控一致性。

**建议方向**

- 清理条件加上 `held_items.is_none()`，或只在「本帧没有 POS 字段」时才清理；
- 补单测：`HELD=0` + 2 条手工 POS → 断言 `held_items.len()==2`。

---

### 3.1 其他低优先级观察

| 位置 | 观察 | 影响 |
|---|---|---|
| `hub/src/notifications.rs` `remove()` 调用处 | `unwrap_or(false)` 把存储 I/O 错误映射成 404 | 删除失败被误报为「不存在」，运维无法区分 |
| `hub/src/positions.rs` `lots_str()` | 仍格式化为 4 位小数，而 API 的 `trim_lots()` 是 8 位 | 仅日志/控制台显示精度，与仪表盘数字可能不一致 |
| `hub/src/envelope.rs` `decompress_field()` | `1:` 解码失败时原样返回字符串 | Hub 视图解析会把它当普通文本；转发仍是逐字节，交易不受影响。但会让「压缩损坏」看起来像「字段内容奇怪」 |
| `hub/src/config.rs` `history()` / `revision_body()` / `read_lines_from_path()` | 每次都全文件读取+逐行 JSON 解析 | revision 永久保留，长期运行后单次 API 调用 O(文件大小)；HA 每秒同步也是 O(文件)。见 O5/O6 |
| `src/Experts/CopierReceiver.mq4` `CopierWaitMs()` | 忙等（20ms/10 单、批量结束 30ms） | 批量平仓时占用主线程；是有意的限速，但可用 `Sleep` 之外的让步方式优化 |
| `src/Include/Copier/CopierState.mqh` `PruneTo()` | 每次清空 4096 项 `desUid` 字符串 | 每份快照一次 O(4096) 字符串赋值，可用代数戳避免 |

---

## 4. 性能与可维护性优化建议

以下都不是「错误」，但在大账户/长运行/多节点场景下会成为瓶颈。按收益排序。

### O1. 事件泵直接调用 `OnTimer()`，导致每批事件都做一次全账户扫描

**位置**：`src/Experts/CopierReceiver.mq4:8663-8675`、`7968-8001`、`2047-2048`

```cpp
void OnChartEvent(...)
  {
   if(g_pump.OnEvent(id))
     {
      OnTimer();                 // 完整慢车道 + BuildCurrent
      if(g_pump.IsActive()) g_pump.Trigger();
     }
  }
```

`OnTimer()` 的第一步就是 `BuildCurrent()`（`CopierReadPositions` 全表 + ticket 索引 + 变化检测）。事件泵的设计是 15ms/500 事件的微突发，用于「事件到达后尽快执行队列」；但它复用了整个 `OnTimer`，于是一串 `OPEN/CLOSE` 事件会放大成多次全账户扫描 + 多次 `RefreshRisk()` + 多次 `ConvergeSender()`。

**建议**：拆成两个入口：
- `DrainAndExecute()`：只 drain、路由事件、`ExecuteQueue()`（泵路径）；
- `ScanAndConverge()`：`BuildCurrent` + `RefreshRisk` + 全 sender 收敛（定时器慢车道）。

泵路径在 `hasFastAction` 时已经显式调用 `RefreshRisk()` 与目标 sender 的 `ConvergeSender()`，所以拆分不会损失快速性。

**收益**：高波动时 CPU 峰值下降；账户越大越明显。**风险**：低，但需要回归 `OnChartEvent` 的 15ms 预算。

### O2. `PruneTo()` 的 4096 项字符串清空

**位置**：`src/Include/Copier/CopierState.mqh:490-542`

每份快照解码后都会 `PruneTo`，函数用两个 `static` 数组做 UID 集合，结束时：

```cpp
for(int k=0;k<CP_UIDIDX_SLOTS;k++)
   if(desHash[k]!=0) { desHash[k]=0; desUid[k]=""; }
```

4096 次字符串赋值，且 `m_n=UsedCount()` 又扫一遍 2048 槽。快照 1s 一次时这只是噪声，但在 2048 持仓 + 高频快照下是白白的固定开销。

**建议**：用 `uint` 代数戳代替清空（每次调用 `++gen`，命中时比较 `desGen[k]==gen`），并把 `m_n` 改为 `m_n -= removed`。两处都是一行改动，行为不变。

### O3. Hub 配置/命令日志的「每次全文件扫描」

**位置**：`hub/src/config.rs:203-231`、`441-470`、`481-520`；`hub/src/commands.rs:323-355`

- `read_lines_from_path(from_line)` 为了拿到第 N 行之后的切片，**从头读整个文件**；
- `revision_body()` 为取一条 revision，扫描整个文件；
- `history()` 为列出最近 N 条，扫描并解析整个文件。

而 revision/command 都是**永久保留**的（设计如此）。一个每天推送几十次配置、运行数年的 Hub，单次 `/api/v1/config/history` 或备用端每秒的 `/cluster/sync` 都会解析整份日志。

**建议**：
- 维护一个内存中的行偏移索引（`Vec<u64>`），append 时 push，`replace_all` 时重建；读取用 `seek`；
- 或至少给 `history()` 加「只读文件尾部 N MB」的快速路径（按行数上限反推）；
- HA 的 `from_line` 游标与物理行偏移一一对应，天然适配。

**收益**：HA 同步从 O(文件) 降到 O(delta)；长时间运行后差异可达几个数量级。

### O4. 接收端批量平仓的忙等限速

**位置**：`src/Experts/CopierReceiver.mq4:2827-2836`、`3236-3243`

`CopierWaitMs()` 是纯 `while` 忙等（注释说明 `Sleep()` 在 `OnTimer()` 中被忽略）。每 10 个异步平仓等 20ms，批量结束再等 30ms。64 个动作的批量约 6 次等待 = 120ms 主线程空转。

**建议**：改用「分帧提交」——本轮提交 N 个后直接返回，把剩余动作留到下一 tick（`MaxActionsPerTick` 已经存在），用时间而非忙等来限速。这样既不阻塞图表线程，也能保持对经纪商的请求速率。

### O5. `RefreshRisk()` 的扫描频率

**位置**：`src/Experts/CopierReceiver.mq4:8323`、`8155`、`8548`

`RefreshRisk()` 在慢车道每 100ms 一次，事件快车道再来一次，`g_forcePosReport` 时再来一次。它内部会遍历账户全部持仓/挂单并解析注释。对 2048 持仓的账户，这是 10Hz × 2048 的字符串工作。

**建议**：已有 `g_posCache` / `g_acctAllPos` 缓存，可给 `RefreshRisk` 加一个「距上次 < 50ms 且无 `g_mapDirty` 则复用」的门闩；`ExecuteQueue` 前的调用只在 `hasFastAction` 时强制刷新。

### O6. `CopierStrBuilder::Result()` 的成对合并

`Result()` 已经是 O(n log n)，但每轮都在 `m_parts` 原地写，且 `m_parts` 容量按 `m_n+1` 增长（`ArrayResize(...,64)` 预留）。100 sender 的 ini 约 270KB → 约 66 个 4KB 块 → 7 轮合并，可接受。无需改动，记录在此以免后续误判为 O(n²)。

### O7. 可维护性：`CopierReceiver.mq4` 体量

单文件约 8676 行，包含配置加载、队列、收敛、命令、面板、状态持久化。跨模块不变量（如 `senderIdx`、`g_desired` 的 `si*CP_MAX_POSITIONS` 布局）靠注释维系。建议后续按「配置 / 队列 / 收敛 / 命令 / 遥测」拆成 include，至少把 `CopierAction` 的所有权规则集中到一处文档。这不是缺陷，是审计成本问题——本轮有相当时间花在跨 8000 行确认一个下标语义上。

---

## 5. 文档与实现不一致

文档整体质量高，且多数地方主动标注了「历史设计，非现状」。以下是可以直接修正的漂移，按影响排序。

| # | 文档位置 | 文档说法 | 代码事实 | 建议 |
|---|---|---|---|---|
| D1 | `README.md:189,191`、`README.zh-CN.md:189,191` | 接收端参数名为 `CentralHubEndpoint` | 实际输入是 `HubEndpoint`（`CopierReceiver.mq4:87`） | 改为 `HubEndpoint`；这是新用户第一步就会踩的坑 |
| D2 | `doc/PROTOCOL.md:451` | `SNDHWM=1000`, `RCVHWM=1000` | `CopierTransport.mqh:99-100` 是 256；`hub/src/main.rs:188` 也是 256 | 改为 256，并说明「降低 HWM 是为了限制慢客户端内存」 |
| D3 | `doc/PROTOCOL.md` 失败行为表 | 「feed stale → **every** queued action is held」 | `ExecuteQueue` 在全局停摆时允许 `CLOSE/TRIM/DEDUP` 继续（2934-2941 行），只 hold `OPEN/MODIFY` | 改成「除减仓类动作外全部 hold」，这是有意的安全改进，应在文档中体现 |
| D4 | `README.md` 首次启动说明 | 初始密码「打印在控制台」 | `main.rs:1589-1598` 写入 `.admin_bootstrap_password` 并只打印路径 | 更新为「写入文件并打印路径」，并提示首次登录后删除 |
| D5 | `README.md` 测试规模 | 与当前数量不符 | 本轮实测 Rust 162 条（161 通过 + 1 条被跳过） | 用 `tools/tests.sh --all` 的实际输出为准，避免写死数字 |
| D6 | `README.md` 安全宣称 | 「zero split-brain risk」「100% durability」等绝对表述 | 双主同 epoch 靠 `hub_id` 决胜；网络分区期间两端都可能短暂可写。`atomic_replace_file` 在 Windows 回退为 copy（非原子） | 改为「在检测到对端后收敛」「append + fsync，替换在 Windows 上为 copy 回退」 |
| D7 | `doc/PHASE1-DESIGN.md:262` | HWM 1000 | 同上 | 该文档是历史设计，可在开头加一句「参数以当前代码为准」即可，不必逐条改 |

另外：`PROTOCOL.md` 的「Not in v1」小节已经自己标注了「这些后来都实现了」，处理得当，不需要动。

---

## 6. 已核实、判定为「非缺陷」的项

这些是本轮重点反查过、结论是**有意设计或已被正确实现**的点。列出来是为了避免下一轮审计重复开案。

| 项 | 结论 | 证据 |
|---|---|---|
| `InvertTrades=true` 且发送端 `TP=0` 时接收端 SL 为 0 | **有意设计**：不为反向镜像凭空造硬止损；需要保护时由操作员显式配置 `EmergencySLPips` | `CopierSelfTest.mq4:2358-2363` 明确断言并标注 `Locked Decision` |
| `CLOSE/TRIM/DEDUP` 的 1s 退避上限会不会阻塞平仓 | **不会**：`BlockedCapped(key,1000)` 最多延迟 1s，不是永久阻断；且 `PushAction` 之前已 `Forget` 对应 key | `CopierReceiver.mq4:2700-2707`、`CopierState.mqh:1098-1107` |
| `MODIFY` 不受 seen-ring 约束 | **正确**：幂等状态赋值应由「当前值 vs 目标值」判断，而非「是否做过」 | `CopierDefs.mqh:217-220`、`CopierSelfTest.mq4:920-944` |
| `g_manualClosed` 的持久化与 GC | **已实现**：加入时 `CmdStateSave()`，GC 变化时再次保存，按 sender 定向清理 | `CopierReceiver.mq4` 中 4 处 `CmdStateSave()` 调用与 `gcChanged` 分支 |
| 通知渠道密钥的掩码与回填 | **正确且是 deny-by-default**：按 key 名掩码、webhook 反转为白名单、header 全掩码、URL path 掩码；回填只接受含 `***` 的字段 | `notifications.rs:44-255`、`543-600`，测试 `a_type_change_restores_secrets_under_the_stored_type` |
| CURVE 白名单是否真的能阻止未授权订阅 | **能**：ZAP 在握手期拒绝，peer 不会成为 subscriber；空名单 `--curve on` 拒绝启动 | `curve.rs:376-577`、`main.rs:1185-1201` |
| `unescape_ini` 的 UTF-8 切片 panic | **已修**：按字节读两位 hex，不再用 `&s[i+1..i+3]`；`%中` 有测试 | `config.rs:808-842`、测试 `unescape_never_panics_on_a_percent_before_a_multibyte_char` |
| `mask_secret` 的多字节 panic | **已修**：按 `char` 取前后 4 位 | `notifications.rs:298-309`、测试 `mask_secret_never_panics_on_multibyte_input` |
| `CopierKvGet("OTS")` 命中 `LOTS=` | **已修**：沿 `;` 边界回溯，找不到再前进 | `CopierDefs.mqh:754-785`、测试 `TestKvSuffixCollision` |
| 通知 URL 的 SSRF / DNS rebinding | **已处理**：禁重定向、DNS 解析后固定 IP、禁 loopback/私网/云元数据（含 IPv4-mapped IPv6） | `notifications.rs:1074-1301` |
| 满容量快照能否装进 1MB | **能**：2048 条最坏长度记录 × 2 仍有 headroom，自检断言 `StringLen(wire)*2 <= CP_MAX_MSG_LEN` | `CopierSelfTest.mq4:1762-1776` |
| 双 standby / 双 primary 的收敛 | **有确定性裁决**：同 epoch 双主按 `is_configured_primary` + `hub_id` 字典序；双备按同规则恢复一个主；`next_epoch` 饱和不回绕 | `cluster.rs:514-609`、`386-389` |
| 配置/命令日志的持久化顺序 | **先落盘再发布**：`put()` / `apply_delta_lines()` 都是 append 成功后才更新内存；失败返回 `StoreError::Write` | `config.rs:390-396`、`commands.rs:451-455` |
| 有界状态 | 所有表都有硬上限：positions 2048、actions 256、seen 4096、backoff 256、manual-closed 256、stops-override 512、peers 100 | `CopierDefs.mqh:30-67`、`CopierState.mqh`、`CopierReceiver.mq4:402-410` |

---

## 7. 测试与验证记录

### 7.1 已执行

```bash
bash hub/build.sh --test -- --test-threads=1 --skip validate_outgoing_url_ssrf_protection
```

结果：

```
running 161 tests
...
test result: ok. 161 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out; finished in 3.48s
```

另有针对审计日志的单模块运行：

```bash
bash hub/build.sh --test audit::tests:: -- --test-threads=1
# 15 passed; 0 failed
```

说明：

- 被跳过的 `notifications::tests::validate_outgoing_url_ssrf_protection` 会真实解析 `api.telegram.org`、`qyapi.weixin.qq.com` 等外部域名。为了不在审计环境引入外网依赖，主动跳过；它的断言在本轮代码阅读中逐条核对过，逻辑与 `check_url_base` / `check_single_ip` 一致。
- 构建过程出现一条非致命告警：
  `error deleting lock file for incremental compilation session directory ... Access is denied (os error 5)`
  构建仍成功（`Finished dev profile`）。这是 Windows 上增量编译锁文件被其他句柄占用导致的清理失败，不影响产物；若后续 CI 出现，清理 `hub/target/debug/incremental` 即可。
- 没有修改 `hub/target` 之外的任何文件；测试只在临时目录创建文件（各测试自带 `remove_dir_all`）。

### 7.2 未执行及原因

| 套件 | 原因 |
|---|---|
| `src/Scripts/CopierSelfTest.mq4` | 需要 MetaTrader 终端挂到图表上运行；本环境没有终端，且运行它会写 `MQL\Files\copier_selftest.log`。本轮改为逐条阅读其断言，确认它们覆盖了 H1 之外的多数不变量。 |
| `src/Scripts/CopierZmqProbe.mq4` | 同上，需要终端与本地端口 5781。 |
| `tools/tests.sh` | 需要 `pyzmq` 虚拟环境，且多数套件会启动 Hub 进程、绑定端口。属于「运行服务」范畴，按只读审计约束未执行。 |
| `tools/tests.sh --all` | 会调用 `tools/build.sh` 编译 EA，需要 MetaEditor；且会重写 `MQL\Experts` 下的产物。未执行。 |

### 7.3 覆盖度与未读部分（如实说明）

- `hub/src/*.rs`：全部 17 个文件都通读；`api.rs`（4367 行）按功能段读完了鉴权、用户、配置、命令、通知、HA、TLS、WS、审计、locales，未逐行读的是部分端点参数校验的重复样板。
- `src/Include/Copier/*.mqh`：全部通读。
- `src/Experts/CopierSender.mq4`（2383 行）：读了输入定义、`BuildCurrent`、快照/收据/修复、`OnTimer`、`HandleHubSubFrame` 等关键段；`OnInit` 中输入解析的中段（约 770-1090 行）本轮未逐行重读。
- `src/Experts/CopierReceiver.mq4`（8676 行）：配置加载、队列、执行、收敛、命令、遥测、生命周期均已覆盖；约 85% 行数直接读过，未逐行的是部分面板绘制与重复的日志分支。
- `hub/src/assets/dashboard.html`（9358 行）：读了结构、主题变量、关键渲染函数与它所消费的 API 形状，未逐行读所有 CSS。
- `doc/HANDOFF.md`（约 1890 行）：按区间读取；有几段因超出单次输出上限被工具落盘，只看到预览。**本轮结论一律以当前代码为准，不依赖这些未完整可见的历史段落。**

---

## 8. 建议的处理顺序

### P0（先做，直接影响交易或凭据）

1. **H1**：按需模式修复为「repair 发送 `g_latestSnapPayload` 并推进 `g_snapHash`」，或在内容变化时主动广播一次；同时为 `SnapshotSeconds<=0 && SyncHeartbeatSeconds<=0` 加启动警告。补一条 MQL 自检或 Python 行为镜像。
2. **H2**：TLS 启用但 acceptor 不可用时 fail closed；`reload_from_disk()` 失败不得静默。
3. **M3**：`CopierIniWriteAll` 检查写入长度，短写不删 `.tmp`、不返回 true。

### P1（正确性与 HA 可信度）

4. **H3**：Hub 持仓视图用 NID 查询（或在 Node 上保存 sid）。
5. **H4**：`apply_loaded_users` 比较密码指纹并撤销会话。
6. **M1**：拆分物理/逻辑行数，游标只用物理值。
7. **M2**：动作保存稳定 sender 键，执行时重解析。
8. **M5**：`issue_cfg` 失败返回 503，审计不写 ok。

### P2（安全边界与体验）

9. **M4**：WS 定期复核会话。
10. **M6**：先补一条真实 STAT 的回归测试，再决定是否改清理条件。
11. **O1/O2**：拆分泵路径与扫描路径；`PruneTo` 用代数戳。
12. **O3**：给配置/命令日志加行偏移索引（长运行 + HA 场景收益最大）。
13. **D1-D4**：文档修正，尤其是 `HubEndpoint` 参数名。

### 建议新增的测试（按优先级）

| 测试 | 目的 |
|---|---|
| `SnapshotSeconds=0` 下修改手数/部分平仓，断言产生 SNAP 或推进 hash | 锁死 H1 |
| TLS enabled + 证书缺失，断言端口拒绝明文 | 锁死 H2 |
| 10 位账号的 `nodes_json_list` 持仓非空 | 锁死 H3 |
| 主库改密 → 复制 → 备用端旧 token 失效 | 锁死 H4 |
| 重复 delta 应用两次，断言 `sync_stats().0` 不变 | 锁死 M1 |
| 重载后保留的 TRIM 归属正确 | 锁死 M2 |
| 短写 ini（可用只读/配额模拟）返回 false 且保留 `.tmp` | 锁死 M3 |

---

## 9. 附：两个可在不改代码前提下复现的思路

### H1 的静态复现（无需终端）

1. 令 `SnapshotSeconds=0`，让发送端完成首次 `RebuildSnapshotPayload()`（`g_snapPayload`/`g_snapHash` 被赋值）。
2. 人为改变 `g_prev` 中某个 UID 的 `lots`（模拟部分平仓），触发 `MarkStateDirty()`。
3. 推进 `OnTimer()` 数次：`g_snapDirty` 分支会更新 `g_latestSnapHash`，但 `g_snapHash` 不变，且不会调用 `Emit(CP_T_SNAP,...)`。
4. 断言：`g_snapHash == 初始值`，且 `IsRecentSnapHash(g_snapHash)==true`。这正好证明「收据永远正确、修复永不触发」。

若要在 Python 侧镜像，可直接复用 `tools/snapshot_repair_test.py` 的 `Receiver` 类：把 `sender_hash` 固定为初始值、`latest_hash` 设为变化后的值，观察 `track()` 永远返回 false——当前测试第 8 节只断言了「latest 被接受」，没有断言「旧哈希也应最终被判 stale」。

### H3 的静态复现

1. 构造 `Node { role: Sender, acc: "1234567890", ... }`。
2. 用 `sid = "234567890"` 调 `pos.on_snap(...)` 写入一条记录。
3. 调 `nodes_json_list_from_nodes(&[node], &pos, now)`。
4. 断言 `j[0]["positions"]` 为 `null`（当前行为），而期望是 `{count:1,...}`。

---

## 10. 结语

本轮没有发现「会立刻导致错误下单」的缺陷：平仓/减仓的标识、方向、手数校验链是完整的，反向镜像与止损重锚的边界也有测试锁定。真正需要尽快处理的是 **H1（按需模式静默停止收敛）**、**H2（TLS 降级为明文）** 和 **M3（配置截断）**——它们的共同点是「失败时看起来一切正常」，而这正是这个项目在文档里反复强调要避免的失败类型。

报告中的每一条都给了代码位置与触发条件；标为「待复核」的只有 M6 一条，其余均可由静态阅读或现有测试直接验证。建议先按 P0 处理，再决定 H3/H4 是否纳入同一版本。

