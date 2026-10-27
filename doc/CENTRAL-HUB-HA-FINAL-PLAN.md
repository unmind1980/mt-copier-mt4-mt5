# mt-copier 主备 Hub 双机热备（Dual-Active HA）最终实施方案与全阶段路线图

> **文档版本**：v3.0 终审定案稿（综合 v1 架构草案、v2 生产强化版与第三方评审专家意见）  
> **制定日期**：2026-10-26  
> **实施状态**：方案定案完成，待启动 Phase 0 验证基线（本阶段不写业务代码）  
> **适用版本**：mt-copier v1.0+ (MQL4/MQL5 + Rust Hub)  
> **核心原则**：数据面双端双活（0ms 链路容灾） + 控制面主写备读（受控 Fencing 单写） + 渐进式交付（显式双地址先行，自动拓扑后置）

---

## 1. 架构总览与核心设计决策（ADR）

综合前期讨论与两份专业评审意见，针对主备高可用架构，确立以下 9 项核心架构决策：

```
                              管理员 / Web Dashboard
                                 │             │
                          HTTP/WS│             │HTTP/WS
                          (:6010)▼             ▼(:6011)
                     ┌────────────────┐       ┌────────────────┐
                     │ Primary Hub    │       │ Standby Hub    │
                     │ (主节点)       │       │ (热备节点)     │
                     │ - 角色: Primary│       │ - 角色: Standby│
                     │ - 写权限: 开启 │       │ - 写权限: 锁定 │
                     │ - 数据面: 转发 │       │ - 数据面: 转发 │
                     │ - 控制面: 主发 │       │ - 控制面: 静默 │
                     └───────▲────────┘       └───────▲────────┘
                             │   Inter-Hub Sync       │
                             │ (JSONL 水位线 + 摘要)  │
                             │◄──────────────────────►│
                             │                        │
                  同一交易流 │                        │ 同一交易流
                 双路上行/下行│                        │ 双路上行/下行
                             │                        │
                     ┌───────┴────────────────────────┴───────┐
                     │         MT4 / MT5 EA 终端              │
                     │ - 单 m_sub 套接字同时连入主备两端       │
                     │ - 按最大 SEQ 快照合并 + AcceptSeq 过滤 │
                     │ - 独立追踪主备 PONG 与往返延迟 (RTT)   │
                     └────────────────────────────────────────┘
```

### 10 项架构决策定案（ADR）

