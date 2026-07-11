# Security Model

## 核心安全假设

VIP 的安全建立在以下三层隔离之上：

### 第一层：进程隔离

| 进程 | 身份 | 能做什么 | 不能做什么 |
|------|------|----------|------------|
| Hermes Agent | 你的用户 | 提交 sudo 请求 | 批准请求、读密钥 |
| VIP Daemon | root | 执行 sudo、读密钥 | 无限制 |
| Connector | 你的用户/root | 发送审批通知 | 无权执行命令 |

### 第二层：通信隔离

| Socket | 权限 | 谁能用 | 用途 |
|--------|------|--------|------|
| `request.sock` | user:staff 755 | Hermes Plugin | 提交请求 |
| `control.sock` | root:wheel 600 | 仅 root/connector | 提交审批 |

### 第三层：认知隔离

LLM 不知道 VIP 的存在。所有 sudo 命令返回 `"sudo: a password is required"`，和用户没配密码时一模一样的错误。

## 威胁模型

| 攻击场景 | 被攻破的层 | VIP 是否还安全 |
|----------|-----------|---------------|
| LLM 被注入"批准所有请求" | 第三层 | ✅ control socket root:600，模型无法连接 |
| LLM 被注入读取密钥 | 第二层 | ✅ 密钥在 `/etc/hermes-vip/` root:600 |
| Hermes 进程被攻击者控制 | 第一、二层 | ✅ 只能提交请求，不能批准 |
| root 权限被攻击者获得 | 全部 | ❌ 不再安全（所有防御失效） |
| 连接器密钥泄漏 | 第二层 | ❌ 需要 revoke 后更换 |

## 审计

所有操作记录在 `/var/log/hermes-vip/audit.log`（append-only）：
- 每次请求提交
- 每次审批（批准/拒绝/超时）
- 每次命令执行（命令+结果+耗时）
- 每次 daemon 启停

## 漏洞报告

请通过 GitHub Security Advisory 提交。
