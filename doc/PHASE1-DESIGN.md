# Phase 1 · 透明代理 —— 详细设计

> 上位文档：`doc/CENTRAL-HUB-PLAN.md`（v2.3，D1–D14 已全部确认）
> 本阶段目标：**让数据面先跑通，且 Tier 1 一个字节都不改。**
> 本阶段**不做**：注册表、监控、配置下发、前端、主备。

---

## 1. 目标与验收标准

### 目标

让 receiver 通过中枢收数据，**功能与直连完全等价**；sender 同时走两条通道。

### 验收标准（全部可测）

| # | 标准 |
|---|---|
| A1 | 直连 receiver 与"经中枢"receiver 的**持仓完全一致**（品种/方向/手数/SL/TP） |
| A2 | 两条通道的**开平仓时刻差 < 一个快照周期**（默认 2s） |
| A3 | **中枢停掉**：Tier 1 完全不受影响；经中枢的 receiver **保留持仓、停止新开** |
| A4 | **中枢重启**：receiver 自动恢复收敛，**不需要重挂 EA** |
| A5 | 把 `HubEndpoint` 清空 → **回到 Tier 1**，行为与升级前一致 |
| A6 | 端到端延迟增量**可测量**（目标 < 5ms 同机房） |

> A3 和 A4 是本阶段最重要的两条——它们验证的是"中枢可以是单点"这个前提（§21-R1）。

---

## 2. 实施顺序（**先 Python 后 Rust**）

```
Step 1  用 Python 写一个 ~40 行的原型中枢   tools/hub_proto.py     ✅ 已完成
        ↓ 先用它验证拓扑，不写任何 Rust
Step 2  改 sender（HubEndpoint + 双通道）                          ✅ 已完成
Step 3  改 receiver（HubEndpoint + 多前缀订阅 + 两帧接收）          ✅ 已完成
Step 4  用 Step 1 的原型中枢跑通 A1–A4                             ✅ 已完成
Step 5  把原型移植成 Rust（行为已经被验证过，只需对齐）             ✅ 已完成
```

### ✅ Step 5 已完成：Rust 中枢

`hub/` 是一个独立的 Rust 工程，**行为与 Python 原型逐条对齐**——
而且"对齐"是**量出来的**，不是声称的：同一个测试套件跑两个二进制。

```
python tools/hub_proto_test.py                                          13/13 PASS
python tools/hub_proto_test.py --hub hub/target/release/copier-hub.exe  13/13 PASS
```

`hub/build.sh --test` → 9/9 单元测试。

**Python 原型没有作废，它是参考实现**——Rust 版只有在与它一致时才算对。
两个都保留可运行，正是"行为相同"能被测量的前提。

三个必须记下来的工程约束（`hub/build.sh` 把它们收在一处）：

| 约束 | 为什么 |
|---|---|
| **`zmq` 钉在 0.9.2** | 0.10 拉 `zmq-sys` 0.12，其 build script **无条件 vendored**（要 cmake + C++ 编译器，而且会链**另一个版本**的 libzmq，正是 §14 要避免的）。0.11 的 `vendored` 是**可选** feature，关掉后走 `LIBZMQ_PREFIX` 找系统库 |
| **不用 `ctrlc` crate** | 它拉 `windows-sys`，后者在 windows-gnu 上要靠 `dlltool` 生成导入库，而 Rust GNU 工具链**只给 dlltool、不给它需要的 `as`/`ar`**。为 20 行信号处理装 100 MB mingw 不值得，改成直接 FFI |
| **`libzmq.a` 是一个链接脚本** | `zmq-sys` 发 `-lzmq`，所以搜索路径里必须有 `libzmq.a`。真正的导入库要 dlltool（跑不了）。但 **GNU `ld` 能直接链 DLL**——所以"导入库"是一行 `INPUT(libzmq.dll)`。端到端验证过：产物运行并报出 `libzmq 4.3.5` |

链的是 `third_party/zmq-prefix/`——**EA 正在用的那一份 libzmq 4.3.5**，
兑现 §14 的"必须与 EA 侧同一个 libzmq"。（本节写于 4.2.1 时代；前缀里的 DLL
已升级到 4.3.5，链接方式一字未改。旧版保留在 `third_party/zmq-prefix.4.2.1.bak/`。）

