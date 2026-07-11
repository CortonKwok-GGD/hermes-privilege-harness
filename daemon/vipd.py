#!/usr/bin/env python3
"""
VIP Daemon — Hermes root privilege escalation gateway
=====================================================

Usage:
    sudo python3 daemon/vipd.py              # foreground
    sudo python3 daemon/vipd.py --daemon     # fork to background
    sudo python3 daemon/vipd.py --config /etc/hermes-vip/config.yaml
"""

import argparse
import logging
import logging.handlers
import os
import signal
import sys
import time

from .approval_queue import ApprovalQueue
from .executor import Executor
from .socket_server import SocketServer
from .audit import audit

logger = logging.getLogger("vipd")


def setup_logging(log_level: str = "info", log_file: str = ""):
    """配置日志"""
    level_map = {
        "debug": logging.DEBUG,
        "info": logging.INFO,
        "warn": logging.WARNING,
        "error": logging.ERROR,
    }
    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    root_logger = logging.getLogger("vipd")
    root_logger.setLevel(level_map.get(log_level, logging.INFO))

    # 控制台
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    root_logger.addHandler(console)

    # 文件
    if log_file:
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            file_handler = logging.handlers.RotatingFileHandler(
                log_file, maxBytes=10 * 1024 * 1024, backupCount=5
            )
            file_handler.setFormatter(fmt)
            root_logger.addHandler(file_handler)
        except Exception as exc:
            logger.warning("无法创建日志文件 %s: %s", log_file, exc)


def load_config(config_path: str) -> dict:
    """加载 YAML 配置"""
    try:
        import yaml
        with open(config_path) as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        logger.warning("配置文件 %s 不存在，使用默认配置", config_path)
        return {}
    except ImportError:
        logger.warning("yaml 模块未安装，使用默认配置")
        return {}


def main():
    parser = argparse.ArgumentParser(description="Hermes VIP Daemon")
    parser.add_argument("--config", default="/etc/hermes-vip/config.yaml",
                        help="配置文件路径")
    parser.add_argument("--daemon", action="store_true",
                        help="后台运行")
    parser.add_argument("--log-level", default="info",
                        choices=["debug", "info", "warn", "error"],
                        help="日志级别")
    parser.add_argument("--log-file", default="/var/log/hermes-vip/vipd.log",
                        help="日志文件路径")
    args = parser.parse_args()

    # 检查 root
    if os.geteuid() != 0:
        print("错误：VIP Daemon 必须以 root 身份运行", file=sys.stderr)
        sys.exit(1)

    # 配置
    config = load_config(args.config)
    daemon_cfg = config.get("daemon", {})

    setup_logging(
        args.log_level or daemon_cfg.get("log_level", "info"),
        args.log_file or daemon_cfg.get("log_file",
                                        "/var/log/hermes-vip/vipd.log"),
    )

    logger.info("Hermes VIP Daemon starting...")
    logger.info("PID: %d", os.getpid())

    # 初始化组件
    ttl = config.get("approval", {}).get("ttl_seconds", 300)
    queue = ApprovalQueue(ttl=ttl)

    exec_cfg = config.get("executor", {})
    executor = Executor(
        timeout=exec_cfg.get("timeout", 300),
        max_stdout=exec_cfg.get("max_stdout_bytes", 50000),
        detect_dangerous=exec_cfg.get("detect_dangerous", True),
    )

    server = SocketServer(queue, executor, config)

    # 恢复未完成的请求
    queue.recover()

    # 注册内建连接器
    _register_builtin_connectors(server, config)

    # 信号处理
    running = True

    def _handle_signal(signum, frame):
        nonlocal running
        logger.info("收到信号 %d，正在关闭...", signum)
        running = False

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # 启动
    server.start()
    audit.start()

    # 主循环
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("收到 Ctrl+C")
    finally:
        logger.info("正在关闭...")
        queue.clear()
        server.stop()
        audit.stop()
        logger.info("VIP Daemon 已关闭")


def _register_builtin_connectors(server: SocketServer, config: dict):
    """注册内建连接器"""
    connectors_cfg = config.get("connectors", {})

    # hermes_gateway 连接器
    if connectors_cfg.get("hermes_gateway", {}).get("enabled", True):
        from ..connectors.hermes_gateway import send_approval
        server.register_connector("hermes_gateway", send_approval)
        logger.info("connector 'hermes_gateway' enabled")

    # CLI 连接器
    if connectors_cfg.get("cli", {}).get("enabled", True):
        from ..connectors.cli import send_approval
        server.register_connector("cli", send_approval)
        logger.info("connector 'cli' enabled")

    # OS Dialog 连接器
    if connectors_cfg.get("os_dialog", {}).get("enabled", False):
        from ..connectors.os_dialog import send_approval
        server.register_connector("os_dialog", send_approval)
        logger.info("connector 'os_dialog' enabled")


if __name__ == "__main__":
    main()
