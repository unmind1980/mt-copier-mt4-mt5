# MT-Copier 项目交接与系统状态手册 (Project Handoff & Status Manual)

> 生成时间：2026-10-18 23:55 (UTC+8)  
> 状态：**生产就绪 (Production Ready) / 全部测试全绿 (All Suites Green)**  
> 适用对象：系统维护人员、量化交易员、后继开发人员

---

## 1. 架构总览与系统拓扑 (Architecture & Topology)

MT-Copier 是一套高性能、低延迟、生产级跨账户 MetaTrader 4 / MetaTrader 5 跟单系统，支持**直连网状（Direct Mesh）**与**中央中枢（Central Hub）**两种拓扑形态并存运行。

```text
 ┌────────────────────────────────────────────────────────┐
 │                      Web Dashboard                     │
 │          (HTTP: 6010 / Nonce Salted Hash Auth)         │
 └───────────────────────────┬────────────────────────────┘
                             │ REST / SSE
 ┌───────────────────────────┴────────────────────────────┐
 │                  Central Hub (Rust)                    │
 │         (XPUB/XSUB: 6000, CURVE Encrypted)             │
 └─────────────┬───────────────────────────┬──────────────┘
               │ ZMQ (Topics: @nid / nid)  │ ZMQ
 ┌─────────────┴─────────────┐ ┌───────────┴──────────────┐
 │   Sender EAs (MT4/MT5)    │ │  Receiver EAs (MT4/MT5)  │
 │  - CopierSender.mq4/mq5   │ │  - CopierReceiver.mq4/mq5│
 │  - Dual Broadcast         │ │  - Hierarchical Risk     │
 │  - Account-bound State    │ │  - Waiting Telemetry     │
 │  - AutoPort (5000..5999)  │ │  - Auto Magic Number     │
 └───────────────────────────┘ └──────────────────────────┘
```

### 1.1 关键通信端口与安全规范
- **ZMQ 消息中枢端口：`6000`**
  - 角色：XPUB / XSUB 代理中继。
  - 加密：默认开启 **CURVE 加密**（Z85 格式公钥 40 字符 ↔ 底层转换 32 字节原始二进制密钥）。
  - 主题规范：
    - `@<nid>` / `@all`：控制通道（节点向中枢发送，中枢消费，永不转发）。
    - `<nid>`（无 `@` 前缀）：数据快照通道，根据订阅前缀逐字节广播给已授权的 Receiver。
- **Web UI & REST API 端口：`6010`**
  - 服务框架：Axum (Rust)。
  - 启动参数：默认开启 `--writes on` 全局写闸。
  - 认证安全：登录鉴权采用 **Nonce 动态盐值哈希（Salted Hashing）**：
    `SHA-256(password + nonce)`，5 秒过期且单次使用即毁，杜绝网络嗅探与重放攻击。
  - 权限模型：RBAC 三级权限（SuperAdmin / Operator / Viewer）。
- **直连模式通讯端口（Direct Mode）**：
  - 默认启用 `AutoPort = true`（留空即生效）。
  - 端口公式：`5000 + (Account % 1000)`（范围 `5000..5999`）；若被占用则快速失败弹窗报警，拒绝自增漂移以防止节点间端口竞态。

### 1.2 当前运行环境终端拓扑
| 终端实例 | 类型 | 账号/角色 | 数据路径 | 备注 |
| :--- | :--- | :--- | :--- | :--- |
| **MT5 Portable** | MT5 x64 | `sender:53203697` | `E:\MetaTrader 5\MQL5` | 必须使用 `Mt5-Portable.bat` 启动 |
| **MT5 ProgramFiles** | MT5 x64 | `receiver:53203699` | `%APPDATA%\...\D0E8209F77C8CF37AD8BF550E51FF075\MQL5` | 官方标准安装目录 |
| **Alpari MT4-1** | MT4 x86 | `sender:252033316` | `%APPDATA%\...\287469DEA9630EA94D0715D755974F1B\MQL4` | 直连+中枢双广播 |
| **Alpari MT4-2** | MT4 x86 | `receiver:252034803`| `%APPDATA%\...\311584BE9969960C78E0200E53528ECB\MQL4` | 多信号源独立分层风控 |

