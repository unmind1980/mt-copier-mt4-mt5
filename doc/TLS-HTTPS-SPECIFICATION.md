# MT-Copier Central Hub 原生 SSL/HTTPS 安全架构与实施规范

**版本**：v1.0 (Draft)  
**作者**：MT-Copier 核心团队  
**日期**：2026-10-31  
**状态**：架构方案敲定，待阶段化实施  

---

## 1. 业务目标与核心原则

### 1.1 业务目标
为 MT-Copier Central Hub 提供**纯原生内置、开箱即用、一站式**的 SSL/TLS (HTTPS & WSS) 能力：
1. **公网访问安全**：对运维仪表盘（Web UI）、REST API 及高频 WebSocket 数据流进行全程强加密（TLS 1.2 / TLS 1.3），杜绝公网明文传输被抓包、中间人劫持（MITM）或会话凭证泄露风险。
2. **无域名用户极简体验**：针对大量只有公网 IP、没有独立域名的 VPS 用户，通过 Wildcard IP 域名映射（`sslip.io`）实现**自动申请权威机构 CA 证书（绿色安全锁）**，彻底消除浏览器不安全告警。
3. **零外部跳转与全自动续期**：用户无需走出管理后台，无需注册第三方 DDNS，无需配置外部 Nginx/Caddy/Certbot，系统在后台自动管理证书的申请与平滑续期（剩余 30 天自动刷新）。

### 1.2 核心原则
- **零外部运行时依赖**：保持 `copier-hub` 单一独立静态可执行文件的纯粹性，不依赖外部 DLL 或辅助代理进程。
- **业务零中断热重载**：证书申请与续期完全在后台异步进行，新证书通过无锁原子指针热重载生效，绝对不重启 Hub，不影响跟单与实时数据流。
- **Fail-safe 防失联兜底**：HTTPS 自测成功前不掐断现有 HTTP 通道；提供 CLI 一键复位脚本，杜绝因防火墙配置错误导致管理员被锁在门外。

---

## 2. 核心架构与网络拓扑

```
                            公网访问 (Internet)
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
   HTTP 监听器 (端口 80)                               HTTPS 监听器 (443 或 6010 等)
           │                                                   │
  [ ACME 挑战捕获 & 301 重定向 ]                        [ Rustls 动态握手引擎 ]
           │                                                   │
  ├── 命中 /.well-known/acme-challenge/ -> 返回 Token   ├── Web UI Dashboard (静态内嵌)
  └── 其余 HTTP 访问 -> 301 永久重定向至 HTTPS 对应地址 ├── RESTful Management API
                                                       └── WebSocket 实时数据推流 (WSS)
```

### 2.1 端口与监听策略
系统提供两种灵活的端口模式，满足不同 VPS 部署环境：

1. **标准端口模式（Standard 443）**：
   - **HTTPS 端口**：`443`（浏览器直接输入域名访问，免输端口号，直观优雅）。
   - **HTTP 端口**：`80`（用于处理 Let's Encrypt 验证并实现全局 HTTP -> HTTPS 自动跳转）。
2. **自定义端口模式（Custom Port）**：
   - **HTTPS 端口**：用户指定（默认沿用原端口 `6010`，亦可填 `8443` 等其他非标端口）。
   - **HTTP 端口策略**：
     - 若 80 端口空闲，可开启“80 跳转”；
     - 若 80 端口已被其他 Web 服务占用，系统仅在证书申请/续期的这十几秒内临时借用（或配合已有代理转发 `/.well-known/acme-challenge/`），平时不占 80 端口。

---

## 3. 三大证书来源模式设计

### 3.1 模式 A：自动模式（Auto sslip.io）—— 专治无域名客户（推荐）
- **适用场景**：客户只有一台公网 VPS，没有申请或备案独立域名。
- **技术机制**：
  1. Hub 启动探针自动检测本机公网 IP（例如 `123.45.67.89`）；
  2. 合成符合 RFC 1035 标准的唯一 FQDN 域名：`123-45-67-89.sslip.io`；
  3. 全球 Anycast DNS 会将该域名解析回本机 IP；
  4. 系统向 Let's Encrypt 提交该域名申请，通过 HTTP-01 挑战颁发合法证书。
  5. 享有 Mozilla PSL（Public Suffix List）配额独立保障，不受全局限流影响。

### 3.2 模式 B：自定义域名模式（Custom Domain）—— 专治有域名客户
- **适用场景**：客户拥有自己的公司域名（如 `hub.myfund.com`）。
- **技术机制**：
  1. 客户在自有 DNS 处将域名 A 记录指向本机公网 IP；
  2. 在系统界面输入该域名并点击启用；
  3. Hub 后端自动向 Let's Encrypt 申请该域名的证书并自动绑定。

### 3.3 模式 C：自定义证书导入模式（Import Certificate）—— 专治离线与企业客户
- **适用场景**：机房无法联通外网 CA、云厂商 80 端口被严格阻断、或企业拥有商业泛域名证书。
- **技术机制**：
  1. 界面提供证书文本框（`fullchain.pem`）与私钥文本框（`privkey.pem`）；
  2. 保存后立即在本地校验密码学匹配度，验证通过后热载入 Rustls 引擎生效。

---

## 4. 数据模型与配置文件规范

TLS 配置独立持久化于根目录下的 `tls_config.json`，证书文件隔离存储于 `data/certs/` 目录。

