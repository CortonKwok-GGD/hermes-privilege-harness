"""宿主侧真实 daemon 端到端验证：同 uid 多 cap 并存（方案 B 部署后验证）

用法（Mac 终端，普通用户即可，socket 0660 需在 daemon 组）:
    python3 tests/test_cap_multi_process_live.py

验证点：
1. 同 uid 两次 stamp_init → 两个 cap 都有效（修复前：capA 被 capB 踢掉）
2. 伪造 cap → REJECTED: unknown capability（安全回归）
"""
import socket, struct, json, base64, hashlib, hmac, os, sys

SOCK = '/var/run/hermes-vip/request.sock'

def frame(obj):
    return struct.pack('!I', len(obj)) + obj

def recv_frame(s):
    raw = b''
    while len(raw) < 4:
        c = s.recv(4 - len(raw))
        if not c:
            break
        raw += c
    if len(raw) < 4:
        return None
    (mlen,) = struct.unpack('!I', raw)
    data = b''
    while len(data) < mlen:
        c = s.recv(mlen - len(data))
        if not c:
            break
        data += c
    return json.loads(data.decode())

def stamp_init():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall(frame(json.dumps({"type": "stamp_init"}).encode()))
    resp = recv_frame(s)
    s.close()
    return resp['cap']

def sudo_exec(cap_b64, cmd='echo OK'):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    cap = base64.b64decode(cap_b64)
    stamp = hmac.new(cap, cmd.encode(), hashlib.sha256).hexdigest()
    req = {"type": "sudo_execute", "command": cmd, "reason": "cap-multi-test",
           "origin": {"channel": "vip_sudo"}, "cap": cap_b64, "stamp": stamp}
    s.sendall(frame(json.dumps(req).encode()))
    resp = recv_frame(s)
    s.close()
    return resp

PASS = FAIL = 0
def check(name, ok, detail=''):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f'  OK {name}')
    else:
        FAIL += 1
        print(f'  FAIL {name}  -- {detail}')

# 1. 同 uid 两次 stamp_init → 两 cap 都有效
capA = stamp_init()
capB = stamp_init()
check('两次 stamp_init 返回不同 cap', capA != capB)
rA = sudo_exec(capA, 'echo A')
rB = sudo_exec(capB, 'echo B')
check('capA sudo_execute approved', rA.get('status') == 'approved', str(rA))
check('capB sudo_execute approved', rB.get('status') == 'approved', str(rB))

# 2. 伪造 cap 仍拒
rF = sudo_exec(base64.b64encode(os.urandom(32)).decode(), 'echo F')
check('伪造 cap → REJECTED: unknown capability',
      rF.get('error') == 'REJECTED: unknown capability', str(rF))

print(f'\n{"="*44}\n{PASS} passed, {FAIL} failed')
sys.exit(1 if FAIL else 0)