| 决策编号 | 核心问题 | 最终定案结论与工程理由 |
| :--- | :--- | :--- |
| **ADR-01** | **服务可用性承诺** | **链路冗余 + 状态最终收敛（Eventual Consistency via Snapshots）**。<br>两路 ZMQ 并发传输确保主机宕机时下行链路 0ms 顶上；不宣称“数学意义绝对 0 丢单”，通过 15s 权威全量快照与收据修复机制确保仓位在秒级内 100% 收敛一致。 |
| **ADR-02** | **数据面传输拓扑** | **双端双活连接（Active-Active Dual-Connected XSUB）**。<br>Sender 与 Receiver 均同时连接 Primary 与 Standby；两台 Hub 均实时转发数据帧。依靠协议内置的 `SEQ` 序列号和 Receiver 本地 `CopierSeenRing`（`g_seen`）实现微秒级幂等去重。 |
| **ADR-03** | **控制面写权限与切主** | **严格单写（Single-Writer）+ MVP 阶段受控人工 Promote**。<br>Standby 默认只读（`writes = false`）。拒绝在双机直连心跳超时下盲目自动提权（防网络分区脑裂）；需人工确认旧主隔离后在 Standby 界面点击「一键提权（Promote）」。 |
| **ADR-04** | **世代号（Epoch）** | **引入持久化 `epoch`（`cluster_state.json`）作为恢复与版本防护元数据**。<br>Standby 提权时 `epoch++`；原主恢复上线后发现自身 `epoch` 落后，**强制以 Standby 只读身份加入，并自动反向从新主拉取增量数据**，彻底杜绝旧主数据覆盖新主。 |
| **ADR-05** | **客户端接入演进** | **显式双地址先行，自动拓扑（`T=TOPOLOGY`）后置**。<br>Phase 1 优先支持 `HubEndpoint` 填入分号分隔的双地址（如 `主IP:6000;备IP:6001`）；Phase 3 再引入 `T=TOPOLOGY` 下发与本地 `copier_hub_cluster.st` 缓存，降低首发复杂度。 |
| **ADR-06** | **CURVE 加密规范** | **共享同一套 `curve_hub.keys` 服务端密钥对**。<br>`libzmq` 底层限制一个 XSUB 套接字只能绑定一个服务端公钥。主备共享密钥对，客户端只需下载配置一次 `copier_hub.key` 即可双连成功。 |
| **ADR-07** | **控制帧发射权属** | **Standby 默认控制帧静默，仅在 Primary 失联 >6s 时自动代发 `RCPT`**。<br>避免平时双份 `RCPT` 干扰 Sender 的心跳周期估算；Primary 故障时 Standby 自动接管 `RCPT` 中继，保障快照修复闭环。 |
| **ADR-08** | **状态持久化与同步** | **沿用现有文本/JSONL 架构，基于增量水位线（High-Watermark）+ SHA-256 摘要对齐**。<br>不引入外部数据库。主备强同步 5 大核心文件：`users.json`、`alert_channels.json`、`curve_clients.txt`、`config_revisions.jsonl`、`commands.jsonl`；客户端真实 INI 依靠 `REG` 哈希按需拉取。 |
| **ADR-09** | **集群内部通信安全** | **专用集群共享通信令牌（`cluster_token`）+ 私网/防火墙白名单**。<br>不借用前端 Web Session，不从 CURVE 私钥做非标派生；采用清晰的标准 HMAC-SHA256 或 Bearer Token，并在防火墙层限制互联 IP。<br>**令牌生命周期（N56 补充）**：首次启动随机生成并落盘 `cluster_token.txt`，主备共享同一份；备机缺文件时**拒绝启动**而非自行生成（两端令牌不一致会导致 401、永久 `disconnected`、永不 failback，且无任何报错）。轮换为**手动**操作：停双机 → 删文件 → 启主机（重新生成）→ 拷贝给备机 → 启备机。hub 侧拒绝长度 <16 或本仓库曾公开过的值，且**不把令牌写入日志**。 |
| **ADR-10** | **稳定期自动回切机制（Auto-Failback）** | **主机连续健康在线达标（默认 24h）自动夺回 Master**。<br>运维人员难以长期记忆当前主备归属，为保持“绝大多数时候主机恒为 Master”，主机重启追平数据并连续稳定在线 24 小时后，通过两阶段安全握手优雅夺回 Master 身份，避开重启初期的震荡（Flapping），且全过程无双写窗口。 |

---

## 2. 必须闭环的 8 大工程陷阱与源码级解决方案

对照前述 v2 报告挖掘出的真实源码碰撞，以下 8 项改动为系统稳定性必修项：

### 陷阱 1：双份 `RCPT` 引发 Sender 快照补发风暴
* **机理**：`CopierSender.mq4:1154-1163` 的 `SnapTrack()` 根据相邻两份收据间隔计算心跳周期 `g_snapIntMs`。主备同时回传相同收据（间隔 2~5ms）会导致周期估算被误判压缩至 5ms，2 秒防抖失效，引发每次持仓变化都全量重发。
* **对策**：
  1. **Hub 侧**：Standby 正常消费 `STAT` 更新监控，但平时静默不外发 `RCPT`；仅当探测到 Primary 失联超过 6 秒时，自动接管 `RCPT` 发送。
  2. **Sender 侧**：在 `SnapTrack()` 入口增加 250ms 同 Hash 抑制门限：若 250ms 内收到相同 Receiver 的相同 Hash，仅更新确认时间，不重新计算间隔周期与落后计数。

### 陷阱 2：Receiver 快照合并（Conflation）逆序下标陷阱
* **机理**：`CopierReceiver.mq4:7185-7200` 在同一个 Drain 批次中，通过 `for(i=n-1; i>=0; i--)` 逆序查找最新快照。若 Primary 的新快照（`SEQ=105`）先到（下标 0），Standby 的旧快照（`SEQ=104`）后到（下标 1），逆序会选中旧快照，而下标 0 的新快照被无情跳过丢弃！
* **对策**：重构合并逻辑，遍历批次内所有快照，按同一 Sender 的 `(ssid, max_seq)` 挑出序列号最大的索引置为 `s_isLatestSnap = true`，彻底消除链路延迟差导致的快照倒退。

