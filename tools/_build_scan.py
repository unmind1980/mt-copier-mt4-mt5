"""Print the FULL last 'receiver up' line for the two live receiver instances."""
import os
import re

TARGETS = [
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\287469DEA9630EA94D0715D755974F1B\MQL4\Files\copier_receiver_252034803.0.log",
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Files\copier_receiver_53203699.0.log",
]


def read_text(path):
    raw = open(path, "rb").read()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16")
    head = raw[:4096]
    if head and head.count(0) > len(head) // 4:
        return raw.decode("utf-16-le", errors="replace")
    return raw.decode("utf-8", errors="replace")


for t in TARGETS:
    print("=" * 90)
    print(t.split("Terminal\\")[-1][:40], " mtime:",
          os.path.getmtime(t) and __import__("datetime").datetime.fromtimestamp(
              os.path.getmtime(t)).strftime("%m-%d %H:%M:%S"))
    text = read_text(t)
    ups = re.findall(r".*receiver up.*", text)
    for line in ups[-2:]:
        print("  ", line.strip())
    # also any CFG/CMD/pause traces after the last 'up'
    idx = text.rfind("receiver up")
    tail = text[idx:]
    hits = re.findall(r".*(?:CMD|CFG|PAUSE|pause|command).*", tail)
    print("   control traces after last up:", len(hits))
    for h in hits[-4:]:
        print("      ", h.strip()[:150])
