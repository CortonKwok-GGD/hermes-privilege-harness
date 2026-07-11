path = '/Users/mac/hermes-workspace/apps/hermes-vip/daemon/vipd.py'
with open(path) as f:
    lines = f.readlines()
new_lines = []
skip = False
for i, line in enumerate(lines):
    if '检查 root' in line:
        skip = True  # skip this and the 3 lines after
        continue
    if skip:
        if 'sys.exit' in line:
            skip = False
            continue
        continue
    new_lines.append(line)
with open(path, 'w') as f:
    f.writelines(new_lines)
print('fixed')