### 陷阱 3：重复交易事件触发双倍风控扫仓与水位线歧义
* **机理**：`CopierReceiver.mq4:7223` 在调用 `RouteMessage()` 之前就无条件设置了 `hasFastAction = true`，导致第二份重复事件虽被 `AcceptSeq` 拦截，但依然触发全仓扫描；且 `HBT` 心跳与交易事件共用 `CP_STREAM_EVENTS` 水位线。
* **对策**：
  1. `RouteMessage()` 改为返回 `bool`，仅在通过安全检查且 `AcceptSeq` 成功时返回 `true`，`hasFastAction` 仅在返回 `true` 时激活。
  2. 新增 `#define CP_STREAM_HBT 2`，将 `g_lastSeq` 扩充为 3 路独立水位线（交易事件、快照、心跳），心跳不污染交易事件序列号。

### 陷阱 4：单 `"hub"` 对端名导致双 Hub 延迟与断线盲区
* **机理**：当前 `PONG` 固定使用 `FROM=hub`（`main.rs:582`）。两端双连时，较快 Hub 会清掉探针，较慢 Hub 的 RTT 永远测不出；若 Primary 宕机而 Standby 存活，Standby 回复 `FROM=hub` 会让 EA 面板误显“连接正常”，掩盖主机崩溃。
* **对策**：
  1. Hub 回复 `PONG` 时信封保持 `SID=hub`，载荷中填写 `FROM=hub:primary` 或 `FROM=hub:standby`。
  2. EA 对端表（`g_peers`）独立维护 `hub:primary` 与 `hub:standby` 两个对端槽位，图表面板分两行直观展示双端 IP、存活状态及独立 RTT。

### 陷阱 5：`ZMQ_IMMEDIATE=1` 握手期静默丢弃刚接入时的 `REG`
* **机理**：`CopierTransport.mqh:147` 开启了 `Immediate` 模式。当运行期调用 `connect(standby_ep)` 时，底层的 TCP + CURVE 异步握手需 50~200ms。此时同步发出的 `REG` 在未握手完成的套接字管道上会被 libzmq 直接丢弃，而启动期 3 次 `REG` 用完后不再补发。
* **对策**：新增 `ConnectExtraHub(endpoint)` 接口；当接入新端点时，强制重置 `g_announceCount = 0`，使接下来 3 个定时周期（0s, 5s, 10s）连续发送完整 `REG`，确保跨越握手期成功在 Standby 注册。

### 陷阱 6：主备切换命令 ID 序号碰撞与旧主覆盖
* **机理**：`commands.rs` 生成命令 ID 时采用本地计数器 `<node>-<op>-<seq>`。若主备切换时不延续该 `seq`，新主生成的命令 ID 会与旧主历史 ID 重复，被 Receiver 的 `CommandSeen` 环判定为已执行而静默丢弃。原主恢复若未受控，旧配置会反向覆盖新主配置。
* **对策**：
  1. Standby 导入命令记录时，执行 `self.seq = self.seq.max(imported_seq + 1)`，水位线只升不降。
  2. 引入 `cluster_state.json` 记录 `epoch`；旧主启动后若检测到对端 `epoch` 更高，必须自动降级为 Standby，关闭写闸并反向追平数据。

### 陷阱 7：告警配置同步缺失与集群内部接口鉴权
* **机理**：遗漏 `alert_channels.json` 同步会导致 Standby 接管后失去告警通知能力；内部集群 API 若缺少身份认证存在未授权越权风险。
* **对策**：
  1. 将 `alert_channels.json` 列为 5 大强同步文件之一。
  2. 配置文件显式提供 `cluster_auth_token`，主备间 HTTP 接口通过 Bearer Token 或标准 HMAC-SHA256 签名，配合本地防火墙白名单，保障内网通信安全。