---

## 2. 本次交接涵盖的核心功能与关键重构 (Key Changelog)

### 2.1 Receiver 等待开仓遥测全栈穿透 (Waiting Telemetry Pipeline)
- **业务背景**：Receiver 图表面板能展示 `Waiting 9 to open (0 queued, 0 delayed, 9 mkt closed)`，需将此状态穿透至 Web UI，让操作员无需远程登录 VPS 即可掌控全网阻塞订单。
- **底层改造（MQL）**：
  - 在 `CopierReceiver.mq4/mq5` 的 `PutStatusMessage` 中，周期性统计待开仓单量并打包 `CP_T_STAT` 状态帧：
    `WAIT`（总等待开仓数）、`WLOTS`（总待开手数）、`WQUEUED`（券商排队中）、`WDELAYED`（延迟防抖中）、`WMKT`（闭市休市阻塞）、`EQ`（实时净值）、`BL`（实时余额）。
- **中枢处理（Rust Hub）**：
  - `registry.rs` 与 `main.rs` 捕获并解析上述字段，存入 `NodeEntry.waiting` 结构体，并通过 `/api/v1/nodes` 序列化输出。
- **前端联动（Web Dashboard）**：
  - 节点列表新增徽章展示（如 `Waiting 9 (0q · 0d · 9m)`）；
  - 遇到风控拦截时自动追加高亮标（如 `🚫 [daily-loss]`）；
  - 持仓数下方小字直观副标显示财务信息（`Eq: $10,015.99 · Bal: $10,000.00`）。

### 2.2 现代化 Dashboard 重构与移动端自适应 (Mobile-First UI Redesign)
- **顶部 4 大核心 KPI 决策卡片（Executive KPI Summary Grid）**：
  1. **Active Terminals**：全网终端在线率统计，区分 Senders 与 Receivers；
  2. **Open Positions**：全网持仓总笔数与总手数实时汇总，可点击直达持仓弹窗；
  3. **Waiting to Open**：全网阻塞订单统计，实时细分排队、延迟与闭市数量，有阻塞时卡片呈高亮警示；
  4. **Hub Status**：展示 Hub 运行时间、加密模式（`🔒 CURVE Encrypted`）及全局写闸状态（`Writes ON`）。
- **持仓大表收敛为按需下钻弹窗（`#posmodal`）**：
  - 主界面默认隐藏宽幅持仓表，大幅减轻视觉负担；
  - 提供多入口一键调出持仓弹窗（KPI 卡片、表格持仓单元格、快捷按键 `Positions`、全局工具栏按钮）；
  - 支持快捷键 `Esc` 退出与背景遮罩点击关闭，并支持自动平滑滚动高亮选定节点。
- **移动端卡片化布局（`@media (max-width: 768px)`）**：
  - 利用 `data-label` 属性及 CSS `td::before { content: attr(data-label) }` 伪元素，在手机屏幕上自动将水平表格行折叠重构为垂直卡片流，彻底消除横向拉伸；
  - 操作按钮自适应为双列舒适触控网格（触控靶区最小高度 $\ge 36\text{px}$）。
- **统一危险操作二次确认体系（`confirmDialog`）**：
  - 对平仓、紧急暂停、回滚等高危操作提供明确弹窗预警，杜绝误触。

### 2.3 分层多信号源独立风控与动态 INI 同步 (Hierarchical Risk & Config)
- **多信号源独立风控**：`copier.ini` 中支持为每个 `[senderN]` 独立定义风控额度（手数、止损、品种过滤、延迟门控、交易时段）；未定义的字段自动向上 Fallback 继承 `[common]` 基准值。
- **MQL 双层拦截执行**：先经过 `g_senderRisk[si].AllowOpen` 限制该信号源配额，再由 `g_risk.AllowOpen` 守卫账户级总权益、总手数与日内熔断。
- **Current Setting 实时同步**：Receiver 在 `REG` 及 `CFGRPT` 中携带当前运行态 INI，Web Visual Editor 支持一键 `Load Current Setting` 实时加载真实参数对比编辑并下发。

