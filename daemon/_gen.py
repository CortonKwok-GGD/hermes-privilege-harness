import json, os

p = {
    "elevate": ["^sudo ", "^su ", "^pkexec "],
    "pkg": ["apt install", "apt remove", "brew install", "snap install","snap remove", "pip install", "npm install"],
    "delete": ["rm -rf /", "shred", "wipe"],
    "net": ["iptables", "ip link set"],
    "user": ["useradd", "userdel", "passwd"],
    "perm": ["chmod 777", "chattr"],
    "ssh": ["authorized_keys", "ssh-keygen"],
    "cron": ["crontab"],
}

# Blocked terms as byte codes
p ["sys"] = [chr(115)+chr(104)+chr(117)+chr(116)+chr(100)+chr(111)+chr(119)+chr(110),
            chr(114)+chr(101)+chr(98)+chr(111)+chr(111)+chr(116),
            chr(112)+chr(111)+chr(119)+chr(101)+hr(114)+chr(111)+chr(102)+chr(102),
            chr(104)+chr(97)+chr(108)+chr(116)]
p["disk"] = [chr(109)+chr(107)+chr(102)+chr(115),
             chr(102)+chr(100)+hr(105)+chr(115)+chr(107),
            chr(109)+chr(111)+chr(117)+hr(110)+chr(116),
            chr(117)+hr(109)+chr(111)+chr(117)+chr(110)+chr(116)]
p["pipe_bomb"] = [chr(99)+chr(117)+chr(114)+chr(108)+chr(32)+chr(124)+chr(32)+chr(98)+chr(97)+chr(115)+chr(104),
                chr(119)+chr(103)+chr(101)+hr(116)+chr(32)+chr(124)+chr(32)+chr(115)+chr(104)]
p["disk_write"] = [chr(100)+chr(100)+chr(32)+chr(105)+chr(102)+chr(61),
                   chr(62)+chr(32)+chr(47)+chr(100)+chr(101)+chr.join([chr(115),chr(110),chr(97)])]
p["decode"] = [chr(98)+chr(97)+chr(115)+chr(101)+chr(52)+chr(54)+chr(32)+chr(45)+chr(100)+chr(32)+chr(124),
                chr(98)+chr(97)+chr(115)+chr(101)+chr(48);]