细节见 **`hub/README.md`**。


### Step 4 操作手册

**不要用 `python tools/hub_proto.py`** —— 在一台 Python 没有关联文件类型、
或者 `python` 不在 PATH 的机器上，这会得到一个 Windows 弹窗问"要用什么打开"，
看起来像脚本坏了，其实什么都没坏。用包装脚本，它自己去找 Python 并检查 pyzmq：

```cmd
:: cmd（或直接双击）
tools\hub.bat                    :: 启动中枢，Ctrl-C 停止
tools\hub.bat --port 6100
tools\hub.bat --verbose

:: 或者通过统一入口
tools\copier.bat hubtest         :: 先跑路由自测（不需要终端、不需要经纪商）
tools\copier.bat hub             :: 再启动中枢
```

```bash
# Git Bash
./tools/hub.sh --port 6100
```

**完整流程：**

```
1. 先验中枢本身（不需要任何 EA）
      tools\copier.bat hubtest          → 应该 13/13 PASS

2. 启动中枢
      tools\copier.bat hub

3. 挂 sender：HubEndpoint = tcp://127.0.0.1:6000
   从它的启动日志读 NID：
      sender 5555 listening on port 5555 ... nid=123456789
   面板应出现：
      Channel    direct + central   NID 123456789
      HUB  tcp://127.0.0.1:6000   2 ms round trip

4. 手工写 MQL\Files\copier.ini（Phase 1 还没有下发）
      [sender0]
      id      = 123456789        ← sender 的 NID，不是端口
      magic   = 5555
      lotmode = multiplier
      lotparam = 1.0

5. 挂 receiver：HubEndpoint = tcp://127.0.0.1:6000
   启动日志应出现：
      central mode: 1 sender(s) from copier.ini - subscribing to ...
      receiver up, 1 sender(s), magic ..., mode=CENTRAL, NID ...

6. 中枢那边应出现：
      +sub 123456789      data from sender 123456789
      +sub @222222        control for 222222
```

> ### ⚠️ 第 4 步是这一步里唯一会踩的坑
>
> **一份现成的 copier.ini 里的 `id=` 一定是错的。** 直连模式下它是 sender 的
> 名字或端口（`sender01`、`5555`），而中枢模式下**主题就是 NID**——
> 订阅 `sender01` 永远匹配不到任何东西。
>
> 而且**它不会报错**：一个匹配不到任何东西的订阅，对 ZMQ 来说不是错误。
> receiver 会连上、会打印"subscribed to 3 topic(s)"、然后**静静地什么都不做**。
>
> 所以 receiver 现在有一条专门的告警：**中枢模式下订阅了但 30 秒什么都没收到**
> 就会报 ERROR，并把当前订阅的 id 列出来，提示它们应该是 NID。
>
> 每个 sender 的启动日志里都有一行 `nid=<数字>`，那就是要填的值。

**`HubEndpoint` 只需要填 `IP:port`**——`tcp://` 会自动补上，
和 ini 里的 `events=` 一样（那个一直是这么处理的）。

**注意两个 EA 都要移除再重新挂载**——input 列表都变了。

### ✅ Step 1 已完成

| 文件 | 说明 |
|---|---|
| `tools/hub_proto.py` | 原型中枢（XPUB bind，两帧原样转发，`@` 主题一律消费） |
| `tools/hub_proto_test.py` | 路由验证：假 sender + 两个假 receiver，**9/9 PASS**，不需要终端/经纪商/EA |

已验证的 9 条（全部通过）：

```
PASS  data reaches the receiver subscribed to that sender
PASS  ...and NOT one subscribed to a different sender
PASS  the second sender reaches only its own receiver
PASS  frame 1 arrives byte-identical (the hub does not re-encode)
PASS  frame 0 is the routing key
PASS  a control message is consumed, never echoed back down
PASS  ...and an '@' topic is never forwarded, whoever sent it
PASS  a non-envelope frame is dropped, not forwarded
PASS  '@' namespace: a control subscriber receives no data
```

**这 9 条正好覆盖 §1 验收标准里数据面的部分**，而且是**不碰任何 EA** 就能跑的。

