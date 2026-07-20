"""Quick validation for passive-vip guard.py"""
import importlib.util, hashlib, sys
spec = importlib.util.spec_from_file_location(
    'guard', '/Users/mac/hermes-workspace/apps/hermes-vip/hermes-plugin/guard.py'
)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
P = 0
def ok(n): global P; P += 1; print(f'  OK {n}')

# SHA-256 stamp
g._stamp('test')
k = hashlib.sha256(b'test').hexdigest()
assert k in g._stamps; ok('stamp set')
assert g._verify('test'); ok('verify ok')
assert not g._verify('x'); ok('no stamp rejected')

# Blocklist
r = g._check_blocklist('visudo')
assert r[0]; ok(f'blocklist visudo: {r[1]}')
r = g._check_blocklist('echo hi')
assert not r[0]; ok('blocklist pass: echo')
r = g._check_blocklist('rm -rf /')
assert r[0]; ok('blocklist rm -rf')

# check() for vip_sudo
r = g.check('vip_sudo', {'command': 'whoami'})
assert r['action'] == 'approve'
assert 'sudo:' in r.get('message', ''); ok('check returns approve + sudo:')

print(f'\nAll {P} checks passed')