### 4.1 配置文件规范 (`tls_config.json`)
```json
{
  "version": 1,
  "enabled": true,
  "mode": "auto",
  "domain": "123-45-67-89.sslip.io",
  "http_port": 80,
  "https_port": 443,
  "email": "admin@example.com",
  "enable_http_redirect": true,
  "auto_renew": true,
  "staging_mode": false,
  "status": {
    "cert_valid": true,
    "issuer": "Let's Encrypt Authority X3",
    "subject": "123-45-67-89.sslip.io",
    "issued_at": 1730380800,
    "expires_at": 1738156800,
    "days_remaining": 89,
    "last_error": null,
    "in_progress": false,
    "progress_step": "idle"
  }
}
```

### 4.2 证书目录规范 (`data/certs/`)
- `account.key`：ACME 账户私钥（Ed25519 或 ECDSA P-256，由 Hub 生成并长期复用）。
- `site.key`：站点私钥（ECDSA P-256 / RSA 2048）。
- `fullchain.pem`：站点证书链（包含终端证书与中间 CA 证书）。

---

## 5. REST API 契约设计

所有写操作受 M9 RBAC 控制（需 `operator` 或 `admin` 权限）。

### 5.1 查询 TLS 状态
- **Endpoint**: `GET /api/v1/tls/status`
- **Response**: 返回当前配置、证书有效期、到期倒计时天数及实时探测到的公网 IP。

### 5.2 提交配置与申请证书
- **Endpoint**: `POST /api/v1/tls/configure`
- **Body**:
  ```json
  {
    "enabled": true,
    "mode": "auto",
    "domain": "",
    "https_port": 443,
    "email": "admin@example.com",
    "enable_http_redirect": true
  }
  ```
- **Response**: `202 Accepted` + 后台异步任务启动；前端可通过 status 接口轮询进度。

### 5.3 导入外部证书
- **Endpoint**: `POST /api/v1/tls/import`
- **Body**:
  ```json
  {
    "cert_pem": "-----BEGIN CERTIFICATE-----\n...",
    "key_pem": "-----BEGIN PRIVATE KEY-----\n...",
    "https_port": 443
  }
  ```

### 5.4 手动触发即时续期
- **Endpoint**: `POST /api/v1/tls/renew`
- **Response**: 强制立即启动续期流程，不受 30 天门限限制。

### 5.5 HTTPS 连通性自测探针
- **Endpoint**: `POST /api/v1/tls/probe`
- **说明**: 用于切换前由浏览器向新地址发起探针请求，确认连通后才引导用户安全跳转。

---

## 6. 自动化续期与零停机热重载引擎

### 6.1 后台生命周期 Worker
1. Hub 启动一个长周期 Worker（每 12 小时自检一次）。
2. **到期评估**：检查当前证书的 `not_after` 时间戳。
   - 若 `days_remaining <= 30` 且 `auto_renew == true`，自动触发续期；
   - 采用指数退避重试（若网络暂时不通，则推迟至 2 小时后重试，避免轰炸 Let's Encrypt 导致被限流封禁）。

### 6.2 零停机热重载（Rustls ResolvesServerCertUsingSni）
1. 内存中维护一个原子指针：`ArcSwap<Option<Arc<CertifiedKey>>>`。
2. 每次有外部客户端进行 TLS 握手时，直接以原子无锁方式读取指针（耗时 < 10ns）。
3. 续期成功后，通过 `store` 原子写入新的证书对象：
   - 正在传输的连接完全不受影响；
   - 新到来的连接瞬间使用新证书；
   - 彻底告别传统 Nginx “reload” 造成的进程抖动。

---

## 7. 异常防御与防失联机制 (Fail-Safe)

1. **80 端口占用防崩溃预检**：在发起挑战前，系统尝试以非阻塞方式探测 80 端口绑定能力。若被占用，返回精准错误提示并中止任务，绝不 panic。
2. **HTTPS 切换过渡保护**：申请到新证书后，原 HTTP 端口暂时保留；前端自测通过后，才正式引导跳转并激活强制 301 重定向。
3. **命令行一键复位工具**：
   - 提供 `tools/reset_ssl.bat`（Windows）与 `tools/reset_ssl.sh`（Linux）；
   - 支持启动参数 `--ssl off`；
   - 即使客户把端口配置错乱或证书损坏，在控制台运行一次脚本即可瞬间切回纯 HTTP 模式恢复访问。

---

## 8. 分阶段实施路线图

| 阶段 | 核心任务 | 交付物 |
| :--- | :--- | :--- |
| **Stage 1: 基础选型与数据层** | 引入 `rustls`, `rcgen`, `instant-acme`；实现 `tls_config.json` 序列化与 `data/certs/` 读写；编写 `tools/reset_ssl.bat` 恢复工具 | 编译无外部 C 依赖，单元测试覆盖配置管理 |
| **Stage 2: ACME 协议与双监听引擎** | 实现 HTTP-01 验证拦截与 301 重定向；实现基于 `sslip.io` 的公网探针；接入 Let's Encrypt 生产与 Staging 环境 | 完成无域名与自有域名的全自动证书申请与落盘 |
| **Stage 3: 内存热重载与生命周期** | 实现 Rustls 动态证书解析器；实现每 12 小时自动续期 Worker | 续期成功后零停机生效，WSS 自动继承 |
| **Stage 4: REST API 与 WebUI 集成** | 在 `api.rs` 暴露状态、配置、导入端点；在 `dashboard.html` 嵌入一站式安全设置选项卡与平滑跳转交互 | 客户可通过 Web 界面全流程完成配置与查看 |
| **Stage 5: 全栈集成测试与回归** | 编写端到端自动化测试脚本；验证自签名、导入、sslip.io、多端口及断网回退场景 | 全平台 MQL 编译与 Python 测试套件全部绿灯 |