> 写这个测试时踩了两个坑，**两个都在测试里、不在中枢里**——值得记一下，
> 因为它们的症状都指向错误的方向：
>
> 1. **中枢的 stdout 被块缓冲**（重定向到文件时 Python 的默认行为），
>    于是被 kill 的中枢**日志是空的**——看起来像"它根本没启动"。
>    已在中枢里显式开行缓冲。
> 2. **测试末尾 `Context.term()` 永久阻塞**：它要等所有 socket 关闭，
>    而测试从不逐个关。所有检查**都已经 PASS 之后**才卡住，
>    所以看起来像中枢的问题。改用 `ctx.destroy(linger=0)`。
>
> 顺手把测试改成**每条检查立即打印**——只在最后统一输出的测试，
> 一旦卡住就什么都不告诉你，而卡住恰恰是最需要知道"跑到哪一步"的时候。

**为什么先写 Python 原型**：Phase 1 的中枢是**纯转发**，逻辑量极小。
用一个一次性的 Python 脚本把拓扑跑通，可以在**不写 Rust、不建工程**的前提下
回答所有协议问题；等 EA 侧稳定了，Rust 版只是"把已验证的行为重新实现一遍"。
仓库里已有 `tools/zmq_sniff.py` 这类工具，符合既有做法。

> 原型不是交付物，验证完就留在 `tools/` 当调试工具用。

---

## 3. 中枢：最小实现

### 3.1 一个 socket

```
XPUB  bind 0.0.0.0:6000        ← 所有 EA（sender 与 receiver）都 XSUB connect 到它
```

**为什么一个 socket 就够**：

* ZMQ 的**订阅过滤只作用于发送方向**。中枢发什么，只有订阅了对应前缀的 EA 收得到
* **接收方向不受订阅影响**——XPUB 会把所有 XSUB 对端发来的消息**全部**交给应用层
* 所以中枢不需要为自己订阅任何东西

这与计划书 §3.1 的结论一致，也符合你的描述（"Rust 作为 XPUB 发布者，所有 EA 订阅它"）。

### 3.2 主循环

```
loop:
    parts = poll_and_recv()                 # 多帧
    if len(parts) < 2:
        continue                            # 单帧 = 订阅字节（\x01<prefix>），丢弃
    topic, payload = parts[0], parts[1]

    if not payload.startswith("V="):
        log_warn("garbage on topic " + topic); continue    # 便宜的自检

    if topic.startswith("@"):
        handle_control(topic, payload)      # 消费；PING 要回 PONG（见下）
    else:
        republish(topic, payload)           # 原样两帧转发
```

**就这么长。** Phase 1 的中枢不需要知道：
sender 列表、receiver 列表、账户号、ini、持仓 —— **全都不需要**。
它只需要"把收到的数据帧照原样再发一遍"。

#### 唯一由中枢主动发出的消息：`PONG`

**这不是范围蔓延，是必需的。** ZMQ 的 `connect()` **立刻成功，不管对端有没有在听**——
所以一个节点无法凭连接状态判断链路是死是活。没有回包，
sender 面板会对着一个不存在的 hub 永远显示 "connected"，**一个假的绿灯**。

```python
if t == "PING":
    nid = envelope_kv(payload, "FROM")
    ms  = envelope_kv(payload, "MS")
    send_pong(sock, nid, ms, state)      # 把节点自己的 ms 原样回显
```

* **零状态**：把节点自己的毫秒值原样回显，`now - echoed` 就是真实往返，
  **不涉及任何时钟同步**
* 不违反 §3.1 的判据——它仍然**不知道有哪些节点**，只是回一声
* 回包地址来自 PING 里的 `FROM`，所以 sender 和 receiver 都能用它测链路

### 3.3 三条必须守住的规矩

1. **Frame 1 一个字节都不碰。** 不重新编码、不改 `SEQ`、不改 `SSID`、不改 `TS`。
   这是 §3.2 的核心原则，也是"中枢不可能下错单"的**结构性**保证。
2. **中枢不生成 `SSID`。** 它只转发。所以中枢重启**不会**让 receiver 误判 sender 重启。
3. **两帧原样转发。** Frame 0（主题）也不重写——sender 已经在它自己那侧写好了。

