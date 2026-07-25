#!/bin/bash
set -e
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
[ -z "$REAL_USER" ] && REAL_USER="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
[ -z "$REAL_USER" ] && { echo "error: no user" >&2; exit 1; }
REAL_HOME=$(eval echo ~$REAL_USER)
C="sudo -u $REAL_USER /usr/local/bin/container"
CFG="$REAL_HOME/.hermes/plugins/hermes-vip/config.yaml"
CNAME=$(python3 -c "import yaml,sys;c=yaml.safe_load(open('$CFG'));print(c['sandbox']['container']['name'])")
IMAGE=$(python3 -c "import yaml,sys;c=yaml.safe_load(open('$CFG'));print(c['sandbox']['container'].get('image','hermes-vm:latest'))")
MEM=$(python3 -c "import yaml,sys;c=yaml.safe_load(open('$CFG'));print(c['sandbox']['container'].get('memory_mb',2048))")
CPU=$(python3 -c "import yaml,sys;c=yaml.safe_load(open('$CFG'));print(c['sandbox']['container'].get('cpus',4))")
VOLS=$(python3 -c "import yaml,os;c=yaml.safe_load(open('$CFG'));
for m in c['sandbox']['mounts']:
 h=os.path.expandvars(os.path.expanduser(m['host_path']))
 g=os.path.expandvars(os.path.expanduser(m['container_path']))
 r=':ro' if not m.get('writable',True) else ''
 print(f'-v {h}:{g}{r}',end=' ')")
echo "Rebuilding $CNAME ($IMAGE) mem=${MEM}MB cpus=$CPU"
$C stop "$CNAME" 2>/dev/null || true
$C rm "$CNAME" 2>/dev/null || true
sleep 1
# create + start 替代 run -d，不验证 registry
$C create --arch amd64 --name "$CNAME" --memory "${MEM}MiB" --cpus "$CPU" $VOLS "$IMAGE" sleep infinity
$C start "$CNAME"
echo "Done: $CNAME rebuilt"