### 陷阱 8：首次冷启动在 Primary 断电时的引导盲区
* **机理**：若用户属性框只填单个 Primary 地址，且本机是新安装环境（无历史缓存），若首次启动恰逢 Primary 停机，将无法获取 Standby 地址。
* **对策**：`HubEndpoint` 语法上原生兼容双地址输入（`ip1:6000;ip2:6001`）。首发阶段推荐用户配置双地址；后续即便增加 `T=TOPOLOGY` 自动发现，也始终保留双地址引导能力。

---

## 3. 主备数据同步引擎详细设计（Replication Engine）

### 3.1 同步范围与职责边界明确

| 数据类别 | 文件 / 状态载体 | 复制策略 | 冲突与版本管理机制 |
| :--- | :--- | :---: | :--- |
| **Web 账号体系** | `users.json` | **强同步** | 全量快照哈希比对。SHA-256 不一致时，Standby 原子替换并热重载 `UserStore`。 |
| **告警渠道通道** | `alert_channels.json` | **强同步** | 全量快照哈希比对。SHA-256 不一致时原子替换并热重载 `NotifyStore`。 |
| **CURVE 客户端白名单** | `curve_clients.txt` | **强同步** | 双向并集去重（Set Union）。Standby 学习到的新客户端汇总给 Primary 统一确认。 |
| **配置修订历史库** | `config_revisions.jsonl` | **强同步** | 按行号/字节偏移增量追加。Standby 更新内存 `max_rev`，确保版本连续递增。 |
| **管理操作命令流水** | `commands.jsonl` | **强同步** | 增量追加，Standby 持续将本地 `self.seq` 推高至最新已同步序号。 |
| **节点实时监控/持仓** | 内存 `Registry` / `Positions` | **无需同步** | 由 Sender/Receiver 双路上报，主备两端在各自内存中实时构建，天然鲜活。 |
| **客户端实际 INI 内容** | 客户端 `copier.ini` | **无需同步** | **客户端是唯一真实态**。客户端连上备机后带哈希报到，备机若缺失则通过 `reqcfg` 按需拉取。 |

### 3.2 复制协议工作流程

```
[Standby Hub]                                         [Primary Hub]
      │                                                     │
      │ 1. GET /api/v1/cluster/status (带签名)              │
      ├────────────────────────────────────────────────────►│
      │ 2. 返回 { epoch: 1, cfg_lines: 45, users_hash: ...} │
      │◄────────────────────────────────────────────────────┤
      │                                                     │
      │ (Standby 比对发现本地 cfg_lines 仅为 42)            │
      │                                                     │
      │ 3. POST /api/v1/cluster/sync { from_cfg_line: 42 }  │
      ├────────────────────────────────────────────────────►│
      │ 4. 返回新增 3 条 JSONL 记录及 SHA-256 校验码        │
      │◄────────────────────────────────────────────────────┤
      │                                                     │
      │ 5. Standby 校验签名与摘要，写入临时文件，原子替换落盘 │
      │ 6. 更新本地复制水位线，Web UI 状态置为 SYNCED       │
```

---

## 4. 故障切换运行手册（Fencing & Failover Protocol）

### 4.1 场景一：Primary 宕机 $\rightarrow$ Standby 人工受控接管（Promote）
1. **故障感知**：监控报警 Primary 失联；Standby 界面顶部显示 `[PRIMARY UNREACHABLE · STANDBY ACTIVE]`。
2. **数据面持续运行**：由于是双活连接，**所有订单继续正常跟单，无中断、无丢单**。
3. **运维 Fencing 隔离旧主**：
   - 运维人员登录 VPS 控制台，确认旧 Primary 进程已停止（或通过云防火墙切断其管理端口），防止旧主网络恢复后产生双写。
4. **执行提权（Promote）**：
   - 登录 Standby 控制台（`http://standby:6011`），点击顶部黄色按钮 **`⚡ Promote to Primary`**；
   - 弹窗确认已完成旧主隔离，输入管理员密码确认；
   - Standby 本地执行：`epoch++`，设置 `role = "primary"`，激活写闸门 `writes = true`，落盘 `cluster_state.json`；
   - 控制台恢复绿色 **`[PRIMARY · 读写激活]`**，即刻可进行配置修改与全队暂停操作。

