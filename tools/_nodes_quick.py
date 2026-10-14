import json
import urllib.request

d = json.load(urllib.request.urlopen("http://127.0.0.1:6010/api/v1/nodes", timeout=5))
for n in d.get("nodes", []):
    print(n.get("key"), "|", n.get("name"), "|", n.get("liveness"),
          "| quiet", n.get("quiet_secs"), "s")
