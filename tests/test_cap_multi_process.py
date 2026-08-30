"""daemon 侧 stamp cap 多进程并存修复验证（方案 B）

验证点：
1. 同 uid 两次 stamp_init → 两个 cap 都有效（旧实现：后注册删先注册 → 先 cap 失效）
2. 伪造 cap → REJECTED: unknown capability（安全回归）
3. cap 归属 uid 不符 → REJECTED: capability not bound to peer
4. 过期 cap 被 reaper 清理
5. CAP_MAX 上限：超出删最老
"""
import sys, os, time, base64, hashlib, hmac, importlib.util, io as _io
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from daemon.socket_server import SocketServer, CAP_TTL, CAP_MAX

PASS = 0
FAIL = 0
def check(name, ok, detail=''):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f'  OK {name}')
    else:
        FAIL += 1
        print(f'  FAIL {name}  -- {detail}')

class FakeClient:
    def __init__(self):
        self.sent = []
    def sendall(self, data):
        self.sent.append(data)
    def close(self):
        pass

class FakeQueue:
    def __init__(self):
        self.expired = 0
    def reap_expired(self):
        self.expired += 1

class FakeExecutor:
    def __init__(self):
        self.executed = []
    def execute(self, command):
        self.executed.append(command)
        return {"exit_code": 0, "duration_ms": 1, "stdout": "root\n", "stderr": ""}

# 构造 server（不 start，只测 handler）
server = SocketServer(FakeQueue(), FakeExecutor(), config={"sockets.request": "/tmp/test-req.sock", "sockets.control": "/tmp/test-ctl.sock"})

# ---- 1. 同 uid 两次 stamp_init，两个 cap 都有效 ----
c1, c2 = FakeClient(), FakeClient()
server._handle_stamp_init(c1, {"type": "stamp_init"}, peer_uid=501)
server._handle_stamp_init(c2, {"type": "stamp_init"}, peer_uid=501)
import json
cap1 = json.loads(c1.sent[0].split(b'\x00'*0)[0] if False else c1.sent[0][4:].decode())["cap"]
cap2 = json.loads(c2.sent[0][4:].decode())["cap"]
check('两次 stamp_init 返回不同 cap', cap1 != cap2)
check('两个 cap 都在表中', cap1 in server._capabilities and cap2 in server._capabilities,
      f'table size={len(server._capabilities)}')
check('cap1 仍归属 501（未被踢）', server._capabilities.get(cap1, (None,))[0] == 501)
check('cap2 归属 501', server._capabilities.get(cap2, (None,))[0] == 501)

# 两个 cap 都能通过 sudo_execute 的 HMAC 校验
for name, cap_b64 in (('cap1', cap1), ('cap2', cap2)):
    cmd = 'whoami'
    stamp = hmac.new(base64.b64decode(cap_b64), cmd.encode(), hashlib.sha256).hexdigest()
    fc = FakeClient()
    server._handle_sudo_execute(fc, {
        "type": "sudo_execute", "command": cmd, "reason": "t",
        "origin": {"channel": "vip_sudo"},
        "cap": cap_b64, "stamp": stamp,
    }, peer_uid=501)
    resp = json.loads(fc.sent[0][4:].decode())
    check(f'{name} sudo_execute approved', resp.get("status") == "approved", str(resp))
check('executor 收到 2 次执行', len(server._executor.executed) == 2,
      str(len(server._executor.executed)))

# ---- 2. 伪造 cap 仍拒 ----
fc = FakeClient()
server._handle_sudo_execute(fc, {
    "type": "sudo_execute", "command": "whoami", "reason": "t",
    "origin": {"channel": "vip_sudo"},
    "cap": base64.b64encode(os.urandom(32)).decode(),
    "stamp": "x" * 64,
}, peer_uid=501)
resp = json.loads(fc.sent[0][4:].decode())
check('伪造 cap → REJECTED: unknown capability',
      resp.get("error") == "REJECTED: unknown capability", str(resp))

# ---- 3. 归属不符（cap 属 501，请求 peer 502）----
fc = FakeClient()
cmd = 'whoami'
stamp = hmac.new(base64.b64decode(cap1), cmd.encode(), hashlib.sha256).hexdigest()
server._handle_sudo_execute(fc, {
    "type": "sudo_execute", "command": cmd, "reason": "t",
    "origin": {"channel": "vip_sudo"},
    "cap": cap1, "stamp": stamp,
}, peer_uid=502)
resp = json.loads(fc.sent[0][4:].decode())
check('cap 归属不符 → REJECTED: capability not bound to peer',
      resp.get("error") == "REJECTED: capability not bound to peer", str(resp))

# ---- 4. 过期 cap 被 reaper 清理 ----
old = dict(server._capabilities)
for k in server._capabilities:
    server._capabilities[k] = (server._capabilities[k][0], time.time() - CAP_TTL - 10)
server._reap_expired_caps()
check('过期 cap 全部清理', len(server._capabilities) == 0,
      f'remaining={len(server._capabilities)}')
server._capabilities.update(old)  # 还原

# ---- 5. CAP_MAX 上限：塞满后新注册删最老 ----
server._capabilities.clear()
t0 = time.time()
for i in range(CAP_MAX):
    k = base64.b64encode(os.urandom(32)).decode()
    server._capabilities[k] = (501, t0 + i)  # 时间递增
oldest = min(server._capabilities, key=lambda k: server._capabilities[k][1])
fc = FakeClient()
server._handle_stamp_init(fc, {"type": "stamp_init"}, peer_uid=501)
check('超出上限后删除最老 cap', len(server._capabilities) == CAP_MAX,
      f'size={len(server._capabilities)}')
check('最老 cap 被删', oldest not in server._capabilities)
newcap = json.loads(fc.sent[0][4:].decode())["cap"]
check('新 cap 存活', newcap in server._capabilities)

print(f'\n{"="*40}\n{name}: {PASS} passed, {FAIL} failed')
sys.exit(1 if FAIL else 0)