### 4.2 场景二：原 Primary 机器修复重启
1. 原 Primary 机器开机，启动 `copier-hub`。
2. 启动初始化：读取本地 `cluster_state.json`（此时其记录的旧 `epoch` 为 1）。
3. 握手探测：向 Standby 发起集群状态探测，发现 Standby 当前 `epoch == 2` 且为 Primary。
4. **自动退位与对齐**：
   - 原 Primary 自动将本地角色置为 `role = "standby"`，关闭写闸 `writes = false`；
   - 自动将本地 `epoch` 更新为 2，落盘 `cluster_state.json`；
   - 作为 Standby 向现 Primary 发起增量同步请求，拉取离线期间产生的所有新配置与新命令；
   - 状态追平后，平稳作为热备节点继续工作，**零数据回滚、零人工风险**。

### 4.3 场景三：主机恢复并连续稳定在线超过 24 小时自动夺回 Master（Graceful Auto-Failback）

#### 为什么需要自动回切？
在实盘运维中，如果主机维护或短暂故障后变成 Standby 长期运行，运维人员极易混淆主备归属（记不住哪台机器在管写），导致误看监控、查错日志甚至误关备机。因此必须建立**“让主机（Primary Host）在绝大多数时候保持 Master 身份”**的自愈归位机制。

#### 为什么必须设定“连续在线超过 24 小时”门槛？
若主机一开机就立即抢回 Master，一旦主机发生偶发性网络抖动或硬件反复 Crash（Flapping 惊群震荡），会导致主备频繁争抢写闸门、配置版本撕裂。**24 小时连续在线稳定窗口（Stabilization Window）**能够绝对确保主机已彻底修复、硬件与网络已达生产级稳定。

#### 自动回切的三大前提门槛（缺一不可）
1. **数据完全对齐（Zero Lag）**：主机已从当前 Master（临时接管的备机）拉取并追平所有配置、命令与账号，本地与备机的 SHA-256 摘要完全一致。
2. **连续健康计时达标（连续 24 小时无中断）**：主机与备机间的互联心跳连续保持 24 小时（可配置参数 `failback_stabilization_hours=24`，测试环境可设为分钟级），期间未发生任何网络断开或丢包。
3. **未开启禁止回切标志**：运维未在控制台勾选 `Disable Auto-Failback`。

#### 两阶段安全握手交接协议（Two-Phase Handover Protocol）
杜绝任何“暴力单方抢权”引发的脑裂，交接全过程由两台 Hub 通过原子握手完成（耗时 < 50ms）：

```text
[原主机 (当前 Standby)]                                   [备机 (当前临时 Master)]
         │                                                         │
         │ 1. 满足 24h 连续健康 + 数据完全对齐                    │
         │    POST /api/v1/cluster/handover-request                │
         ├────────────────────────────────────────────────────────►│
         │                                                         │
         │                                                         │ 2. 备机校验通过:
         │                                                         │    a. 关闭自身写闸门 (writes = false)
         │                                                         │    b. 冻结写 API，生成 new_epoch = epoch + 1
         │                                                         │    c. 角色降级为 role = "standby" 并落盘
         │ 3. 返回 200 OK { agreed: true, new_epoch: 3 }           │
         │◄────────────────────────────────────────────────────────┤
         │                                                         │
         │ 4. 主机确认备机已安全闭闸:                             │
         │    a. 采用 new_epoch = 3                                │
         │    b. 角色升级为 role = "primary" 并落盘                │
         │    c. 开启写闸门 (writes = true)                       │
         │    d. 记录审计日志 cluster.failback_success             │
         ▼                                                         ▼
    [已夺回 Master, 读写激活]                                  [已平稳退回 Standby, 纯只读]
```
* **零双写保证**：备机在回复同意的**瞬间就已经关闭了写闸门**，因此集群在任何一微秒内都不存在两个 Hub 同时可写的状态。
* **运维可观测性与控制**：
  - Web 控制台顶部常驻显示倒计时指示条：`[主机连续健康在线 19h / 24h · 预计 5 小时后自动回切为 Master]`；
  - 提供 **`⚡ 立即安全回切 (Force Safe Failback Now)`** 按钮：运维人员在场确认主机健康时，无需等待 24 小时，一键触发上述安全握手立即归位；
  - 提供 **`锁定备机为 Master (Lock Standby as Master)`** 复选框：当主机计划下线或硬件检修时，可随时阻断自动回切。