### 2.4 Sender AutoPort 与 Receiver Auto Magic 优化
- **Sender AutoPort**：Direct 模式默认启用 `AutoPort = true`（输入框留空即可），绑定账号哈希端口；若被占用立即弹窗报警让用户切手动，禁止自动自增以防竞态。
- **持久化文件解耦**：Sender 状态文件统一改用 `copier_sender_<account>.st`（解耦端口变更导致重复重开仓的隐患），与 Receiver 状态文件 `copier_receiver_<magic>.st` 彻底隔离，同终端 Loopback 自我拷贝 100% 安全。
- **Receiver Auto Magic**：`InpMagic` 默认为空字符串 `""`（代表 Auto 模式），直连模式下自动采用 `(long)SenderPort` 作为 Magic Number；填入具体数字则采用显式 Magic。
- **参数分组美化**：EA 属性面板通过 `input group`（MT5）及清爽分隔行（MT4）按 8 大分类严格对齐 Web UI 结构（`Connectivity & Mode`, `Sizing & Symbol Mapping`, `Risk Limits`, `Execution & Stops`, `Filters & Direction`, `Anti-Stack & Delays`, `Schedule & Timeout`, `System & Display`）。

### 2.5 启动脚本与运维管线加固
- **多实例与端口冲突防范**：加固 `tools\hublog.bat` 与 `tools\hubrs.bat`，在拉起 `copier-hub.exe` 前先检索系统进程；若发现已有 Hub 运行主动弹窗报警，避免 6000/6010 端口静默冲突闪退。
- **部署脚本修复**：修复 `tools/deploy.sh` 清理脚本时的通配符匹配范围，避免 Windows 文件锁 `.compile.log` 引发的部署中断。

---

## 3. 核心文件与改动清单 (Manifest of Modified Components)

| 模块 | 文件路径 | 关键改动简要说明 |
| :--- | :--- | :--- |
| **Hub 前端** | `hub/src/assets/dashboard.html` | 现代化 UI 改版、4 大 KPI 卡片、持仓下钻弹窗 `#posmodal`、移动端卡片式自适应 CSS、二次确认弹窗、等待开仓徽章渲染 |
| **Hub 核心** | `hub/src/main.rs` | 默认启动 `--writes on`、解析与分发 `WAIT` 遥测数据、广播通知通道对接 |
| **Hub 注册表** | `hub/src/registry.rs` | `NodeEntry` 新增 `waiting`（`total/lots/queued/delayed/mkt`）、`equity`、`balance` 字段解析与存储 |
| **Hub 接口** | `hub/src/api.rs` | `/api/v1/nodes` 序列化输出等待开仓指标、Nonce 盐值哈希认证接口 |
| **Receiver EA** | `src/Experts/CopierReceiver.mq4` | `PutStatusMessage` 上报 `WAIT` 系列指标、`Auto Magic` 支持、参数 8 大分组结构化 |
| **Sender EA** | `src/Experts/CopierSender.mq4` | `AutoPort` 留空推导、持久化状态文件改绑账号、参数分组结构化 |
| **配置头文件** | `src/Include/Copier/CopierConfig.mqh` | `copier.ini` 多信号源分层继承解析、`[senderN]` 独立参数加载 |
| **风控头文件** | `src/Include/Copier/CopierRisk.mqh` | 信号源级与账户级双层风控守卫模型 |
| **运维脚本** | `tools/hublog.bat` / `hubrs.bat` | 启动前多实例进程查验，冲突友好报警 |
| **部署与编译** | `tools/deploy.sh` / `compile.sh` | 部署清理通配符精细化、支持 4 大目标跨架构全自动编译 |

---

## 4. 验证与质量保证记录 (Verification & QA Sign-off)

所有交付组件均经过全维度严格验证，保持 **100% 绿色通过 (Zero Regressions)**：

1. **前端静态与 DOM 语法校验**：
   ```bash
   python tools/dash_check.py
   # 结果：dashboard OK: 0 mismatched brackets; 145 ids referenced, all present; 76 functions, no duplicates
   ```
