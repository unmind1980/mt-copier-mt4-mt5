#!/usr/bin/env python3
"""
dash_check.py - static sanity check for the hub's embedded dashboard.

Catches, WITHOUT a browser or node:
  * unbalanced braces / parens / brackets in the <script> body
    (string-literal aware: a "//" inside a string is NOT a comment - the
    first version of this checker got that wrong and reported a false
    imbalance on the WebSocket URL line);
  * every $("id") the script references exists in the markup;
  * duplicate element ids and duplicate function definitions.

Both real dashboard breakages were of the "one duplicated / stray fragment"
kind, which is exactly what this catches: a single syntax error kills the
whole script, and the symptom is every footer link degrading to a bare '#'.
"""
import os, re, sys

def strip_js(s):
    out, i, n = [], 0, len(s)
    while i < n:
        ch = s[i]
        if ch in ("'", '"'):
            q = ch; out.append(q); i += 1
            while i < n:
                if s[i] == "\\":
                    out.append(s[i:i+2]); i += 2; continue
                if s[i] == q:
                    out.append(q); i += 1; break
                out.append(s[i]); i += 1
            continue
        if s.startswith("//", i):
            while i < n and s[i] != "\n": i += 1
            continue
        if s.startswith("/*", i):
            j = s.find("*/", i + 2); i = n if j < 0 else j + 2
            continue
        out.append(ch); i += 1
    return "".join(out)

def main(path):
    h = open(path, encoding="utf-8").read()
    m = re.search(r"<script>([\s\S]*?)</script>", h)
    if not m:
        print("FAIL: no <script> body found"); return 1
    t = strip_js(m.group(1))
    bad = []
    counts = {}
    for ch, name in (("{","brace"),("(","paren"),("[","bracket")):
        close = {"{":"}","(":")","[":"]"}[ch]
        d = t.count(ch) - t.count(close)
        counts[name] = d
        if d: bad.append(f"{name}s unbalanced by {d}")
    ids_ref = set(re.findall(r'\$\("([^"]+)"\)', m.group(1)))
    ids_def = set(re.findall(r'id="([^"]+)"', h))
    missing = sorted(i for i in ids_ref if i not in ids_def)
    if missing: bad.append(f"ids referenced but absent: {missing}")
    dup_ids = sorted(i for i in ids_def if h.count(f'id="{i}"') > 1)
    if dup_ids: bad.append(f"duplicate ids: {dup_ids}")
    fns = re.findall(r"function ([A-Za-z_$][\w$]*)\s*\(", m.group(1))
    dup_fns = sorted({f for f in fns if fns.count(f) > 1})
    if dup_fns: bad.append(f"duplicate functions: {dup_fns}")
    # Node.js syntax check if node is available
    import subprocess, shutil, tempfile
    node_exe = None
    candidates = [
        os.path.expanduser(r"~\.workbuddy-ai\binaries\node\versions\22.22.2-6\node.exe"),
        shutil.which("node")
    ]
    for c in candidates:
        if c and os.path.exists(c):
            node_exe = c
            break
    if node_exe:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as tf:
            tf.write(m.group(1))
            tname = tf.name
        try:
            res = subprocess.run([node_exe, "-c", tname], capture_output=True, text=True)
            if res.returncode != 0:
                bad.append("Node.js syntax check failed: " + res.stderr.strip())
        finally:
            try:
                os.remove(tname)
            except OSError:
                pass

    if bad:
        for b in bad: print("FAIL:", b)
        return 1
    print("dashboard OK:", counts, f"| {len(ids_ref)} ids referenced, all present;",
          f"{len(fns)} functions, no duplicates")
    return 0

if __name__ == "__main__":
    default = __file__.replace("tools" + os.sep + "dash_check.py", "")
    path = sys.argv[1] if len(sys.argv) > 1 else __import__("os").path.join(
        __file__.rsplit("tools", 1)[0], "hub", "src", "assets", "dashboard.html")
    sys.exit(main(path))