---

## 5. 分阶段实施全景路线图（Phased Roadmap）

本方案严格采取**“每一阶段可编译、可测试、可独立回退”**的渐进式实施步骤：

```
Phase 0: 决策签字与基线测试 (验证现有代码行为，建立测试基线，不改业务代码)
   │
   ▼
Phase 1: 客户端双活增强与显式双地址 (消除快照逆序/收据风暴隐患，支持双连接)
   │
   ▼
Phase 2: Hub 服务端集群角色与数据同步引擎 (实现主备文件增量复制与只读写闸)
   │
   ▼
Phase 3: Web 控制台双机感知与受控提权 UI (状态胶囊、只读保护、一键 Promote)
   │
   ▼
Phase 4: 自动化拓扑发现 (T=TOPOLOGY) 与端到端混沌测试 (实现单地址全自动引导)
```

### 阶段详细任务拆解表

| 阶段 | 核心任务目标 | 关键改动文件与技术点 | 验收与通过条件 |
| :--- | :--- | :--- | :--- |
| **Phase 0**<br>(当前阶段) | **基线确认与探针测试**<br>（不修改任何业务代码） | 1. 运行 `tools/tests.sh --all` 确认 100% 全绿；<br>2. 编写轻量 Python 探针测试当前 `m_sub` 双 `connect()` 时的消息接收与 PONG 行为；<br>3. 签署确认 ADR-01 至 ADR-09。 | 探针测试输出清晰日志，现有单 Hub 功能零回归。 |
| **Phase 1** | **客户端双活幂等加固与双连**<br>（支持显式双地址） | 1. `CopierDefs.mqh`：实现端点解析函数（支持分号分隔）；<br>2. `CopierReceiver.mq4`：修复快照逆序合并 bug（按最大 SEQ 选快照）；分离 `HBT` 水位线；后置 `hasFastAction`；<br>3. `CopierSender.mq4`：`SnapTrack` 增加 250ms 同 Hash 抑制；<br>4. `CopierTransport.mqh`：新增 `ConnectExtraHub` 支持动态双连；<br>5. 扩展 PONG 载荷与图表面板双行 RTT 显示。 | 启动两个测试 Hub，客户端填入双地址，两端均能正常通信；杀掉任一 Hub，跟单毫无卡顿。 |
| **Phase 2** | **Hub 集群状态机与数据同步** | 1. 新增 `hub/src/cluster.rs`：集群状态机、`cluster_state.json` 管理、增量同步后台线程；<br>2. `hub/src/main.rs`：增加 `--role primary/standby`、`--peer-api`、`--failback-hours` 参数；Standby 默认控制帧静默，失联 6s 自动接管 `RCPT`；<br>3. `config.rs` & `commands.rs`：支持增量导出与导入，命令序号对齐；<br>4. `api.rs`：挂载 `/api/v1/cluster/*` 同步接口，支持两阶段安全回切协议（`/handover-request`），非 Primary 节点写操作统一 409 拦截。 | 启动主备两个 Hub，在主节点改配置/添加用户，3 秒内自动同步至备节点；备节点写接口被安全拦截。 |
| **Phase 3** | **Web 控制台主备感知与提权** | 1. `dashboard.html`：顶部显示集群状态胶囊（Primary/Standby）；<br>2. Standby 页面全局置灰写操作，显示醒目的只读横幅；<br>3. 增加 `[⚡ Promote to Primary]` 按钮与二次确认弹窗；<br>4. 增加主机回切倒计时提示条、`[⚡ 立即安全回切]` 按钮与 `[锁定备机为 Master]` 复选框；<br>5. 前端支持主节点离线时一键跳转对端备用控制台。 | 操作员在 Standby 控制台点击提权后角色升级；主机健康在线达标后或点击提前回切后，两阶段握手安全归位，无双写窗口。 |
| **Phase 4** | **自动拓扑发现与混沌验收** | 1. 协议引入 `T=TOPOLOGY`，Hub 处理 `REG` 时自动下发拓扑；<br>2. EA 本地落盘 `copier_hub_cluster.st` 缓存；<br>3. 新端点接入时触发 `g_announceCount = 0` 重发完整 `REG`；<br>4. 编写自动化混沌测试脚本，在交易脉冲并发中突发 kill 进程演练。 | 客户端仅填单个主地址，自动发现并连接备机；全量混沌容灾演练通过，输出测试报告。 |

