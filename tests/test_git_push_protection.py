"""验证 git push 保护不影响现有 VIP sudo 功能。"""
import importlib.util
import sys
import json

# 加载 guard.py
spec = importlib.util.spec_from_file_location(
    'guard', '/Users/mac/hermes-workspace/apps/hermes-vip/hermes-plugin/guard.py'
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

PASS = 0
FAIL = 0

def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  ✓ {name}")
    else:
        FAIL += 1
        print(f"  ✗ {name}  -- {detail}")

def is_block(r):
    return isinstance(r, dict) and r.get("action") == "block"

def is_approve(r, expected_key=None):
    if not (isinstance(r, dict) and r.get("action") == "approve"):
        return False
    if expected_key and r.get("rule_key") != expected_key:
        return False
    return True

def is_none(r):
    return r is None

# ============================================================
print("=" * 60)
print("验证 1: 原始 VIP sudo 功能不受影响")
print("=" * 60)

# 1.1 terminal sudo 仍然被 block
r = guard.check("terminal", {"command": "sudo apt-get install htop"})
check("terminal(sudo) → block", is_block(r), str(r))

# 1.2 terminal(ssh remote sudo) 仍然放行
r = guard.check("terminal", {"command": "ssh admin@10.0.0.3 sudo systemctl restart nginx"})
check("terminal(ssh remote sudo) → None (放行)", is_none(r), str(r))

# 1.3 vip_sudo 仍然返回 approve + stamp
r = guard.check("vip_sudo", {"command": "apt-get remove htop"})
check("vip_sudo(sudo cmd) → approve + vip:sudo",
      is_approve(r, "vip:sudo"), str(r))

# 1.4 vip_sudo stamp 验证有效
# 先 stamp，再 verify
guard._stamp("test-command-123")
ok = guard._verify("test-command-123")
check("stamp/verify 机制正常", ok)

# 1.5 无 stamp 的 verify 返回 False
ok = guard._verify("unstamped-command")
check("无 stamp 的 verify → False", not ok)

# 1.6 vip_sudo handler 拒绝无 stamp 的命令
r = guard.vip_sudo("whoami", "test")
res = json.loads(r)
check("vip_sudo(无 stamp) → REJECTED",
      "REJECTED" in res.get("error", ""), str(res))

# 1.7 黑名单仍然生效
r = guard._check_blocklist("visudo")
check("blocklist(visudo) → blocked",
      r == (True, "编辑 sudoers 文件"), str(r))

r = guard._check_blocklist("echo 'ok'")
check("blocklist(普通命令) → not blocked",
      r == (False, ""), str(r))

# ============================================================
print()
print("=" * 60)
print("验证 2: 新增 git push 拦截功能")
print("=" * 60)

# 2.1 git push 被检测
r = guard._is_git_push_operation("git push origin main")
check("_is_git_push_operation('git push origin main')", r)

r = guard._is_git_push_operation("git push --force origin main")
check("_is_git_push_operation('git push --force')", r)

r = guard._is_git_push_operation("cd ~/repo && git push origin main")
check("_is_git_push_operation('cd ~/repo && git push')", r)

# 2.2 非 push 不被检测
r = guard._is_git_push_operation("git clone https://github.com/...")
check("_is_git_push_operation('git clone') → False", not r)

r = guard._is_git_push_operation("git fetch origin")
check("_is_git_push_operation('git fetch') → False", not r)

r = guard._is_git_push_operation("git pull upstream main")
check("_is_git_push_operation('git pull') → False", not r)

r = guard._is_git_push_operation("git status")
check("_is_git_push_operation('git status') → False", not r)

r = guard._is_git_push_operation("git checkout main")
check("_is_git_push_operation('git checkout') → False", not r)

r = guard._is_git_push_operation("git log --oneline")
check("_is_git_push_operation('git log') → False", not r)

# 2.3 terminal(git push) 返回 approve + vip:git
r = guard.check("terminal", {"command": "git push origin main"})
check("terminal(git push) → approve + vip:git",
      is_approve(r, "vip:git"), str(r))

r = guard.check("terminal", {"command": "git push --force origin main"})
check("terminal(git push --force) → approve + vip:git",
      is_approve(r, "vip:git"), str(r))

# 2.4 terminal(non-push git) 返回 None
r = guard.check("terminal", {"command": "git clone https://github.com/..."})
check("terminal(git clone) → None", is_none(r), str(r))

r = guard.check("terminal", {"command": "git fetch origin"})
check("terminal(git fetch) → None", is_none(r), str(r))

# ============================================================
print()
print("=" * 60)
print("验证 3: vip:git 与 vip:sudo 互不干扰")
print("=" * 60)

# 3.1 sudo 命令不会被 git push 检测误匹配
r = guard._is_git_push_operation("sudo apt-get update")
check("sudo apt-get → not git push", not r)

# 3.2 git push 不会被 sudo 检测误匹配
r = guard._has_privilege_escalation("git push origin main")
check("git push → not privilege escalation", not r)

# 3.3 混合命令：sudo git push → 优先走 sudo 拦截
r = guard.check("terminal", {"command": "sudo git push origin main"})
# sudo 检测优先，返回 block
check("sudo git push → block (sudo 优先)", is_block(r), str(r))

# 3.4 vip_sudo(git push) 走 daemon 路径（不特殊处理）
# 但这在实际中不会发生，因为终端拦截已经把 git push 转到 approve + 直接执行
r = guard.check("vip_sudo", {"command": "cd ~/repo && git push origin main"})
check("vip_sudo(git push) → approve + vip:sudo（正常 sudo 审批路径）",
      is_approve(r, "vip:sudo"), str(r))

# ============================================================
print()
print(f"\n{'='*60}")
print(f"结果: {PASS} 通过, {FAIL} 失败")
print(f"{'='*60}")
if FAIL > 0:
    sys.exit(1)
else:
    print("全部通过 ✅")
