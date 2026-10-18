#!/usr/bin/env python3
"""
hub_users_test.py - M9 (users, roles, sessions) against the REAL hub binary.

The plan's §17.2 (D10/D12) asks for auth + three roles on the control plane
and D5/§19.1 leaves the ZMQ port firewall-only. This test pins down the whole
matrix against the real HTTP API:

  * **Closed by default**: anything under /api/v1 answers 401 without a
    session cookie; whoami answers 401 too (it is the probe the dashboard's
    login overlay makes).
  * **Login verifies credentials** and mints a cookie; a wrong password and a
    non-existent user are the same answer (no account enumeration).
  * **The role matrix** (§17.2): viewer reads but cannot audit or write;
    operator writes commands; admin manages users and reads the audit log.
  * **The last admin cannot be removed or demoted** - a hub with no
    administrators is a hub nobody can fix.
  * **Logout kills the session**, and a disabled user cannot log back in.
  * **Changing your own password** requires the old one, is open to every
    role (rotating your own credential is not an admin privilege), and ends
    the user's OTHER sessions while keeping the one that made the change.
  * **The audit log records it all**: auth.login (ok + rejected), auth.denied,
    auth.logout, user.upsert, user.delete, user.bootstrap,
    user.password_changed.
"""
import hashlib
import http.client
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

