"""Passive VIP sandbox verification."""
import sys
sys.path.insert(0, '/home/admin/.hermes/hermes-agent')
sys.path.insert(0, '/home/admin/.hermes/plugins/hermes-vip')
import hashlib
import re

PASS = 0
FAIL = 0
def ok(name):
    global PASS; PASS += 1; print(f'  OK {name}')
def ng(name, e):
    global FAIL; FAIL += 1; print(f'  FAIL {name}: {e}')

# 1. Git push injection
try:
    from tools.approval import DANGEROUS_PATTERNS
    pat = (r'(?:^|[;&|&(])\s*git\s+push\b', 'git push (requires approval)')
    if pat not in DANGEROUS_PATTERNS:
        DANGEROUS_PATTERNS.append(pat)
        ok('git push injection')
    else:
        ok('git push pattern already present')
except Exception as e:
    ng('git push injection', e)

# 2. Approval display patch
try:
    from tools.approval import _run_approval_gate as orig
    import functools
    @functools.wraps(orig)
    def patched(*, display_target, description, **kw):
        if description and description.startswith('sudo:'):
            display_target = description
        return orig(display_target=display_target, description=description, **kw)
    import tools.approval
    tools.approval._run_approval_gate = patched
    ok('approval display patch')
except Exception as e:
    ng('approval display patch', e)

# 3. SHA-256 stamp
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'guard', '/home/admin/.hermes/plugins/hermes-vip/guard.py'
    )
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)

    guard._stamp('test-cmd')
    key = hashlib.sha256(b'test-cmd').hexdigest()
    assert key in guard._stamps, 'stamp not set'
    assert guard._verify('test-cmd'), 'verify failed'
    assert not guard._verify('unknown'), 'unknown verified'
    ok('SHA-256 stamp')
except Exception as e:
    ng('SHA-256 stamp', e)

print(f'\n{PASS}/{PASS+FAIL} passed ({FAIL} failed)')