---

## 6. 核心测试用例矩阵（必须验证场景）

为确保生产环境万无一失，整个实施必须通过以下 12 项严密契约测试：

| 用例 ID | 测试场景 | 测试操作步骤 | 预期判定结果（PASS 标准） |
| :--- | :--- | :--- | :--- |
| **TC-01** | **单 Hub 兼容性回归** | EA 仅配置单个 Primary 地址运行 | 行为与改动前 100% 一致，无新增错误日志。 |
| **TC-02** | **双活同时转发幂等性** | Sender 同时通过双 Hub 发送同一笔 `OPEN` | Receiver 仅开出一张单，`g_seen` 拦截第二笔，无重复风控扫仓。 |
| **TC-03** | **快照乱序合并验证** | 人为让旧快照 `SEQ=1` 晚于新快照 `SEQ=2` 到达 | Receiver 正确识别并合并 `SEQ=2`，决不被旧快照覆盖。 |
| **TC-04** | **收据防风暴验证** | 正常运行下检查 Sender 日志 | Standby 静默不发收据，Sender `g_snapIntMs` 稳定在 1000ms，无快照重发风暴。 |
| **TC-05** | **主 Hub 突发下线容灾** | 交易打流期间突发 `kill` 掉 Primary 进程 | 备路毫秒级顶上，所有在途与后续订单 100% 正常复制；6 秒后 Standby 接管 `RCPT`。 |
| **TC-06** | **数据持久化增量对齐** | Primary 连续下发 3 个配置版本并添加新用户 | Standby 增量拉取成功，两端 `config_revisions.jsonl` 与 `users.json` 摘要一致。 |
| **TC-07** | **命令序号防碰撞** | Primary 下发 2 条命令后停机，Standby 提权 | Standby 新发命令 `seq` 从 3 开始递增，命令 ID 绝不与旧主碰撞。 |
| **TC-08** | **旧主重启防脑裂** | Standby 提权后，旧主重新启动 | 旧主读取到更高 `epoch`，自动降级为 Standby，写闸保持关闭，并反向拉取新配置。 |
| **TC-09** | **24h 稳定期自动夺回 Master** | 主机恢复并稳定在线达标（测试配为 2 分钟） | 主机自动触发两阶段交接：备机先关闭写闸并降级，主机获得 new_epoch 并开启写闸，全过程零双写。 |
| **TC-10** | **手动提前回切与锁定测试** | 点击「立即安全回切」或勾选「锁定备机」 | 点击立即回切触发安全交接归位；勾选锁定则倒计时暂停，绝不发生自动回切。 |
| **TC-11** | **客户端重启自愈** | Primary 宕机期间重启 MT4/MT5 终端 | EA 读取本地 `copier_hub_cluster.st` 缓存，直接连通 Standby 上线跟单。 |
| **TC-12** | **回滚安全性验证** | 客户端改回单地址配置，停用 Standby | 系统安全平稳回退至单机模式，历史订单不受影响。 |

---

## 7. 结论与当前就绪状态

本方案将用户初衷的实用性、v2 草案的深层工程修补以及评审专家的工业级审慎原则有机融为一体：
- 既获得了**双端双活“0ms 链路容灾”**的极致跟单体验；
- 又通过**受控单写与 Epoch 机制**封死了脑裂与数据覆盖隐患；
- 同时通过**分阶段交付**避免了“一步迈太大引入新 Bug”的系统性风险。

**当前状态**：方案已完整起草定案，代码库未做任何破坏性修改。待您与团队核准确认后，即可正式启动 **Phase 0（基线与探针测试）**。