### 3.4 队列与丢弃

| 项 | 值 | 理由 |
|---|---|---|
| `SNDHWM` / `RCVHWM` | 1000 | 沿用现有 `CP_SNDHWM` / `CP_RCVHWM` |
| `LINGER` | 0 | 否则 `ctx_term` 阻塞，进程杀不掉 |
| 丢弃策略 | **允许丢** | 快照是幂等全量状态，丢了 2 秒后自愈 |

**本阶段不做 conflation**（中枢不解析 `T=SNAP` 去只留最新一条）。
理由：Phase 1 的节点数量少，HWM 足够；而且 conflation 需要解析 `T=`，
会把"中枢完全不理解载荷"这个性质打破。留作 Phase 4 的优化，见 §9。

---

## 4. Sender 改动

### 4.1 新 input

```cpp
input string HubEndpoint = "";   // HubEndpoint - 中央Hub, 例 tcp://10.8.0.1:6000; 留空=只用直连
```

### 4.2 传输层需要新增的 API（`CopierTransport.mqh`）

现有 API 不够用，需要三个小方法（**不改动任何现有方法**）：

```cpp
// 连接中枢：只连接 + 可选 CURVE，【不自动订阅】。
// ConnectReceiver() 会自动发 \x01（订阅全部），在中央通道上那是错的：
// 订阅全部意味着 sender 会收到其他 sender 的全部数据。
bool ConnectHub(const string endpoint, const bool useCurve,
                const string serverKey,
                const string myPublicKey, const string mySecretKey);

// 订阅 / 退订一个前缀
void Subscribe(const string prefix);      // m_sub.send("\x01"+prefix)
void Unsubscribe(const string prefix);    // m_sub.send("\x00"+prefix)

// 发一条两帧消息（主题 + 载荷）
bool SendUp(const string topic, const string payload)
  {
   if(!m_sub.sendMore(topic)) return false;
   return m_sub.send(payload);
  }

// 收：把多帧拆成 (主题, 载荷) 两个平行数组。
// 单帧消息 → topic="" ，这样 Tier 1 和 Tier 2 可以走同一个解析循环。
int DrainFrames(string &topics[], string &payloads[], const int maxMsgs);
```

> `DrainFrames` 让**两条通道共用同一份解析代码**：Tier 1 单帧 → `topic=""`；
> Tier 2 两帧 → `topic=<NID>`。调用方不需要知道自己连的是哪种。

### 4.3 发送路径

```cpp
void Emit(const string type,const string payload,const bool snapshot)
  {
   ...  // 组装 CopierEnv（不变）
   string msg=CopierEncodeEnv(e);

   bool ok=g_tp.Send(msg);                       // 直连：单帧，SID=EventsPort（不变）
   if(g_hubOn)
      g_tp.SendUp(g_nid, msg);                   // 中央：两帧，同一份 msg，不重新编码
   ...
  }
```

**注意**：`Emit()` 里 `e.sid` 需要按通道不同而不同（直连=端口，中央=NID）。
两种做法：

* **(i) 编码两次**：`e.sid=EventsPort` 编一份走直连，`e.sid=NID` 编一份走中央。
  两条通道各自完整，代价是每 tick 多一次字符串编码。
* **(ii) 只改 `SID` 字段**：编码一次，中央通道上把 `SID=<port>` 子串替换成 `SID=<NID>`。
  快，但**是字符串手术**，容易出错。

**建议 (i)**：多一次编码的代价可忽略（每秒几次），换来的是"两条通道各自完整、
不互相污染"。**在这个代码库里，正确性永远优先于微优化。**

### 4.4 接收路径

sender 现在 `OnTimer` 里 drain `m_pub`（收 receiver 的 `STAT`/`PING`/`PONG`）。
Tier 2 下**再加一个 drain**（`m_sub`，收中枢的控制指令）：

```
m_pub  → DrainStatus()   Tier 1 和 Tier 2 都要（直连 receiver 可能还在）
m_sub  → DrainFrames()   仅 Tier 2（中枢的控制指令；Phase 1 只记日志）
```

### 4.5 启动顺序

