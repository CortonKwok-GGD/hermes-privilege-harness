"""
Socket Server — Unix socket 服务
================================

两个 socket：
1. request.sock (user:staff 755) — Hermes Plugin 提交命令请求
2. control.sock (root:wheel 600) — 连接器提交审批响应

线程模型：
- 主线程：启动两个 socket server
- 请求 socket：每个客户端一个线程（ThreadPoolExecutor）
- 控制 socket：每个客户端一个线程
- 后台线程：reaper（定期收割过期请求）
"""

import json
import logging
import os
import socket
import stat
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from .approval_queue import ApprovalQueue
from .executor import Executor

logger = logging.getLogger("vipd.socket_server")

# Socket 路径
REQUEST_SOCK = "/var/run/hermes-vip/request.sock"
CONTROL_SOCK = "/var/run/hermes-vip/control.sock"

# JSON 帧传输：4字节长度前缀 + JSON 数据
LEN_PREFIX_BYTES = 4


def _recv_json(sock: socket.socket) -> dict:
    """从 socket 接收一个 JSON 帧"""
    raw_len = sock.recv(LEN_PREFIX_BYTES, socket.MSG_WAITALL)
    if not raw_len or len(raw_len) < LEN_PREFIX_BYTES:
        raise ConnectionError("连接断开")
    msg_len = struct.unpack("!I", raw_len)[0]
    if msg_len > 1024 * 1024:  # 1MB 上限
        raise ValueError(f"帧过大：{msg_len}")
    data = sock.recv(msg_len, socket.MSG_WAITALL)
    if not data or len(data) < msg_len:
        raise ConnectionError("连接断开")
    return json.loads(data.decode("utf-8"))


def _send_json(sock: socket.socket, data: dict):
    """向 socket 发送一个 JSON 帧"""
    payload = json.dumps(data).encode("utf-8")
    sock.sendall(struct.pack("!I", len(payload)) + payload)


