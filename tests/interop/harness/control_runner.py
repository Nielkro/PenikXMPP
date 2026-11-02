#!/usr/bin/env python3
"""Private-file controller. Never prints account config or credentials."""
import argparse
import json
import os
import pathlib
import secrets
import subprocess
import sys
import time
import uuid

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent
ROOT = BASE.parents[1]
ROLES = ("nora", "leon", "felix")

def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    os.replace(tmp, path)

def state_dir(role):
    if role not in ROLES:
        raise ValueError("Unknown controlled role")
    return BASE / "runner-profiles" / role

def prepare():
    accounts = json.loads((BASE / "private/interop-accounts.json").read_text())
    selected = {}
    for role in ROLES:
        matches = [a for a in accounts if a["name"].split()[0].lower() == role]
        if len(matches) != 1:
            raise ValueError("Expected exactly one provisioned account for " + role)
        selected[role] = matches[0]
    owned_jids = [a["username"] + "@" + a["domain"] for a in selected.values()]
    run_id = "20261015-" + selected["nora"]["username"].split(".")[-1]
    for role, account in selected.items():
        directory = state_dir(role)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        config_file = directory / "config.json"
        if config_file.exists():
            old = json.loads(config_file.read_text())
            if old["jid"] != account["username"] + "@" + account["domain"]:
                raise ValueError("Existing runner profile belongs to another account")
            old["run_id"] = run_id
            old["allowed_jids"] = [jid for jid in owned_jids if jid != old["jid"]]
            private_json(config_file, old)
            print(role + ": existing isolated configuration retained; run scope synchronized")
            continue
        for child in ("inbox", "results", "xdg-data", "xdg-cache", "xdg-config", "runtime"):
            (directory / child).mkdir(mode=0o700, exist_ok=True)
        config = {"run_id": run_id, "jid": account["username"] + "@" + account["domain"],
                  "password": account["password"], "name": account["name"],
                  "allowed_jids": [jid for jid in owned_jids if jid != account["username"] + "@" + account["domain"]], "allowed_rooms": [], "db_key": secrets.token_hex(32)}
        if role in ("leon", "felix"):
            profile = BASE / "peers/profiles" / (role + "-de")
            credential_file = profile / "credential.json"
            if credential_file.is_file():
                credentials = json.loads(credential_file.read_text())
                config["db_key"] = credentials["database_password"]
                config["xdg_data_home"] = str(profile / "data")
                config["xdg_cache_home"] = str(profile / "cache")
                config["xdg_config_home"] = str(profile / "config")
                config["reuse_owned_profile"] = True
        private_json(config_file, config)
        print(role + ": isolated configuration created")

def start(role):
    if role == "nora":
        raise ValueError("Nora is owned exclusively by the Android emulator")
    directory = state_dir(role)
    if not (directory / "config.json").exists():
        raise ValueError("Run prepare first")
    binary = HERE / "build/dinox-interop"
    config = json.loads((directory / "config.json").read_text())
    receipt = json.loads((HERE / "build/compile-receipt.json").read_text())
    native = next(ROOT / name for name in receipt["linked_artifacts"] if name.endswith("/libdinox-google-webrtc.so"))
    worker = native.parent / "dinox-webrtc-worker"
    if not worker.is_file():
        raise ValueError("Matching native worker is missing")
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("DINOX_", "DINO_", "G_MESSAGES_DEBUG", "LD_PRELOAD")):
            del env[key]
    env.update({"XDG_DATA_HOME": config.get("xdg_data_home", str(directory / "xdg-data")), "XDG_CACHE_HOME": config.get("xdg_cache_home", str(directory / "xdg-cache")),
                "XDG_CONFIG_HOME": config.get("xdg_config_home", str(directory / "xdg-config")), "XDG_RUNTIME_DIR": str(directory / "runtime"),
                "DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE": "synthetic", "DINOX_WEBRTC_WORKER_PATH": str(worker),
                "DINOX_GOOGLE_WEBRTC_CALL_DEBUG": "0", "GTK_A11Y": "none"})
    command = ["dbus-run-session", "--", "xvfb-run", "-a", "-s", "-screen 0 800x600x24", "bwrap",
               "--unshare-user", "--unshare-pid", "--die-with-parent", "--new-session",
               "--dev-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--", str(binary), str(directory)]
    # Foreground process: root owns launch/timeout and can observe completion.
    return subprocess.run(command, env=env).returncode

def command(role, payload, wait):
    directory = state_dir(role)
    value = json.loads(payload)
    if not isinstance(value, dict) or not isinstance(value.get("op"), str):
        raise ValueError("Command must be a JSON object with op")
    # Resolve a human role without putting credentials in process arguments.
    if value.get("peer") in ROLES:
        value["peer"] = json.loads((state_dir(value["peer"]) / "config.json").read_text())["jid"]
    value["run_id"] = json.loads((directory / "config.json").read_text())["run_id"]
    value["id"] = str(time.time_ns()) + "-" + uuid.uuid4().hex
    private_json(directory / "inbox" / (value["id"] + ".json"), value)
    result = directory / "results" / (value["id"] + ".json")
    deadline = time.monotonic() + wait
    while wait > 0 and time.monotonic() < deadline:
        if result.exists():
            print(result.read_text().strip())
            return 0
        time.sleep(0.2)
    print(result)
    return 0 if wait == 0 else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("prepare")
    starter = sub.add_parser("start")
    starter.add_argument("role", choices=ROLES)
    sender = sub.add_parser("command")
    sender.add_argument("role", choices=ROLES)
    sender.add_argument("json")
    sender.add_argument("--wait", type=float, default=0)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
        return 0
    if args.action == "start":
        return start(args.role)
    return command(args.role, args.json, args.wait)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError) as error:
        print(type(error).__name__ + ": private controller operation failed", file=sys.stderr)
        raise SystemExit(2)