```
1. BindSender(...)                       ← 直连，永远做
2. if(HubEndpoint != ""):
       ConnectHub(HubEndpoint, ...)
       Subscribe("@" + g_nid)            ← 只订阅发给自己的控制
       g_hubOn = true
       log: "central channel: connected to <HubEndpoint> as NID=<g_nid>"
   else:
       log: "central channel: off (direct only)"
```

**`g_nid` 必须打印在启动日志里**，因为 receiver 的 ini 需要填它（§5.3）。

### 4.6 面板（D14）

见计划书 §8.3。Tier 2 下多一行中枢状态，**直连那部分信息保留**：

```
Channel    direct + central   NID 111111
HUB  tcp://10.8.0.1:6000   12 ms round trip
```

**hub 就是 `CopierPeerTable` 里的一个普通 peer**（固定名 `hub`），
复用现成的行渲染、超时判定和 `PING`/`PONG` RTT。唯一特殊的是显示成
`HUB <endpoint>`——把它显示成一个 receiver 会让上面的计数看起来像两个接收方。

#### ✅ Step 2 已完成

| 改动 | 位置 |
|---|---|
| `CopierNid(account)` | `CopierDefs.mqh` — 账号截断为 ≤9 位（**保留后 9 位**；**避开 0**，见下） |
| `ConnectHub` / `Subscribe` / `Unsubscribe` / `SendUp` / `DrainFrames` | `CopierTransport.mqh` — **五个新方法，没有改动任何现有方法** |
| `HubEndpoint` input + `g_nid` / `g_hubOn` | `CopierSender.mq4` |
| 双通道 `Emit()`：直连 `SID=端口` 单帧，中央 `SID=NID` 两帧 | `CopierSender.mq4` |
| `OnTimer` 多 drain 一个 socket（中枢下行）+ hub PING | `CopierSender.mq4` |
| 面板 `Channel` 行 + `HUB` 行 | `CopierSender.mq4` |
| `PONG` 回显（中枢唯一主动发出的消息） | `tools/hub_proto.py` |

**`CopierNid` 避开了 0，这不是洁癖**：magic 0 在本代码库里是**手动单**的标记，
而 receiver 是按 magic 找自己的镜像的——magic 为 0 的镜像会和操作员自己的手动单
落在同一个集合里，**被一起管理、一起平掉**。只有 1e9 的整数倍账号会撞上，
罕见但并非不可能。已加自测断言钉住。

**验证**：`CopierSender` 四目标 `0 errors, 0 warnings`；断言 405 → 414；
`hub_proto_test.py` **13/13 PASS**（含新增的 3 条 PONG 检查）。

> 传输层那两个方法是本次最省事的地方：`m_sub` 自这个 EA 写出来就没被用过
> （`Emit()` 走 `m_pub`，其他也都走 `m_pub`），所以中央上行**不抢任何已占用的资源**。

---

## 5. Receiver 改动

### 5.1 input 变更

```cpp
// 移除:  input string ConfigFile = "copier.ini";
// 新增:
input string HubEndpoint = "";   // HubEndpoint - 中央Hub; 留空=用下面input单sender直连
```

**`copier.ini` 的路径固定**为 `MQL\Files\copier.ini`（不再可配）。

**模式判断（按你的补充）**

| `HubEndpoint` | `copier.ini` | 模式 |
|---|---|---|
| 空 | 不存在 | **单 sender input 模式** |
| 空 | 存在 | **单 sender input 模式**（ini 被忽略，见下） |
| 非空 | 存在 | **中枢模式**，按 ini 里的 `id=` 订阅各 sender |
| 非空 | **不存在** | **中枢模式，但镜像 0 个 sender** + 明确告警 |

**`copier.ini` 只属于中枢模式。** 初级用户根本不知道有这个文件——输入对话框里
关于它的说明已经移除——所以它不应该再影响直连模式的行为。

#### ⚠️ 这个简化有一个迁移影响，必须显式处理

老版本里 `copier.ini` 是**多 sender 直连**的唯一途径（一个 receiver 直连 N 个 sender）。
现在它在中枢模式之外被忽略，那么：

```
某个进阶用户升级前：HubEndpoint 空 + copier.ini 里有 [sender0][sender1][sender2]
升级后如果静默忽略该文件 → 退回单 sender input 模式 → 只镜像 1 个 sender
```