2. **Rust 单元测试套件**：
   ```bash
   bash hub/build.sh --test
   # 结果：test result: ok. 128 passed; 0 failed; 0 ignored; finished in 2.94s
   ```
3. **Python 端到端契约与黑盒测试套件**：
   ```bash
   ./tools/tests.sh
   # 结果：ALL PYTHON SUITES GREEN (pass=354, fail=0)
   # 涵盖: curve 加密、配置热更、用户权限与 Nonce 鉴权、审计日志滚动、通知告警等 13 个独立测试集
   ```
4. **MQL4 / MQL5 跨平台多终端编译**：
   ```bash
   ./tools/deploy.sh && ./tools/compile.sh
   # 结果：ALL GREEN - 0 errors across every target (MT5 x64 两个终端, MT4 x86 两个终端全部成功编译)
   ```

---

## 5. 日常运维与实盘操作指南 (Operations Manual)

### 5.1 启动与停止 Central Hub
- **日常启动（推荐，带日志输出）**：
  双击运行 `tools\hublog.bat`（或在控制台运行）。
  - 该脚本自带 `cd /d "%REPO%"`，确保工作目录位于项目根目录，以正确读取 `curve_hub.keys` 与 `users.json`。
  - 启动后通过浏览器访问：`http://127.0.0.1:6010`。
- **停止 Hub**：
  在运行窗口按下 `Ctrl + C`，或在 PowerShell 中执行：
  ```powershell
  Stop-Process -Name copier-hub -Force
  ```
- **管理员密码重置（若遗忘密码）**：
  运行 `tools\reset_password.bat`，即可一键重置 `users.json` 中的管理员密码，重启 Hub 后立即生效。

### 5.2 EA 代码修改后的部署与编译（铁律）
> ⚠️ **重要规则：必须先 deploy 后 compile！**
> 若只运行 `compile.sh`，MetaEditor 只会反复编译终端数据目录中的旧文件，导致代码更新不生效！

标准更新流程：
```bash
# 1. 同步源码到所有 MT4 / MT5 终端数据目录
./tools/deploy.sh

# 2. 触发终端 MetaEditor 进行跨架构就地编译
./tools/compile.sh
```

### 5.3 终端加载与生效要点
- **MetaTrader 不会自动热重载外部编译的 `.ex4` / `.ex5` 文件**：
  在更新编译后，必须在终端图表上**重新挂载 EA**，或**重启 MetaTrader 终端**。
- **验证版本凭证**：
  查看终端下方「EA 交易 (Experts)」日志输出，核对启动时打印的 `build=` 时间戳（例如 `build=2026.10.18 23:40`）。

### 5.4 日志与文本编码规则
- **查看终端日志**：
  MT5 日志及 PowerShell 输出通常为 **UTF-16LE 带 BOM**，MT4 日志为 **UTF-8**。使用 Python 脚本解析时推荐如下两步法，绝不能盲猜 utf-16：
  ```python
  b = open(log_path, "rb").read()
  if b[:2] in (b"\xff\xfe", b"\xfe\xff"):
      text = b.decode("utf-16", "replace")
  else:
      text = b.decode("utf-8", "replace")
  ```

---

## 6. 后续演进建议与待办事项 (Next Steps & Recommendations)

1. **生产环境守护进程化 (Daemon / Service)**：
   - 当前 Hub 由控制台或批处理脚本启动。生产环境可考虑使用 Windows 计划任务或 NSSM (Non-Sucking Service Manager) 将 `copier-hub.exe` 注册为系统自启动服务，并配置异常闪退自动重启。
2. **多中枢高可用（Master / Slave 接管）**：
   - 架构设计已在 `CENTRAL-HUB-PLAN.md` §11 中完成预留（双活发布 + 静默接管）。当管理节点扩展至跨机房多服务器时，可按计划书开启主备双写。
3. **通知渠道丰富度**：
   - 当前已打通 Telegram 与本地 WebHook 告警。后续可按需拓展企业微信、钉钉或邮件告警通道。

---
*交接文档编制完毕，系统运行平稳，所有代码及自动化测试均处于已验证状态。*