def _ensure_socket_path(path: str, mode: int):
    """确保 socket 路径存在且权限正确"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _set_socket_permissions(path: str, uid: int, gid: int, file_mode: int):
    """设置 socket 文件权限"""
    try:
        os.chown(path, uid, gid)
        os.chmod(path, file_mode)
    except PermissionError:
        logger.warning("无法设置 socket 权限 %s (uid=%d gid=%d mode=%o)",
                       path, uid, gid, file_mode)


class SocketServer:
    """VIP daemon socket server"""

    # 请求 socket 的默认权限（用户可读写）
    REQUEST_MODE = 0o755  # user:staff rwx
    # 控制 socket 的默认权限（仅 root）
    CONTROL_MODE = 0o600  # root:wheel 仅读写

    def __init__(self, queue: ApprovalQueue, executor: Executor,
                 config: Optional[dict] = None):
        self._queue = queue
        self._executor = executor
        self._config = config or {}
        self._running = False
        self._threads: list[threading.Thread] = []

        # socket 路径配置
        self._request_path = self._config.get(
            "sockets.request", REQUEST_SOCK)
        self._control_path = self._config.get(
            "sockets.control", CONTROL_SOCK)

        # socket 权限
        self._request_mode = self._config.get(
            "sockets.request_mode", self.REQUEST_MODE)
        self._control_mode = self._config.get(
            "sockets.control_mode", self.CONTROL_MODE)

        # 线程池
        self._pool = ThreadPoolExecutor(max_workers=10)

        # 连接器注册（name → send_approval_request 回调）
        self._connectors: dict[str, callable] = {}

    def register_connector(self, name: str,
                           send_cb: callable):
        """注册一个连接器的审批推送回调"""
        self._connectors[name] = send_cb
        logger.info("connector registered: %s", name)

    # ── 启动/停止 ──

    def start(self):
        """启动所有 socket 服务"""
        self._running = True

        # 请求 socket
        _ensure_socket_path(self._request_path, self._request_mode)
        req_server = self._create_server(self._request_path)
        req_thread = threading.Thread(
            target=self._serve_requests,
            args=(req_server,),
            daemon=True,
            name="req-socket",
        )
        req_thread.start()
        self._threads.append(req_thread)
        # 权限设置在 bind 之后
        _set_socket_permissions(
            self._request_path,
            self._config.get("request_uid", os.getuid()),
            self._config.get("request_gid", os.getgid()),
            self._request_mode,
        )
        logger.info("request socket: %s (mode=%o)", self._request_path,
                    self._request_mode)

        # 控制 socket
        _ensure_socket_path(self._control_path, self._control_mode)
        ctl_server = self._create_server(self._control_path)
        ctl_thread = threading.Thread(
            target=self._serve_control,
            args=(ctl_server,),
            daemon=True,
            name="ctl-socket",
        )
        ctl_thread.start()
        self._threads.append(ctl_thread)
        _set_socket_permissions(
            self._control_path,
            0,  # root
            0,  # wheel
            self._control_mode,
        )
        logger.info("control socket: %s (mode=%o)", self._control_path,
                    self._control_mode)

        # Reaper 线程
        reaper = threading.Thread(target=self._reaper_loop, daemon=True,
                                  name="reaper")
        reaper.start()
        self._threads.append(reaper)

        logger.info("socket server started")

    def stop(self):
        """停止所有 socket 服务（线程将在下一次 I/O 时退出）"""
        self._running = False
        # 清理 socket 文件
        try:
            os.unlink(self._request_path)
        except FileNotFoundError:
            pass
        try:
            os.unlink(self._control_path)
        except FileNotFoundError:
            pass
        self._pool.shutdown(wait=False)
        logger.info("socket server stopped")

    def _create_server(self, path: str) -> socket.socket:
        """创建并绑定一个 Unix socket"""
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(path)
        server.listen(32)
        return server

    # ── 请求 socket 处理 ──

    def _serve_requests(self, server: socket.socket):
        """请求 socket 主循环"""
        server.settimeout(1.0)
        while self._running:
            try:
                client, _ = server.accept()
                self._pool.submit(self._handle_request_client, client)
            except socket.timeout:
                continue
            except OSError as exc:
                if self._running:
                    logger.error("request socket accept error: %s", exc)
                    time.sleep(1)

    def _handle_request_client(self, client: socket.socket):
        """处理一个请求 socket 客户端（Hermes Plugin 连接）"""
        try:
            req = _recv_json(client)
            req_type = req.get("type")

            if req_type == "sudo_request":
                self._handle_sudo_request(client, req)
            else:
                _send_json(client, {
                    "status": "error",
                    "error": f"未知请求类型: {req_type}",
                })
        except (ConnectionError, json.JSONDecodeError, ValueError) as exc:
            logger.warning("request client error: %s", exc)
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _handle_sudo_request(self, client: socket.socket, req: dict):
        """处理一条 sudo 请求：入队列→等待审批→执行→返回结果"""
        command = req.get("command", "")
        reason = req.get("reason", "提权请求")
        origin = req.get("origin", {})

        if not command:
            _send_json(client, {
                "status": "error",
                "error": "command 不能为空",
            })
            return

        # 1. 入队列
        entry = self._queue.submit(command, reason, origin)

        # 2. 通过连接器发送审批通知
        self._notify_approval(entry)

        # 3. 等待审批结果
        entry.event.wait()

        # 4. 如果超时被 reaper 收割，走 timeout 分支
        if not entry.resolved:
            _send_json(client, {
                "status": "timeout",
                "req_id": entry.req_id,
                "error": "审批超时",
            })
            return

        # 5. 审批结果
        decision = entry.result
        if decision["action"] != "approve":
            _send_json(client, {
                "status": "denied",
                "req_id": entry.req_id,
                "error": f"已拒绝（{decision.get('connector', 'unknown')}）",
            })
            return

        # 6. 执行命令
        exec_result = self._executor.execute(command)

        # 7. 返回结果
        _send_json(client, {
            "status": "approved",
            "req_id": entry.req_id,
            "result": exec_result,
        })

    # ── 控制 socket 处理 ──

    def _serve_control(self, server: socket.socket):
        """控制 socket 主循环"""
        server.settimeout(1.0)
        while self._running:
            try:
                client, _ = server.accept()
                self._pool.submit(self._handle_control_client, client)
            except socket.timeout:
                continue
            except OSError as exc:
                if self._running:
                    logger.error("control socket accept error: %s", exc)
                    time.sleep(1)

    def _handle_control_client(self, client: socket.socket):
        """处理一个控制 socket 客户端（连接器）"""
        try:
            req = _recv_json(client)
            req_type = req.get("type")

            if req_type == "approval_response":
                self._handle_approval_response(client, req)
            elif req_type == "register":
                self._handle_connector_register(client, req)
            elif req_type == "list_pending":
                self._handle_list_pending(client, req)
            else:
                _send_json(client, {
                    "status": "error",
                    "error": f"未知控制命令: {req_type}",
                })
        except (ConnectionError, json.JSONDecodeError, ValueError) as exc:
            logger.warning("control client error: %s", exc)
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _handle_approval_response(self, client: socket.socket, req: dict):
        """处理审批响应"""
        req_id = req.get("req_id", "")
        action = req.get("action", "deny")
        connector = req.get("connector", "unknown")
        verified_by = req.get("verified_by", "")

        if action not in ("approve", "deny"):
            _send_json(client, {
                "status": "error",
                "error": f"无效的 action: {action}（必须是 approve 或 deny）",
            })
            return

        ok = self._queue.resolve(req_id, action, connector, verified_by)
        _send_json(client, {
            "status": "ok" if ok else "not_found",
            "req_id": req_id,
        })

    def _handle_connector_register(self, client: socket.socket, req: dict):
        """处理连接器注册"""
        name = req.get("name", "unknown")
        logger.info("connector registered via control socket: %s", name)
        _send_json(client, {"status": "ok", "name": name})

    def _handle_list_pending(self, client: socket.socket, req: dict):
        """返回待审批列表"""
        pending = self._queue.list_pending()
        _send_json(client, {"status": "ok", "pending": pending})

    # ── 审批通知 ──

    def _notify_approval(self, entry) -> None:
        """通过所有已注册的连接器发送审批通知"""
        expiry = time.strftime(
            "%H:%M:%S", time.localtime(entry.expires_at))
        data = {
            "type": "approval_request",
            "req_id": entry.req_id,
            "command": entry.command,
            "reason": entry.reason,
            "origin_channel": entry.origin.get("channel", "unknown"),
            "expires_at": entry.expires_at,
            "expires_at_str": expiry,
        }
        for name, cb in self._connectors.items():
            try:
                cb(data)
            except Exception as exc:
                logger.error("connector %s notify error: %s", name, exc)

    # ── Reaper ──

    def _reaper_loop(self):
        """后台线程：定期收割过期请求"""
        while self._running:
            try:
                self._queue.reap_expired()
            except Exception as exc:
                logger.error("reaper error: %s", exc)
            time.sleep(10)