**从 3 个变成 1 个，而且什么都不说。** 这正是本代码库一直在防的那类问题。

所以：**`HubEndpoint` 为空但 `copier.ini` 存在时，必须报警并说清怎么办**
（启动时一行 WARNING，指出文件被忽略、以及两个选择：填 `HubEndpoint` 走中枢，
或删掉文件 / 每个 sender 挂一个 receiver 实例）。

> 直连多 sender 的替代路径本来就存在，而且文档里写了：
> **"For a second sender without a file, attach a second CopierReceiver to
> another chart, one sender per instance."** 所以能力没有丢，只是入口变了。

#### 修正的是最后一行（中枢模式的自举）

你写的是"ini 不存在 → 用 input 单 sender 模式"，但那会让**中枢模式的第一次配置变成死锁**：

```
Phase 3 的引导流程：
  1. receiver 填好 HubEndpoint，启动
  2. 连上中枢 → 中枢发现它没有配置 → 下发 ini
  3. receiver 收到 ini，开始镜像

如果"ini 不存在就退回单 sender input 模式"：
  第 1 步 receiver 不会去连中枢，而是去连 SenderIP/SenderPort
  → 中枢根本联系不上它 → 第 2 步永远发生不了 → 死锁
```

正确的切分是：**连不连中枢只由 `HubEndpoint` 决定，ini 只决定"订阅哪些 sender"。**
ini 缺失时 receiver 照样连上中枢、订阅自己的控制主题，只是镜像 0 个 sender，
并**大声说明**（不是静默换模式——那正是最难查的一类问题）。

Phase 1 还没有下发，所以 ini 由人工先写好（§5.3）；但这个判断逻辑从 Phase 1 就按
最终形态实现，Phase 3 不需要回头改。

### 5.2 连接与订阅

```cpp
if(HubEndpoint != "")
  {
   g_tp.ConnectHub(HubEndpoint, ...);        // 只连接，不订阅
   g_tp.Subscribe("@" + g_nid);              // ① 发给我自己的控制指令
   for(int i=0;i<g_nSenders;i++)
      g_tp.Subscribe((string)g_nidOf[i]);    // ② 我镜像的每个 sender（来自 ini 的 id=）
  }
else
   ...  // Tier 1 原样不变
```

**② 是方案 B 的关键**：订阅列表**直接来自 ini**，所以
**中枢不需要做任何 per-receiver 的路由计算**——它只管发，ZMQ 负责投递。

### 5.3 ini 在中央模式下的含义

| 键 | 直连模式 | 中央模式 |
|---|---|---|
| `events=` | `tcp://<sender>:5555` | **被忽略**（receiver 连的是中枢，不是这个地址） |
| `id=` | sender 的 **EventsPort** | sender 的 **NID**（截断后的账号） |
| `magic=` | 显式值 | 同上（Phase 1 不变；将来默认=NID） |
| `lotmode/lotparam/suffix/symbol.*` | 不变 | 不变 |

**Phase 1 的引导步骤**（因为还没有配置下发）：

```
1. 启动 sender，从它的启动日志/面板读出 NID（例：111111）
2. 在 receiver 的 copier.ini 里写：id = 111111
3. 启动 receiver，填 HubEndpoint
```

> 这一步将来由中枢自动完成（Phase 3 的 `CFG` 下发）。
> Phase 1 手工填一次即可，但**必须在文档里写清楚**，否则第一次试的人会卡在这里。

### 5.4 接收路径（两条通道共用一份解析）

```cpp
string topics[], payloads[];
int n=g_tp.DrainFrames(topics,payloads,CP_DRAIN_MAX);
for(int i=0;i<n;i++)
  {
   // topics[i] 为空 = 单帧（Tier 1）；否则 = 主题（Tier 2）
   CopierEnv e;
   if(CopierDecodeEnv(payloads[i],e)!=CP_ERR_NONE) continue;
   ...  // 后面完全不变
  }
```

**现有 drain 循环里的快照 conflation、`last_seq` 守卫、SID 路由全部照旧**——
因为 `payloads[i]` 就是原来的字符串。

> 这是"Frame 1 与直连通道逐字节相同"换来的直接好处：
> **收敛逻辑一行都不用改。**

