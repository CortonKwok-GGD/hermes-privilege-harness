import re,json,os
_DIR=os.path.dirname(__file__)
with open(os.path.join(_DIR,"dangerous_patterns.json")) as f:
 _ALL=json.load(f)
_CATS=['elevate', 'pkg', 'sys', 'delete', 'pipe_bomb', 'decode', 'disk_write', 'net', 'user', 'disk', 'perm', 'ssh', 'cron']
def check(cmd,mode="green"):
 hits=[]
 for c in _get(mode):
  for p in _ALL.get(c,[]):
   if re.search(p,cmd,re.I):hits.append(c);break
 return hits
def _get(m):
 if m=="red":return _CATS[:1]
 if m=="yellow":return _CATS[:5]
 return _CATS