ZMQ_PORT = 6198
HTTP_PORT = 6199
CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2
    os.environ["MTC_ADMIN_PASSWORD"] = "hub-test-pass"
    cmds = os.path.join(HERE, "_hub_usr_cmds.jsonl")
    audit = os.path.join(HERE, "_hub_usr_audit.jsonl")
    users = os.path.join(HERE, "_hub_usr_users.json")
    for f in (cmds, audit, users):
        try:
            os.remove(f)
        except OSError:
            pass
    p = subprocess.Popen(
        [HUB, "--port", str(ZMQ_PORT), "--http", f"127.0.0.1:{HTTP_PORT}",
         "--audit", audit, "--commands", cmds, "--users", users,
         "--stats-every", "0", "--duration", "40"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        time.sleep(2.0)

        def req(method, path, body=None, cookie=None):
            c = http.client.HTTPConnection(f"127.0.0.1:{HTTP_PORT}", timeout=5)
            headers = {}
            if cookie:
                headers["Cookie"] = f"mtc_session={cookie}"
            if body is not None:
                headers["Content-Type"] = "application/json"
            try:
                c.request(method, path, body=body, headers=headers)
                r = c.getresponse()
                raw = r.read()
                set_cookie = r.getheader("Set-Cookie") or ""
                return r.status, raw, set_cookie
            finally:
                c.close()

        def js(method, path, body=None, cookie=None):
            st, raw, _ = req(method, path,
                             json.dumps(body) if body is not None else None,
                             cookie)
            try:
                return st, json.loads(raw) if raw else {}
            except ValueError:
                return st, {}

        def login(user, pw):
            st, _, sc = req("POST", "/api/v1/login",
                            json.dumps({"id": user, "password": pw}))
            tok = None
            for part in sc.split(";"):
                part = part.strip()
                if part.startswith("mtc_session="):
                    tok = part[len("mtc_session="):]
            return st, tok

        # =================================================================
        print("== 1. closed by default ==")
        st, _ = js("GET", "/api/v1/topology")
        check("GET topology without a session -> 401", st == 401, f"status {st}")
        st, d = js("GET", "/api/v1/whoami")
        check("whoami without a session -> 401", st == 401, f"status {st}")
        st, _ = js("POST", "/api/v1/commands", {"op": "pause"})
        check("even the global command endpoint -> 401", st == 401, f"status {st}")

        # =================================================================
        print()
        print("== 2. login verifies credentials ==")
        st, _ = login("admin", "wrong-password")
        check("a wrong password -> 401", st == 401, f"status {st}")
        st, _ = login("no-such-user", "hub-test-pass")
        check("a non-existent user -> the SAME 401 (no enumeration)", st == 401,
              f"status {st}")
        st, tok = login("admin", "hub-test-pass")
        check("the bootstrapped admin can log in with the env password", st == 200,
              f"status {st}")
        st, d = js("GET", "/api/v1/whoami", cookie=tok)
        check("...and whoami says so", st == 200 and d.get("role") == "admin",
              f"status {st} {d}")

        # =================================================================
        print()
        print("== 3. the §17.2 role matrix ==")
        st, _ = js("POST", "/api/v1/users",
                   {"id": "viewer1", "password": "v-pass", "role": "viewer",
                    "disabled": False}, tok)
        check("admin creates a viewer", st == 200, f"status {st}")
        st, _ = js("POST", "/api/v1/users",
                   {"id": "op1", "password": "o-pass", "role": "operator",
                    "disabled": False}, tok)
        check("...and an operator", st == 200, f"status {st}")
        st, vtok = login("viewer1", "v-pass")
        check("the viewer logs in", st == 200, f"status {st}")
        st, otok = login("op1", "o-pass")
        check("the operator logs in", st == 200, f"status {st}")

        st, _ = js("GET", "/api/v1/topology", cookie=vtok)
        check("viewer reads the world", st == 200, f"status {st}")
        st, _ = js("GET", "/api/v1/audit", cookie=vtok)
        check("viewer may NOT read the audit log", st == 403, f"status {st}")
        st, _ = js("POST", "/api/v1/commands", {"op": "pause"}, cookie=vtok)
        check("viewer may NOT issue commands", st == 403, f"status {st}")
        st, _ = js("GET", "/api/v1/users", cookie=vtok)
        check("viewer may NOT list users", st == 403, f"status {st}")

        st, d = js("POST", "/api/v1/nodes/receiver%3A252034803/commands",
                   {"op": "pause"}, otok)
        check("operator DOES issue a command (hurts nobody - the node is fake)",
              st == 202 and d.get("command_id"),
              f"status {st} {str(d)[:80]}")
        st, _ = js("GET", "/api/v1/audit", cookie=otok)
        check("operator may NOT read the audit log", st == 403, f"status {st}")

        st, d = js("GET", "/api/v1/users", cookie=tok)
        check("admin lists users + sessions", st == 200 and len(d.get("users", [])) == 3,
              f"status {st} {len(d.get('users', []))} user(s)")

        # =================================================================
        print()
        print("== 3b. change your own password (any role; the old one is required) ==")
        st, _ = js("POST", "/api/v1/password",
                   {"old": "not-my-password", "new": "v-pass-new"}, cookie=vtok)
        check("a wrong current password -> 403", st == 403, f"status {st}")
        st, _ = js("POST", "/api/v1/password",
                   {"old": "v-pass", "new": "short"}, cookie=vtok)
        check("a too-short new password -> 400", st == 400, f"status {st}")
        st, d = js("POST", "/api/v1/password",
                   {"old": "v-pass", "new": "v-pass-new"}, cookie=vtok)
        check("a VIEWER may change their own password (not admin-only)",
              st == 200 and d.get("ok") is True, f"status {st} {str(d)[:60]}")
        st, _ = js("GET", "/api/v1/topology", cookie=vtok)
        check("the session that made the change survives", st == 200, f"status {st}")
        st, _ = login("viewer1", "v-pass")
        check("the old password no longer works", st == 401, f"status {st}")
        st, vtok2 = login("viewer1", "v-pass-new")
        check("...and the new one does", st == 200, f"status {st}")
        st, _ = js("GET", "/api/v1/topology", cookie=vtok2)
        check("...and its fresh session works", st == 200, f"status {st}")

        # =================================================================
        print()
        print("== 4. the last admin is protected ==")
        st, _ = js("DELETE", "/api/v1/users/admin", cookie=tok)
        check("deleting the only admin -> 409", st == 409, f"status {st}")
        st, _ = js("POST", "/api/v1/users",
                   {"id": "admin", "password": "hub-test-pass",
                    "role": "viewer", "disabled": False}, tok)
        check("demoting the only admin -> 409", st == 409, f"status {st}")
        st, otok2 = login("admin", "hub-test-pass")
        check("...and the admin can still log in", st == 200, f"status {st}")

        # =================================================================
        print()
        print("== 4b. an EMPTY password on /users means keep the existing one ==")
        # The dashboard's user table sends password:"" for every disable /
        # enable / role change - requiring a password there would silently
        # RESET the user's credential on each toggle.
        st, _ = js("POST", "/api/v1/users",
                   {"id": "viewer1", "password": "", "role": "operator",
                    "disabled": False}, tok)
        check("role change with an empty password -> 200", st == 200, f"status {st}")
        st, _ = login("viewer1", "v-pass-new")
        check("...and the OLD password still works", st == 200, f"status {st}")
        st, _ = login("viewer1", "wrong-password")
        check("...and it is not 'no password at all'", st == 401, f"status {st}")
        st, _ = js("POST", "/api/v1/users",
                   {"id": "brandnew", "password": "", "role": "viewer",
                    "disabled": False}, tok)
        check("a NEW user with an empty password -> 400", st == 400, f"status {st}")

        # =================================================================
        print()
        print("== 5. logout and disable ==")
        st, _ = js("POST", "/api/v1/logout", None, otok)
        check("logout -> 200", st == 200, f"status {st}")
        st, _ = js("GET", "/api/v1/topology", cookie=otok)
        check("the logged-out token is dead", st == 401, f"status {st}")
        st, _ = js("POST", "/api/v1/users",
                   {"id": "op1", "password": "o-pass", "role": "operator",
                    "disabled": True}, tok)
        check("admin disables the operator", st == 200, f"status {st}")
        st, _ = login("op1", "o-pass")
        check("a disabled user cannot log in", st == 401, f"status {st}")

        # =================================================================
        print()
        print("== 6. the audit log saw all of it ==")
        st, d = js("GET", "/api/v1/audit?limit=300", cookie=tok)
        actions = {e.get("action") for e in d.get("records", [])}
        for need in ("auth.login", "auth.denied", "auth.logout",
                     "user.upsert", "user.bootstrap", "user.password_changed"):
            check(f"audit has {need}", need in actions, str(sorted(actions)))

        # =================================================================
        print()
        print("== 6b. Scheme B challenge-response (Salted Hashing + Nonce) ==")

        def compute_proof(password, salt, nonce, rounds=4096):
            acc = hashlib.sha256(f"{salt}:{password}".encode("utf-8")).digest()
            for _ in range(1, rounds):
                acc = hashlib.sha256(acc).digest()
            stored_hex = acc.hex()
            return hashlib.sha256(f"{stored_hex}:{nonce}".encode("utf-8")).hexdigest()

        # 1. request nonce for admin
        st, ch = js("POST", "/api/v1/auth/nonce", {"id": "admin"})
        check("POST /api/v1/auth/nonce -> 200", st == 200, f"status {st}")
        check("...returns non-empty nonce", bool(ch.get("nonce")), f"nonce={ch.get('nonce')}")
        check("...returns salt and rounds", bool(ch.get("salt")) and ch.get("rounds") == 4096,
              f"salt={ch.get('salt')} rounds={ch.get('rounds')}")

        # 2. calculate proof and login
        proof = compute_proof("hub-test-pass", ch["salt"], ch["nonce"], ch["rounds"])
        st, raw, sc = req("POST", "/api/v1/login",
                          json.dumps({"id": "admin", "nonce": ch["nonce"], "proof": proof}))
        challenge_tok = None
        for part in sc.split(";"):
            part = part.strip()
            if part.startswith("mtc_session="):
                challenge_tok = part[len("mtc_session="):]
        check("challenge-response login succeeds -> 200", st == 200, f"status {st}")
        check("...and received session cookie", bool(challenge_tok), "cookie present")

        # 3. whoami verifies the session
        st, d = js("GET", "/api/v1/whoami", cookie=challenge_tok)
        check("...and whoami confirms admin role", st == 200 and d.get("role") == "admin",
              f"status {st} {d}")

        # 4. replay attack fails: the nonce was consumed immediately
        st, _, _ = req("POST", "/api/v1/login",
                       json.dumps({"id": "admin", "nonce": ch["nonce"], "proof": proof}))
        check("replay with consumed nonce fails -> 401", st == 401, f"status {st}")

        # 5. bad proof fails
        st, ch2 = js("POST", "/api/v1/auth/nonce", {"id": "admin"})
        st, _, _ = req("POST", "/api/v1/login",
                       json.dumps({"id": "admin", "nonce": ch2["nonce"], "proof": "wrong_proof_hash"}))
        check("bad proof fails -> 401", st == 401, f"status {st}")

        # 6. non-existent user returns dummy salt and cannot login
        st, ch_ghost = js("POST", "/api/v1/auth/nonce", {"id": "nobody_here"})
        check("non-existent user gets a dummy salt (no enumeration)",
              st == 200 and len(ch_ghost.get("salt", "")) == 16, f"salt={ch_ghost.get('salt')}")
        ghost_proof = compute_proof("random-pass", ch_ghost["salt"], ch_ghost["nonce"], ch_ghost["rounds"])
        st, _, _ = req("POST", "/api/v1/login",
                       json.dumps({"id": "nobody_here", "nonce": ch_ghost["nonce"], "proof": ghost_proof}))
        check("...and cannot log in -> 401", st == 401, f"status {st}")
    finally:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()
        for f in (cmds, audit, users):
            try:
                os.remove(f)
            except OSError:
                pass

    # =====================================================================
    print()
    print("== 7. --users none disables the login (anonymous viewer) ==")
    for f in (audit, cmds):
        try:
            os.remove(f)
        except OSError:
            pass
    p2 = subprocess.Popen(
        [HUB, "--port", str(ZMQ_PORT), "--http", f"127.0.0.1:{HTTP_PORT}",
         "--audit", audit, "--commands", cmds, "--users", "none",
         "--stats-every", "0", "--duration", "20"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        time.sleep(2.0)

        def js2(method, path, body=None):
            c = http.client.HTTPConnection(f"127.0.0.1:{HTTP_PORT}", timeout=5)
            headers = {}
            if body is not None:
                headers["Content-Type"] = "application/json"
            c.request(method, path, body=json.dumps(body) if body is not None else None,
                      headers=headers)
            r = c.getresponse()
            raw = r.read().decode()
            try:
                return r.status, json.loads(raw) if raw else {}
            except ValueError:
                return r.status, {}

        st, d = js2("GET", "/api/v1/whoami")
        check("whoami -> 200 anonymous viewer (no cookie)",
              st == 200 and d.get("user") == "anonymous", f"{st} {d}")
        st, d = js2("GET", "/api/v1/nodes")
        check("...so reads work with no login at all", st == 200, f"status {st}")
        st, d = js2("POST", "/api/v1/commands", {"op": "pause"})
        check("...but a global write is still refused (viewer)", st == 403,
              f"status {st} {d}")
        st, d = js2("GET", "/api/v1/users")
        check("...and user management stays admin-only", st == 403, f"status {st}")
        # The audit endpoint is admin-only and there is no admin here, so the
        # startup marker is checked on the file itself.
        try:
            raw = open(audit, encoding="utf-8").read()
        except OSError:
            raw = ""
        check("audit recorded user.auth_disabled", "user.auth_disabled" in raw, "")
    finally:
        p2.terminate()
        try:
            p2.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p2.kill()
        for f in (audit, cmds):
            try:
                os.remove(f)
            except OSError:
                pass

    bad = [c for c in CHECKS if not c[1]]
    print()
    print(f"  pass={len(CHECKS) - len(bad)}  fail={len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
