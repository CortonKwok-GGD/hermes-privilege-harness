"""
Executor — 命令执行器
=====================

以 root 身份执行已批准的提权命令。

安全措施：
- 超时自动 kill
- stdout/stderr 大小限制
- 高危命令检测（管道+shell 模式）
"""

import logging
import os
import shlex
import signal
import subprocess
import time
from typing import Optional

logger = logging.getLogger("vipd.executor")

# 高危模式（同 Hermes approvals 的检测逻辑）
from .dangerous import check as _danger_check


class Executor:
    """命令执行器"""

    def __init__(self, timeout: int = 300, max_stdout: int = 50000,
                 detect_dangerous: bool = True):
        self._timeout = timeout
        self._max_stdout = max_stdout
        self._detect_dangerous = detect_dangerous

    def check_dangerous(self, command: str) -> Optional[str]:
        if not self._detect_dangerous:
            return None
        from .dangerous import check as dc
        hits = dc(command)
        if hits:
            return f"high_risk: {', '.join(hits)}"
        return None

    def execute(self, command: str, timeout: Optional[int] = None,
                env: Optional[dict] = None) -> dict:
        """
        执行命令。

        Args:
            command: shell 命令字符串
            timeout: 超时秒数（默认 self._timeout）
            env: 额外环境变量

        Returns:
            {stdout, stderr, exit_code, executed_at, duration_ms, danger_warning}
        """
        start = time.time()

        # 高危检测
        danger_warning = self.check_dangerous(command)

        result = {
            "stdout": "",
            "stderr": "",
            "exit_code": -1,
            "executed_at": start,
            "duration_ms": 0,
            "danger_warning": danger_warning,
        }

        actual_timeout = timeout or self._timeout

        try:
            proc = subprocess.Popen(
                ["/bin/sh", "-c", command],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={**os.environ, **(env or {})},
                preexec_fn=lambda: os.setsid(),  # 独立进程组，方便 kill 子树
            )

            try:
                stdout_bytes, stderr_bytes = proc.communicate(
                    timeout=actual_timeout
                )
            except subprocess.TimeoutExpired:
                # 超时：kill 整个进程组
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                    proc.wait(timeout=5)
                except (subprocess.TimeoutExpired, ProcessLookupError):
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                        proc.wait(timeout=2)
                    except (ProcessLookupError, subprocess.TimeoutExpired):
                        pass
                result["stderr"] = f"命令执行超时（{actual_timeout}s）"
                result["exit_code"] = -1
                end = time.time()
                result["duration_ms"] = int((end - start) * 1000)
                return result

            # 截断输出
            stdout_str = stdout_bytes.decode("utf-8", errors="replace")
            stderr_str = stderr_bytes.decode("utf-8", errors="replace")

            if len(stdout_str) > self._max_stdout:
                stdout_str = stdout_str[:self._max_stdout] + "\n... (truncated)"
            if len(stderr_str) > self._max_stdout:
                stderr_str = stderr_str[:self._max_stdout] + "\n... (truncated)"

            result["stdout"] = stdout_str
            result["stderr"] = stderr_str
            result["exit_code"] = proc.returncode

        except FileNotFoundError:
            result["stderr"] = f"命令不存在：{command}"
            result["exit_code"] = 127
        except PermissionError:
            result["stderr"] = f"权限不足：{command}"
            result["exit_code"] = 126
        except Exception as exc:
            result["stderr"] = f"执行异常：{exc}"
            result["exit_code"] = -1

        end = time.time()
        result["duration_ms"] = int((end - start) * 1000)
        logger.info("exec  exit_code=%d duration=%dms command=%s",
                     result["exit_code"], result["duration_ms"],
                     command[:80])

        return result
