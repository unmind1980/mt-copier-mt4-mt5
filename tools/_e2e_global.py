"""E2E for the G10 global endpoint: one pause, every receiver; then resume.
Each per-node command is polled to its terminal state."""
import json
import time
import urllib.request

HTTP = "http://127.0.0.1:6010"


def post_global(op):
    req = urllib.request.Request(
        f"{HTTP}/api/v1/commands",
        data=json.dumps({"op": op}).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    r = urllib.request.urlopen(req, timeout=5)
    return json.loads(r.read().decode())


def poll(cid, want, tries=10):
    j = {}
    for _ in range(tries):
        time.sleep(1.0)
        j = json.load(urllib.request.urlopen(f"{HTTP}/api/v1/commands/{cid}", timeout=5))
        if j.get("state") == want:
            return j
    return j


for op in ("pause", "resume"):
    r = post_global(op)
    print(f"global {op}: 202 count={r.get('count')} note={r.get('note')!r}")
    for item in r.get("issued", []):
        cid = item["command_id"]
        j = poll(cid, "acked")
        print(f"  {item['node']}: {cid} -> {j.get('state')} err={j.get('err')!r}")
