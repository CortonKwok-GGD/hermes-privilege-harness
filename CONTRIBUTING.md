# 贡献指南

## 连接器开发

连接器是 VIP 的审批通道。一个连接器只需要实现两个功能：

1. **接收审批推送** — VIP daemon 通知你有新的提权请求
2. **发送审批响应** — 用户批准/拒绝后，通知 VIP daemon

### 接口

```python
class Connector:
    """连接器基类"""

    @property
    def name(self) -> str:
        """连接器唯一名称，如 'telegram'"""
        ...

    async def send_approval_request(
        self, req_id: str, command: str, reason: str, expires_at: float
    ) -> None:
        """向用户发送审批卡"""
        ...

    async def start(self, control_socket_path: str) -> None:
        """连接到 VIP daemon 的控制 socket，开始监听审批推送"""
        ...
```

### 示例：Telegram 连接器

```python
class TelegramConnector(Connector):
    name = "telegram"

    async def send_approval_request(self, req_id, command, reason, expires_at):
        await self.bot.send_message(
            chat_id=self.admin_chat_id,
            text=f"🔐 提权请求 #{req_id}\n命令：{command}\n回复：/approve {req_id}"
        )

    async def start(self, control_socket_path):
        # 连接到 control socket
        # 监听审批推送
        # 用户回复后通过 control socket 发送审批响应
        ...
```

### 连接器安全要求

- bot token 必须存储在 root 可读的位置（`/etc/hermes-vip/`）
- 不能把 token 传给 Hermes 进程
- 连接器本身应该作为独立的进程/线程运行（如果作为独立进程启动，需要用 `sudo` 或 root 权限）

## 发布流程

1. Fork 仓库
2. 创建 feature 分支
3. 提交 PR
4. 通过后合并到 main
