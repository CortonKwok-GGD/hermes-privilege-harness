# Hermes VIP 通信协议

> 定义 VIP daemon 与 Hermes Plugin / 连接器之间的通信格式。
> 版本: v0.1

---

## 1. Socket 规划

| Socket | 路径 | 权限 | 谁连谁 | 用途 |
|--------|------|------|--------|------|
| 请求 socket | `/var/run/hermes-vip/request.sock` | `user:staff 755` | Hermes Plugin → VIP Daemon | 提交命令请求，等待结果 |
| 控制 socket | `/var/run/hermes-vip/control.sock` | `root:wheel 600` | 连接器 → VIP Daemon | 提交审批响应 |

---

## 2. 请求 socket 协议

### 2.1 请求格式（Plugin → Daemon）

```json
{
  "type": "sudo_request",
  "req_id": "a7f2c3d8",
  "command": "brew install node@18",
  "reason": "用户要求安装 Node.js 18",
  "origin": {
    "channel": "weixin",
    "session_key": "wx_abc123",
    "user_id": "user_telegram_12345"
  },
  "timestamp": 1700000000
}
```

### 2.2 响应格式（Daemon → Plugin）

```json
{
  "status": "approved" | "denied" | "timeout" | "error",
  "req_id": "a7f2c3d8",
  "result": {
    "stdout": "🍺 node@18 installed\n",
    "stderr": "",
    "exit_code": 0,
    "executed_at": 1700000100,
    "duration_ms": 12345
  },
  "error": null
}
```

### 2.3 请求 socket 行为

- **同步阻塞**：Plugin 连接后发送请求，线程阻塞在 socket 读上
- **Daemon 处理**：收到请求 → 入队列 → 发审批通知 → 等用户响应 → 执行命令 → 写回结果
- **超时**：超过审批 TTL（默认 5 分钟）→ 返回 `status: "timeout"`
- **连接关闭**：Daemon 写入响应后关闭连接

---

## 3. 控制 socket 协议

### 3.1 审批响应（Connector → Daemon）

```json
{
  "type": "approval_response",
  "req_id": "a7f2c3d8",
  "action": "approve" | "deny",
  "connector": "hermes_gateway" | "telegram" | "cli",
  "verified_by": "user_id:telegram_12345",
  "timestamp": 1700000100
}
```

### 3.2 通知推送（Daemon → Connector）

```json
{
  "type": "approval_request",
  "req_id": "a7f2c3d8",
  "command": "brew install node@18",
  "reason": "用户要求安装 Node.js 18",
  "origin_channel": "weixin",
  "expires_at": 1700000300
}
```

### 3.3 控制 socket 行为

- **双向**：Daemon 通过此 socket 向已连接的 connector 推送审批请求
- **Connector 连接后保持长连接**，Daemon 可主动推送
- **Connector 发送审批响应**，Daemon 验证后执行/拒绝

---

## 4. 数据流

```
┌─────────────────────────────────────────────────────┐
│  Hermes Plugin                    VIP Daemon          │
│                                                      │
│  ┌──────────┐  ① request.sock   ┌──────────────┐   │
│  │ intercept ├──────────────────▶│ approval_queue│   │
│  │ .py       │  请求+阻塞等待    │ (TTL 5min)   │   │
│  │           │                   │              │   │
│  │           │  ⑥ 结果返回       │ ② 入队       │   │
│  │           │◀──────────────────│              │   │
│  └──────────┘                   │              │   │
│                                 │ ③ 推  ┌─────┴─┐  │
│  ┌──────────────┐               │ 送通知│conn   │  │
│  │ gateway_     │               │  ────▶│ector  │  │
│  │ handler.py   │               │       │hub    │  │
│  │              │               │       │  │    │  │
│  │ /vip-approve │  ④ control    │       │  ▼    │  │
│  │   a7f2       ├───────────────▶│   ┌──────┐   │  │
│  │              │  批准响应      │   │executor│  │  │
│  └──────────────┘               │   └──────┘   │  │
│                                 │  ⑤ 执  ⑤ 结  │  │
│                                 │  行    果     │  │
└─────────────────────────────────────────────────────┘
```

## 5. 安全约束

| 规则 | 说明 |
|------|------|
| req_id 一次性 | 响应后立即作废，不可重放 |
| req_id 8 位随机 | `secrets.token_hex(4)`，碰撞概率可忽略 |
| TTL 5 分钟 | 超时自动拒绝，从提交时开始计时 |
| 控制 socket root:600 | 非 root 进程无法连接，无法伪造审批响应 |
| 请求 socket user:staff | Hermes 能提交请求但不能批准 |
| 审批必须匹配 req_id | 无法批准不存在的请求 |
| 审计日志不可变 | append-only 日志，记录每个操作 |
