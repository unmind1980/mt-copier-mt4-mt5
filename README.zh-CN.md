# MT4 / MT5 高性能跟单系统与双活高可用风控管理平台

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-MT4%20%7C%20MT5%20%7C%20Windows%20%7C%20Linux%20(Wine)-green.svg)]()
[![Rust Backend](https://img.shields.io/badge/Rust-1.80%2B%20(Tokio%20%26%20ZeroMQ)-orange.svg)]()
[![Tests](https://img.shields.io/badge/Tests-161%2F161%20Rust%20PASS%20%7C%2022%20Python%20Suites-brightgreen.svg)]()
[![MQL Build](https://img.shields.io/badge/MQL%20Matrix-16%2F16%20Binaries%20ALL%20GREEN-success.svg)]()

**[ English ](README.md) | [ 简体中文 ](README.zh-CN.md)**

*基于 ZeroMQ 与 Rust 构建的机构级、超低延迟（<10ms）跨平台 MetaTrader 4 / MetaTrader 5 跟单与集中式风控平台。*

</div>

---

## 📌 项目概述

**mt-copier** 是一套专为外汇与差价合约高频量化、多账户跟随打造的生产级、自托管跟单系统。它彻底克服了商业跟单软件（如 FX Blue、传统 Socket 简陋脚本）常见的内存无界泄漏崩溃、无法跨平台混跟（MT4 ↔ MT5）、掉线错平漏单以及缺乏集中式可视化运维等痛点。

系统以 **“权威快照保证最终一致性，实时事件流保障超低延迟”** 为核心设计哲学，在保证毫秒级开平仓的同时，提供企业级双活高可用（HA）、全链路加密安全、现代化 Web 交易驾驶舱与多渠道即时告警网络。

---

## ⚡ 核心设计原则

| 维度 | 技术实现 | 业务价值 |
| :--- | :--- | :--- |
| **一致性保障** | 实时事件流 (`OPEN`/`CLOSE`/`MODIFY`) + 周期性**权威快照** (`SNAP`) | 事件流保障超低延迟；快照充当最终法官。哪怕遇到极端网络丢包，在下一次快照到达时即可秒级自愈对齐，永不漏平仓。 |
| **平台中立性** | MQL4（32 位）↔ MQL5（64 位）双向全矩阵无缝互跟 | 发送端与接收端均原生支持 MT4/MT5，跨语言混转无需中间繁琐格式转换，统一协议封包。 |
| **唯一身份溯源** | 订单注释写入确定性 8 位字母数字 `UID`（格式：`tc\|<uid>\|<ticket>`） | 接收端自主标记源头，不依赖发送端权限；即使券商截断注释或 MT4 部分平仓更换 ticket 依然精准溯源。 |
| **交易安全防御** | 距离重锚、移动保本止损跟随、断线保护门禁 | 网络中断或停盘喂价停滞时：**严格保护已有持仓，暂停接收新单**，杜绝脱水价格下随意盲开。 |
| **双活高可用** | Primary (6000/6010) / Standby (6001/6011) 双机热备 | 单调递增 Epoch 仲裁、两阶段 Journal 日志复制，彻底杜绝脑裂；支持 ADR-10 两阶段平滑自动回切。 |

---

## 🚀 核心功能亮点

### 1. 全矩阵超低延迟跟随
- **实测端到端延迟 < 10ms**：采用高性能 ZeroMQ 异步内存缓冲与优化序列化编解码。
- **跨平台任意混跟**：
  - MT4 ➔ MT4
  - MT5 ➔ MT5
  - MT4 ➔ MT5（32 位到 64 位桥接）
  - MT5 ➔ MT4（64 位到 32 位桥接）
- **多对多灵活路由**：单个接收端可同时绑定数十个不同的发送端，各个发送端独立维护序列号、手数倍率模式与魔术数（Magic Number），允许不同信号源在同一品种持有相反仓位。

### 2. 企业级双活高可用（HA）集群
- **主备实时强同步**：Primary Hub 实时将命令日志、配置修订、用户权限及客户端白名单强同步给 Standby Hub。
- **自动故障转移与平滑回切（ADR-04 / ADR-10）**：基于严格的 Epoch 决胜仲裁与心跳探针，主节点故障备机自动接管，主机恢复后完成两阶段握手平滑回切，无状态丢失与重复开仓风险。
- **原子日志持久化**：具备两阶段写入屏障与 `sync_data` 刷盘保证，所有管理命令 100% 具备掉电持久性。

### 3. 金融级传输安全与加密防御
- **ZeroMQ CURVE 非对称加密**：采用 256 位椭圆曲线算法（Curve25519），各个终端配备唯一 Z85 公私钥。未授权节点在 ZAP 握手阶段即被阻断。
- **原生 TLS 1.3 / HTTPS / WSS**：内置 Axum 高性能 Web 服务，支持自定义 SSL 证书或自动申请 ACME（Let's Encrypt）免费证书，HTTP-01 验证支持按需隐形绑定 80 端口。
- **全方位 SSRF 与 DNS 重新绑定防御**：所有外发告警 Webhook 均采用 IP 钉死解析、禁止私有网段与重定向，彻底根除内网穿透隐患。

### 4. 现代化集中式 Web 控制台与驾驶舱
- **交互式多节点看板**：全网节点拓扑图、实时持仓明细监控与命令分发中心。
- **双栏智能分流驾驶舱**：左侧 Sender 卡片与右侧持仓明细联动，实时展示持仓浮动盈亏（**Profit**）与隔夜利息（**Swap**）。
- **多语言（i18n）即时切换**：无需刷新页面，自由切换 **简体中文、繁體中文、English、日本語、Русский、Español**。
- **自适应深浅色主题与字号缩放**：自带护眼 Night Mode 深色模式，移动端全响应式适配，支持全局 80%~140% 无级字体缩放。

### 5. 完备的量化风控保护机制
- **多层级熔断门禁**：支持账户级与信号源级最大持仓数、最大总手数、每日亏损保护（百分比/金额）、滑点与点差保护。
- **智能止损与保本跟随**：
  - 基于本地入场价按开仓相对距离精准重锚；
  - **移动保本止损与锁盈带符号位跟随**（发送端移至保本或锁盈时本地精准同步，绝不反向清空止损）；
  - 反向镜像映射（反向跟单时止盈与止损角色自动翻转）；
  - MT5 ECN 10016 自动降级处理（市价成交后立即夹紧改单）。
- **人工平仓意图保护环**：操作员在终端手动平仓后，记录 `g_manualClosed` 意图环并自动定向回收，彻底杜绝跟单系统误判重新开仓。

### 6. 多渠道即时告警网络
- **全天候推送**：风控触发、节点掉线、时钟严重偏移、网络自愈等事件秒级推送。
- **支持渠道**：
  - **微信（WeChat / Xtuis 虾推啥）**
  - **Telegram 机器人**
  - **企业微信机器人（WeCom）**
  - **钉钉机器人（DingTalk）**
  - **通用自定义 Webhook**
- **多渠道独立语言**：各个推送目的地可独立分配不同的推送语言偏好。

### 7. 生产级 Windows 系统服务支持
- **后台静默守护**：提供一键安装脚本（`install_services.bat`、`start_services.bat`），将主备 Hub 注册为原生 Windows 服务，开机自启动，崩溃自动拉起。

---

## 🏗️ 架构拓扑

### 模式 1：P2P 直连模式（轻量化，无需中心服务）
适合单台 VPS 本地终端之间的点对点极简跟单。
```text
[ MT4 / MT5 发送端 EA ]  -- ZeroMQ XPUB (自动端口 5000+acc%1000) -->  [ MT4 / MT5 接收端 EA ]
```

### 模式 2：中央 Hub 模式（集中监控、统一配置与管理）
由高性能 Rust 进程统一集中路由，支持数十个发送端和接收端集中管理。
```text
[ 发送端终端集合 ]  -- TCP (XSUB) --> [ Central Hub :6000 ] -- TCP (XPUB) --> [ 接收端终端集合 ]
                                                │
                                        ┌───────┴───────┐
                                  [ Web 驾驶舱 ]  [ 多渠道告警 ]
                                      (:6010)     (微信/TG/钉钉等)
```

### 模式 3：双活高可用 HA 集群模式（金融级零停机方案）
两台独立物理机或 VPS 运行主备 Hub，实时同步，故障自动无缝转移。
```text
[ 终端节点集合 ] ── (同时双向连接主备两台 Hub)
         │
   ┌─────┴─────────────────────────┐
   ▼                               ▼
[ Primary 主机 ]   ◄── 实时同步 ──►   [ Standby 备机 ]
  ZMQ 端口 :6000                     ZMQ 端口 :6001
  Web 驾驶舱 :6010 (可读写)           Web 驾驶舱 :6011 (只读)
```

---

## 📂 代码库目录结构

```text
mt-copier/
├── src/
│   ├── Experts/                  # MetaTrader 终端 EA 源码
│   │   ├── CopierSender.mq4      # MT4/MT5 通用发送端 EA
│   │   └── CopierReceiver.mq4    # MT4/MT5 通用接收端 EA
│   ├── Include/Copier/           # MQL 核心通用库
│   │   ├── CopierDefs.mqh        # 标准化仓位模型、平台兼容宏与镜像止损算法
│   │   ├── CopierCodec.mqh       # 协议序列化与快照完整性校验门禁
│   │   ├── CopierModel.mqh       # MT4/MT5 底层交易执行器
│   │   ├── CopierRisk.mqh        # 多层级量化风控熔断器
│   │   ├── CopierTransport.mqh   # ZeroMQ 网络传输层与上行调度
│   │   └── ...                   # 本地状态持久化、手数计算、品种映射等
│   └── Scripts/                  # 自测套件 (CopierSelfTest) 与探针工具
├── hub/                          # Rust 中央服务端工程
│   ├── src/                      # 17 个核心 Rust 模块 (基于 Tokio 异步框架)
│   │   ├── main.rs               # ZMQ 转发代理、心跳路由与服务集成
│   │   ├── api.rs                # REST API、WebSocket 流与驾驶舱服务端
│   │   ├── cluster.rs            # HA 双活集群管理器与自动回切状态机
│   │   ├── commands.rs           # 可靠命令日志与阶梯退避重试
│   │   ├── notifications.rs      # 多渠道告警（微信/Telegram/钉钉/企业微信）
│   │   ├── tls.rs                # SSL/TLS 1.3 引擎与 ACME 自动证书申请
│   │   └── assets/dashboard.html # 现代化响应式 Web 控制台
│   └── target/release/           # 高度优化的生产版二进制程序 (copier-hub.exe)
├── locales/                      # 外挂多语言翻译词典 (中简、中繁、英、日、俄、西)
├── doc/                          # 技术规范与设计文档
│   ├── PROTOCOL.md               # 网络通信协议与数据封包规范白皮书
│   ├── HANDOFF.md                # 完整技术交接手册与历史架构决策记录 (ADR)
│   └── ...                       # 其他架构设计文档
└── tools/                        # 部署、运维与自动化测试工具集
    ├── deploy.sh / compile.sh    # 多终端自动部署与一键 MQL 矩阵编译脚本
    ├── tests.sh / tests.bat      # 22 个 Python 集成回归与契约测试套件
    ├── start_primary.bat         # 启动 Primary 主机 (ZMQ 6000 / Web 6010)
    ├── start_standby.bat         # 启动 Standby 备机 (ZMQ 6001 / Web 6011)
    └── install_services.bat      # Windows 后台服务一键安装脚本
```

---

## ⚡ 5 分钟快速上手指南

### 第一步：部署并编译 MT4 / MT5 终端
使用自动化部署工具，一键向本机所有终端分发依赖库并编译二进制：
```bash
# 在 Git Bash 或 Windows CMD 命令行中执行：
cd mt-copier
bash tools/deploy.sh
bash tools/compile.sh
```
*自动识别本机所有已安装及便携版终端，全自动编译 16 个二进制目标（0 错误，0 警告）。*

### 第二步：启动中央服务端（Central Hub）

**方式一 —— 交互式控制台模式**：
在根目录双击运行 `start_primary_hub.bat`，或在命令行运行：
```bash
./hub/target/release/copier-hub.exe --port 6000 --http 0.0.0.0:6010 --role primary
```

**方式二 —— 原生 Windows 服务守护模式**：
右键以管理员身份运行 `install_services.bat`，即可一键将主备 Hub 安装为 Windows 自动启动服务，后台静默守护。

### 第三步：在终端中挂载 EA
1. 打开 MetaTrader 终端，在菜单 `工具 -> 选项 -> 智能交易系统` 中勾选 **允许导入动态链接库 (DLL)** 和 **允许实时自动交易**；
2. **在发送端（Sender）终端**：将 `CopierSender` 拖放到任意单个图表（如 EURUSD H1）；
   - 设置参数 `CentralHubEndpoint` = `tcp://127.0.0.1:6000`；
3. **在接收端（Receiver）终端**：将 `CopierReceiver` 拖放到任意单个图表；
   - 设置参数 `CentralHubEndpoint` = `tcp://127.0.0.1:6000`；
   - 在 `copier.ini` 中填入对应发送端账号，或直接在 Web 驾驶舱中在线可视化配置。

### 第四步：进入中央 Web 交易驾驶舱
在浏览器中打开：
```text
http://127.0.0.1:6010
```
- 默认登录账户：`admin`
- 首次启动时，终端控制台会自动输出随机生成的管理员密码（或通过环境变量 `MTC_ADMIN_PASSWORD` 预先设定）；
- 登录后即可自由切换语言与主题，实时监控各终端网络心跳，按需配置手数倍率，实时查看浮动盈亏与隔夜利息，或执行全局单笔平仓与紧急风控全平。

---

## 🛡️ 质量保证与自动化测试矩阵

系统每一次代码发布均经过严格的多层级自动化回归验证：

| 测试维度 | 覆盖范围 | 通过标准 |
| :--- | :--- | :--- |
| **MQL 终端编译矩阵** | 4 个独立终端（MT4 / MT5，32位与64位），16 个目标二进制 | **16 / 16 全部通过（0 errors, 0 warnings）** |
| **Rust Hub 单元测试** | 通信协议编解码、HA 集群仲裁选举、日志持久化恢复、SSRF、TLS 等 | **161 / 161 项测试全部通过（0 失败）** |
| **Python 协议契约套件** | 22 个大型端到端测试套件（含长跑混沌故障注入、主备快速接管） | **445+ 断言全部通过 (ALL GREEN)** |
| **静态检查与多语言** | `dash_check.py`（252 个 DOM ID 与 138 个函数）、`i18n_check.py` | **100% ID 匹配，6 种语言各 435 键全量校验** |

在本地执行全量测试与静态检查命令：
```bash
bash tools/tests.sh
bash hub/build.sh --test
python tools/dash_check.py
python tools/i18n_check.py
```

---

## 📖 技术文档与参考索引

- [doc/PROTOCOL.md](doc/PROTOCOL.md) — 网络通信协议、封包格式与信封设计规范白皮书。
- [doc/HANDOFF.md](doc/HANDOFF.md) — 核心系统架构演进历史、运维操作手册与架构决策记录（ADR）。
- [locales/README.md](locales/README.md) — 多语言扩展指南与本地化翻译字典编写规范。

---

## 📄 开源许可证

本项目基于 MIT 许可证开源 —— 详情请查阅 [LICENSE](LICENSE) 文件。
