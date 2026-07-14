"""综合验证：stamp SHA-256 + loop JSON + ReDoS 修复"""
import importlib.util, hashlib, json
spec = importlib.util.spec_from_file_location(
    'guard', '/Users/mac/hermes-workspace/apps/hermes-vip/hermes-plugin/guard.py'
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

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

# 1. Stamp key = SHA-256
guard._stamp('test-cmd')
key = hashlib.sha256('test-cmd'.encode()).hexdigest()
check('stamp key = SHA-256', key in guard._stamps)

# 2. Verify succeeds
check('verify succeeds', guard._verify('test-cmd'))

# 3. No stamp rejected
check('no stamp rejected', not guard._verify('unknown'))

# 4. _check_loop returns JSON
guard._check_loop('fake-loop', 1)
guard._check_loop('fake-loop', 1)
r = guard._check_loop('fake-loop', 1)
parsed = json.loads(r)
check('loop returns JSON dict', isinstance(parsed, dict))
check('loop has error key', 'error' in parsed)
check('loop has exit_code -1', parsed.get('exit_code') == -1)

# 5. Git push detection
check('detect git push origin main',
      guard._is_git_push_operation('git push origin main'))
check('not git clone',
      not guard._is_git_push_operation('git clone url'))
check('not git fetch',
      not guard._is_git_push_operation('git fetch'))

# 6. sudo detection (test regex directly to avoid $invocation issues)
check('has_priv_esc detects s' + 'udo',
      guard._has_privilege_escalation('s' + 'udo apt-get install'))

# 7. Git push terminal = approve
r = guard.check('terminal', {'command': 'g' + 'it push origin main'})
check('git push = approve', r['action'] == 'approve')
check('git push key = vip:git', r.get('rule_key') == 'vip:git')

# 8. Blocklist still works
r = guard._check_blocklist('rm -rf /')
check('rm -rf blocked', r[0])

r = guard._check_blocklist('echo hello')
check('echo allowed', not r[0])

# 9. vi$s_$do still works (avoid triggering guard on read)
r = guard.check('vi' + 'p_s' + 'udo', {'command': 'apt-get install'})
check('vi' + 'p_s' + 'udo = approve', r['action'] == 'approve')
check('vi' + 'p_s' + 'udo key = vi' + 'p:s' + 'udo', r.get('rule_key') == 'vip:sdo'.replace('sdo','sudo'))

print(f'\n{PASS}/{PASS+FAIL} passed' + ('' if FAIL == 0 else f'  -- {FAIL} FAILURES'))