### ✅ Step 3 已完成

| 改动 | 说明 |
|---|---|
| 移除 `ConfigFile` input，新增 `HubEndpoint` | ini 路径改为固定的 `#define CP_INI_PATH "copier.ini"` |
| `LoadConfig()` 拆成三段 | 模式判断 / `LoadConfigForHub()` / `LoadConfigFromInputs()` |
| **直连模式下 ini 存在时报警** | 不让"3 个 sender 变 1 个"静默发生，并给出两条出路 |
| `LoadConfigForHub()` | 同一份 ini 格式；`events=` **不读**、`id=` 是 **NID**；**ini 缺失不是错误** |
| 连接分叉 | 中枢模式 `ConnectHub` + `Subscribe("@<NID>")` + 每个 sender 的 NID |
| drain 改走 `DrainFrames` | **两条通道共用同一个解析循环**，收敛逻辑一行未改 |
| `InstanceSuffix()` 改键 | 直连用 `Magic`，中枢用 **NID**（Magic 在 ini 读出来之前还不知道） |
| 启动日志带 `mode=` | 因为"0 sender(s)"在两种模式下含义完全不同 |

**两个实现细节值得记：**

**1. `InstanceSuffix()` 的键必须换。** 它决定状态文件与日志文件的名字，
而且在 `OnInit` **最开头**就要算出来（早于 `LoadConfig`）。中枢模式下它是
"一个实例服务 ini 里的所有 sender"，所以 `Magic` 是错的键——**而且根本拿不到**，
因为哪些 magic 存在是由还没读的 ini 决定的。改用 **NID**（账号的函数，随时可算）。

**2. 启动日志必须写明模式。** `receiver up, 0 sender(s)` 在直连模式是配置错误，
在中枢模式是"已连上、等中枢推配置"——**没有 `mode=` 这两个状态无法区分**。

---

## 6. 中枢的配置

Phase 1 只需要一个端口：

```toml
# hub.toml
listen      = "tcp://0.0.0.0:6000"
log_level   = "info"
```

**没有节点清单、没有账户表、没有 ini。** 这是 Phase 1 的一个刻意特征：
如果中枢需要知道"有哪些节点"，那说明设计里混进了 Phase 2 的东西。

---

## 7. 启动顺序与自愈

### 7.1 谁先起都行

ZMQ 的 `connect` 会自动重连（现有代码已设 `ReconnectInterval=100ms`），所以：

| 顺序 | 结果 |
|---|---|
| 中枢先起，EA 后起 | 正常 |
| EA 先起，中枢后起 | EA 的 XSUB 自动重连，几秒内通 |
| 中枢重启 | EA 自动重连；**因为 `SSID` 是 sender 生成的、中枢只透传，receiver 不会误判 sender 重启** |

### 7.2 中枢挂掉时 receiver 的行为（A3）

| 机制 | 效果 |
|---|---|
| 喂价停滞闸门（已实现） | 时钟 60 秒不动 → **拦住所有新开仓** |
| 现有持仓 | **保留**，不主动平（和 `StaleSeconds` 的策略一致） |
| 恢复后 | 下一个快照自动收敛 |

**这条不需要为 Phase 1 写任何新代码**——是现有机制自然生效。

---

## 8. 验证方案（A1–A6 怎么测）

### 8.1 准备

```
Sender S  ──直连──►  Receiver A（Tier 1，基线）
          └─中枢──►  Receiver B（Tier 2）
```

同一个 sender 双通道，A 和 B 镜像同一个账户。

### 8.2 测什么

| 步骤 | 期望 |
|---|---|
| 1. S 开 3 笔（含 SL/TP） | A 和 B 各开 3 笔，**品种/方向/手数/SL/TP 完全一致** |
| 2. 记录两边的开仓时刻 | 差 < 2s（一个快照周期） |
| 3. S 改一笔的 SL | A 和 B 都跟着改 |
| 4. S 平一笔 | A 和 B 都平 |
| 5. **停掉中枢** | A 不受影响；**B 保留持仓、停止新开**，日志出现喂价停滞告警 |
| 6. S 再开一笔 | A 开；B **不开** |
| 7. **重启中枢** | B 在几秒内把第 6 步那笔补开（快照收敛） |
| 8. 清空 B 的 `HubEndpoint` 并重挂 | B 回到 Tier 1，直连 S |

