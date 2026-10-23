#!/usr/bin/env python3
"""
reset_password.py - Reset or create a user in users.json.
Useful when the initial random password was lost or needs to be reset.

Usage:
    python tools/reset_password.py
    python tools/reset_password.py --user admin --password mypassword123
"""
import argparse
import hashlib
import json
import os
import secrets
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
USERS_FILE = os.path.join(REPO, "users.json")

def hash_password(password, salt, rounds=4096):
    acc = hashlib.sha256(f"{salt}:{password}".encode("utf-8")).digest()
    for _ in range(1, rounds):
        acc = hashlib.sha256(acc).digest()
    return f"{salt}${rounds}${acc.hex()}"

def main():
    parser = argparse.ArgumentParser(description="Reset or set user password for copier-hub")
    parser.add_argument("--user", default="admin", help="Username to reset (default: admin)")
    parser.add_argument("--password", default=None, help="New password (if omitted, a secure random password is generated)")
    parser.add_argument("--role", default="admin", choices=["admin", "operator", "viewer"], help="Role (default: admin)")
    args = parser.parse_args()

    users = []
    if os.path.exists(USERS_FILE):
        try:
            with open(USERS_FILE, "r", encoding="utf-8") as f:
                users = json.load(f)
        except Exception as e:
            print(f"[WARN] Failed to read {USERS_FILE}: {e}, initializing fresh user list.")
            users = []

    pw = args.password
    if not pw:
        pw = secrets.token_urlsafe(12)
        print(f"[RESET] Generated random password for '{args.user}': {pw}")
    else:
        print(f"[RESET] Updating password for '{args.user}'...")

    salt = secrets.token_hex(8)
    pw_hash = hash_password(pw, salt)

    found = False
    for u in users:
        if u.get("id") == args.user:
            u["pass"] = pw_hash
            u["role"] = args.role
            u["disabled"] = False
            found = True
            break

    if not found:
        users.append({
            "id": args.user,
            "pass": pw_hash,
            "role": args.role,
            "disabled": False
        })

    tmp_file = USERS_FILE + ".tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        json.dump(users, f, indent=2)
    os.replace(tmp_file, USERS_FILE)

    print("")
    print("=" * 60)
    print(f"  [OK] User '{args.user}' password successfully updated!")
    print(f"       User ID:  {args.user}")
    print(f"       Password: {args.password}")
    print(f"       Role:     {args.role}")
    print(f"       File:     {USERS_FILE}")
    print("=" * 60)
    print("  IMPORTANT: You must RESTART the Hub (hublog.bat / copier-hub)")
    print("             for the new credentials to take effect in memory.")
    print("=" * 60)
    print("")

if __name__ == "__main__":
    main()
