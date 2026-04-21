#!/usr/bin/env python3
"""Generate SSH commit-signing keys and upload to GitHub accounts.

Each account gets a unique key (GitHub enforces key uniqueness).
Requires github_token and github_token_personal as Docker build secrets.
"""
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

KEY_TITLE = "sandbox-signing-key"
KEY_DIR = os.path.expanduser("~/.ssh")
GH_API = "https://api.github.com"

GIT_USER_NAME = os.environ["GIT_USER_NAME"]
GIT_USER_EMAIL = os.environ["GIT_USER_EMAIL"]


def read_secret(name: str) -> str:
    with open(f"/run/secrets/{name}") as f:
        return f.read().strip()


def gh_request(method: str, path: str, token: str, data: dict | None = None) -> tuple[int, any]:
    url = f"{GH_API}{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, None
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw.decode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw


def setup_signing_key(token: str, label: str) -> str:
    key_path = os.path.join(KEY_DIR, f"sandbox_signing_{label}")

    # Generate key
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-f", key_path, "-N", "",
         "-C", f"{GIT_USER_NAME} <{GIT_USER_EMAIL}> ({label} sandbox)", "-q"],
        check=True,
    )

    # Delete existing sandbox signing keys
    status, keys = gh_request("GET", "/user/ssh_signing_keys?per_page=100", token)
    if status == 200 and isinstance(keys, list):
        for key in keys:
            if key.get("title") == KEY_TITLE:
                del_status, _ = gh_request("DELETE", f"/user/ssh_signing_keys/{key['id']}", token)
                if del_status < 300:
                    print(f"Deleted old signing key {key['id']} ({label})", file=sys.stderr)

    # Upload public key
    with open(f"{key_path}.pub") as f:
        pub_key = f.read().strip()

    status, resp = gh_request("POST", "/user/ssh_signing_keys", token, {
        "title": KEY_TITLE,
        "key": pub_key,
    })
    if 200 <= status < 300:
        print(f"Uploaded signing key to GitHub ({label})", file=sys.stderr)
    else:
        print(f"Failed to upload signing key ({label}): HTTP {status}", file=sys.stderr)
        print(json.dumps(resp, indent=2), file=sys.stderr)
        sys.exit(1)

    return key_path


def main():
    os.makedirs(KEY_DIR, exist_ok=True)

    github_token = read_secret("github_token")
    github_token_personal = read_secret("github_token_personal")

    work_key = setup_signing_key(github_token, "work")
    personal_key = setup_signing_key(github_token_personal, "personal")

    # Write sandbox git signing config (work key as default)
    with open(os.path.expanduser("~/.gitconfig.sandbox"), "w") as f:
        f.write(f"""[user]
\tsigningkey = {work_key}
[gpg]
\tformat = ssh
[gpg "ssh"]
\tallowedSignersFile = {KEY_DIR}/allowed_signers
[commit]
\tgpgsign = true
[tag]
\tgpgsign = true
""")

    # Personal repos get their own signing key
    with open(os.path.expanduser("~/.gitconfig.sandbox-personal"), "w") as f:
        f.write(f"""[user]
\tsigningkey = {personal_key}
""")

    # Create allowed_signers for verification (both keys)
    with open(os.path.join(KEY_DIR, "allowed_signers"), "w") as f:
        for key_path in [work_key, personal_key]:
            with open(f"{key_path}.pub") as pub:
                f.write(f"{GIT_USER_EMAIL} {pub.read().strip()}\n")


if __name__ == "__main__":
    main()