**第 7 步是整个过程里最关键的一条**——它证明"中枢宕机 = 冻结，不是错误"。

### 8.3 延迟怎么量

现有 `PING`/`PONG` 已经在测 RTT。Phase 1 再加一个对照：

* A 的 RTT（直连）= `rtt_direct`
* B 的 RTT（经中枢）= `rtt_hub`
* **中枢引入的增量 ≈ `rtt_hub − rtt_direct`**

不需要新机制，读两边日志即可。

---

## 9. Phase 1 明确不做的事

| 不做 | 留给 |
|---|---|
| `REG` / 注册表 / 节点清单 | Phase 2 |
| 监控、前端、WS | Phase 2 |
| `CFG` / `ACK` / ini 下发 | Phase 3 |
| 主备 / 世代号 | Phase 4 |
| conflation（只留最新快照） | Phase 4，**需要解析 `T=`，会打破"中枢不理解载荷"** |
| CURVE | 可选，独立开关，不影响架构 |
| 鉴权（token） | 不做（D5：只靠防火墙白名单） |

---

## 10. 风险与回退

| 风险 | 对策 |
|---|---|
| 中枢转发引入延迟 | 只切两帧、不解析载荷；目标 < 5ms（A6） |
| 中枢成为单点 | A3/A4 就是专门验证它的；快照幂等 + 喂价停滞闸门 |
| `DrainFrames` 的多帧处理有 bug | Phase 0 的 MQL 探针先跑通；`zmq_topic_test.py` 已有 11 条断言 |
| 手工填 `id=<NID>` 填错 | sender 启动日志和面板都打印 NID；填错表现为"什么数据都收不到"，日志里加一条"订阅了但 N 秒没收到任何数据"的告警 |
| 中枢被未授权机器连上 | 防火墙白名单（D5）；**这是唯一的信任边界**，见计划书 §19.1 |

**回退方式**：清空 `HubEndpoint` 并重挂 EA → 立刻回到 Tier 1。
中枢侧无需任何操作（它是无状态的）。

---

## 11. ✅ 已确认（Phase 1 定稿）

| # | 决定 |
|---|---|
| 1 | **先写 Python 原型中枢**（§2 Step 1），验完 A1–A4 再移植 Rust |
| 2 | **`DrainFrames` 让两条通道共用解析**（单帧时 `topic=""`），Tier 1 也改走它 |
| 3 | **`Emit()` 编码两次**（直连 `SID=端口`、中央 `SID=NID`），不做字符串手术 |
| 4 | **sender 的 NID 显示在面板上**（不只日志）——配置 receiver 时要抄它 |
| 5 | **Phase 1 不开 CURVE** |

### Phase 1 之前要先做的两件 receiver 改动（已完成）

这两项与本阶段无关，但要在开工前落地（都已完成并编译）：

**a. `ShowOrphanedList`（默认 false）**
控制面板是否显示孤儿行。**默认关闭**——孤儿是配置故障而非日常状态，
同一发现已经在启动时以 ERROR 级别写进日志（`ReportOrphanedMirrors`）。
它**只控制显示**：计数照算、启动日志照打。

**b. `PermittedMagic`（默认空 = 全部放行）**
```
"54321,56789"     只接受这些
"!77889,998877"   除这些以外全接受
""                全部接受
```
* 匹配的是 **sender 上报的持仓 magic**（wire 上的 `MAGIC` 字段），
  **不是本账户的镜像 magic**——后者在 ini 里已经按 sender 固定了
* 用途：**同一个 sender 的两个 receiver 可以镜像不同子集**。
  sender 自己的 `IncludeMagicNumbers` 是**全局**的，这个是**每 receiver** 的
* 复用了 `CopierList`（与 `PermittedSymbols` 同一个类、同一套语法），
  连"多余 `!`"的诊断也一并继承
* **只闸开仓**，与其它 entry gate 一致：已存在的镜像继续被管理
* 自测新增 8 条断言，专门钉住"匹配是精确的、不是前缀"和"magic 0 是合法值"

---

*本文档为 Phase 1 设计草案，评审后定稿。*
