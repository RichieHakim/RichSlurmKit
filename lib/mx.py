#!/usr/bin/env python3
"""Session listing for `m`: the zmx sessions on this node, with the title and
status of the claude running in each, read from ~/.claude/sessions/<pid>.json
and the claude process's environment.

Subcommands:
  ls      Show zmx sessions on this host (the default).
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

CLAUDE_DIR = os.path.expanduser("~/.claude")
# Same pinned socket dir as lib/mx.sh, for when this runs on its own.
os.environ.setdefault("ZMX_DIR", f"/tmp/zmx-{os.getuid()}")


# ----------------------------------------------------------------- claude ---

def machine_id():
    try:
        with open("/etc/machine-id") as f:
            return f.read().strip()
    except OSError:
        return ""


def mux_of(env):
    """(mux, session name) for an environment, or (None, None)."""
    if env.get("ZMX_SESSION"):
        return "zmx", env["ZMX_SESSION"]
    if env.get("ZELLIJ_SESSION_NAME"):
        return "zellij", env["ZELLIJ_SESSION_NAME"]
    return None, None


def find_transcript(session_id, cwd=None):
    if cwd:
        slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
        path = os.path.join(CLAUDE_DIR, "projects", slug, session_id + ".jsonl")
        if os.path.exists(path):
            return path
    hits = glob.glob(os.path.join(CLAUDE_DIR, "projects", "*", session_id + ".jsonl"))
    return hits[0] if hits else None


def transcript_title(path):
    """Session title (custom-title / agent-name) or else the last prompt,
    read from the tail of the transcript."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 256 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    prompt = ""
    for line in reversed(lines):
        if not line.startswith('{"type":"'):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = d.get("type")
        if t == "custom-title" and d.get("customTitle"):
            return d["customTitle"]
        if t == "agent-name" and d.get("agentName"):
            return d["agentName"]
        if t == "last-prompt" and not prompt:
            prompt = d.get("lastPrompt") or ""
    return " ".join(prompt.split())


def proc_start(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            # Field 22; split after the ")" that closes the command name.
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except (OSError, IndexError, ValueError):
        return None


def proc_env(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            raw = f.read().split(b"\0")
    except OSError:
        return {}
    env = {}
    for item in raw:
        k, sep, v = item.partition(b"=")
        if sep:
            env[k.decode(errors="replace")] = v.decode(errors="replace")
    return env


def live_claudes():
    """Live claude processes on this host, from ~/.claude/sessions/<pid>.json."""
    mid = machine_id()
    out = []
    for path in glob.glob(os.path.join(CLAUDE_DIR, "sessions", "*.json")):
        try:
            with open(path) as f:
                reg = json.load(f)
            pid = int(reg["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not mid or mid not in str(reg.get("pidDomain", "")):
            continue
        if reg.get("procStart") is not None and str(proc_start(pid)) != str(reg["procStart"]):
            continue  # dead, or the pid was reused
        reg["env"] = proc_env(pid)
        out.append(reg)
    return out


# -------------------------------------------------------------------- zmx ---

def zmx_sessions():
    """{name: {key: value}} from `zmx list`; empty if zmx is missing."""
    if not shutil.which("zmx"):
        return {}
    p = subprocess.run(["zmx", "list"], capture_output=True, text=True)
    out = {}
    for line in p.stdout.splitlines():
        fields = dict(f.split("=", 1) for f in line.strip().split("\t") if "=" in f)
        if "name" in fields:
            out[fields["name"]] = fields
    return out


def age(seconds):
    seconds = max(0, int(seconds))
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def short_path(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


def clip(text, width):
    return text if len(text) <= width else text[:width - 1] + "…"


def cmd_ls():
    sessions = zmx_sessions()
    if not sessions:
        print("No zmx sessions on this host. Start one with: mc [name]")
        return
    by_name = {}
    for reg in live_claudes():
        mux, name = mux_of(reg["env"])
        if mux == "zmx":
            by_name[name] = reg
    print(f"{'SESSION':<18} {'CLIENTS':<7} {'AGE':<5} {'CLAUDE':<34} DIR")
    now = time.time()
    for name, s in sorted(sessions.items()):
        reg = by_name.get(name)
        if reg:
            label = reg.get("name") or transcript_title(
                find_transcript(reg["sessionId"], reg.get("cwd")) or "")
            claude = f"[{reg.get('status', '?')}] {label}"
        else:
            claude = "-"
        cwd = re.sub(r"^file://[^/]*", "", s.get("cwd", ""))
        created = float(s.get("created", now))
        print(f"{name:<18} {s.get('clients', '?'):<7} {age(now - created):<5} "
              f"{clip(claude, 34):<34} {short_path(cwd)}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "ls"
    if cmd == "ls":
        cmd_ls()
        return 0
    if cmd == "hook":
        # Claudes started while `c` still added a session-recording hook run
        # this on /clear and exit. Stay silent; drop once they have all exited.
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
