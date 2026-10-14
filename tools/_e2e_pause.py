"""E2E for an arbitrary node: pause then resume, polling each to acked.
Usage: python _e2e_pause.py receiver%3A53203699"""
import json
import sys
import time
import urllib.request

HTTP = "http://127.0.0.1:6010"
NODE = sys.argv[1] if len(sys.argv) > 1 else "receiver%3A252034803"


def post(op):
    req = urllib.request.Request(
        f"{HTTP}/api/v1/nodes/{NODE}/commands",
        data=json.dumps({"op": op}).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    r = urllib.request.urlopen(req, timeout=5)
    return json.loads(r.read().decode())


def poll(cid, want, tries=8):
    j = {}
    for _ in range(tries):
        time.sleep(1.0)
        j = json.load(urllib.request.urlopen(f"{HTTP}/api/v1/commands/{cid}", timeout=5))
        if j.get("state") == want:
            return j
    return j


for op in ("pause", "resume"):
    r = post(op)
    cid = r["command_id"]
    print(f"{op}: 202 {cid} state={r['state']}")
    j = poll(cid, "acked")
    print(f"  -> state={j.get('state')} err={j.get('err')!r} attempts={j.get('attempts')}")
