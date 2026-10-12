#!/usr/bin/env python3
"""Session bookkeeping for the zmx-based `m*` commands.

When a Slurm job ends, every zmx session in it dies with its `claude`. To bring
them back in the next job we keep one small JSON record per session name in
the state dir, saying which Claude conversation ran there, in which directory,
on which host and in which job:

  - `c`/`cr` load this file as a SessionStart/SessionEnd hook whenever they run
    inside a zmx or zellij session, so the record follows /clear and /resume.
  - `snapshot` also records every live claude on this host that runs inside a
    zmx or zellij session (from ~/.claude/sessions/<pid>.json plus the
    process environment). The m* commands run it on every call, which is how
    sessions started without the hook get picked up.

Subcommands:
  hook                 Claude Code hook entry point (JSON on stdin; silent).
  snapshot             Record live claude sessions on this host.
  ls                   Show live zmx sessions (and how many can be revived).
  revive [opts] [names...]
                       Show sessions whose job ended; recreate them with
                       `c -r <id>` in their old directory. Options:
                         all        revive every revivable session
                         --forget   delete the named records instead
                         --dry-run  only print what would happen
  forget names...      Delete records (used by `m kill`).
  end names...         Mark records exited, so only `mrevive NAME` revives
                       them (used by `m end`).

State dir: $RSK_M_STATE_DIR, else $XDG_STATE_HOME/richslurmkit/m-sessions.
"""
import glob
import json
import os
import pty
import re
import select
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

CLAUDE_DIR = os.path.expanduser("~/.claude")
# The repo's `c`, by absolute path: it adds the recording hook, and a different
# `c` may come first on PATH.
C_BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "c")
STATE_DIR = os.environ.get("RSK_M_STATE_DIR") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "richslurmkit", "m-sessions")
# Same pinned socket dir as lib/mx.sh, for when this runs on its own.
os.environ.setdefault("ZMX_DIR", f"/tmp/zmx-{os.getuid()}")
# Size of the invisible terminal a revived session starts in. The first real
# client to attach resizes it.
SPAWN_ROWS, SPAWN_COLS = 48, 160


# ----------------------------------------------------------------- records ---

def host():
    return socket.gethostname().split(".")[0]


def machine_id():
    try:
        with open("/etc/machine-id") as f:
            return f.read().strip()
    except OSError:
        return ""


def record_path(name):
    return os.path.join(STATE_DIR, re.sub(r"[^A-Za-z0-9._-]", "_", name) + ".json")


def load_records():
    out = {}
    for path in glob.glob(os.path.join(STATE_DIR, "*.json")):
        try:
            with open(path) as f:
                rec = json.load(f)
            out[rec["name"]] = rec
        except (OSError, ValueError, KeyError):
            continue
    return out


def write_record(rec):
    """Atomic write: the state dir is on NFS and several sessions share it."""
    os.makedirs(STATE_DIR, exist_ok=True)
    rec["updated"] = time.time()
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=1)
    os.replace(tmp, record_path(rec["name"]))


def forget(names):
    for name in names:
        try:
            os.remove(record_path(name))
            print(f"forgot {name}")
        except FileNotFoundError:
            pass


def cmd_end(names):
    """Mark records exited, as /exit would: `mrevive all` skips them and
    `mrevive NAME` still brings them back. `m end` kills the sessions after."""
    records, sessions = load_records(), zmx_sessions()
    rc = 0
    for name in names:
        rec = records.get(name)
        if not rec:
            if name not in sessions:
                print(f"m end: no session or record named {name}", file=sys.stderr)
                rc = 1
            continue
        rec["exited"] = True
        write_record(rec)
        if name in sessions:
            print(f"keeping {name} for `mrevive {name}`")
        else:
            print(f"{name} is not a zmx session on this node, so nothing to kill; "
                  f"marked it ended (`mrevive {name}` still brings it back)")
    return rc


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


# ------------------------------------------------------------------- hook ---

def claude_pid():
    """The claude process running this hook: the nearest ancestor that has a
    ~/.claude/sessions/<pid>.json (hooks run under a shell, not directly)."""
    pid = os.getppid()
    for _ in range(4):
        if os.path.exists(os.path.join(CLAUDE_DIR, "sessions", f"{pid}.json")):
            return pid
        try:
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            break
    return None


def cmd_hook():
    """SessionStart / SessionEnd hook. Must print nothing to stdout (SessionStart
    output is added to Claude's context) and must never fail the session."""
    try:
        data = json.load(sys.stdin)
        mux, name = mux_of(os.environ)
        if not name:
            return
        event = data.get("hook_event_name")
        old = load_records().get(name, {})
        if event == "SessionEnd":
            # Only a deliberate exit marks the record; /clear is followed by a
            # SessionStart with the new id, and a killed job never gets here.
            if data.get("reason") in ("prompt_input_exit", "logout") and \
                    old.get("claude_session_id") == data.get("session_id"):
                old["exited"] = True
                write_record(old)
            return
        if event != "SessionStart" or not data.get("session_id"):
            return
        write_record({
            "name": name,
            "mux": mux,
            "claude_session_id": data["session_id"],
            "cwd": data.get("cwd") or os.getcwd(),
            "transcript_path": data.get("transcript_path") or "",
            "host": host(),
            "machine_id": machine_id(),
            "slurm_job_id": os.environ.get("SLURM_JOB_ID", ""),
            "pid": claude_pid(),
            "source": "hook:" + str(data.get("source", "")),
            "exited": False,
        })
    except Exception:
        pass


# --------------------------------------------------------------- snapshot ---

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


def cmd_snapshot(quiet=True):
    records = load_records()
    for reg in live_claudes():
        mux, name = mux_of(reg["env"])
        if not name or not reg.get("sessionId"):
            continue
        old = records.get(name, {})
        same = (old.get("claude_session_id") == reg["sessionId"]
                and old.get("pid") == reg["pid"] and old.get("host") == host())
        if same:
            continue
        write_record({
            "name": name,
            "mux": mux,
            "claude_session_id": reg["sessionId"],
            "cwd": reg.get("cwd", ""),
            "transcript_path": find_transcript(reg["sessionId"], reg.get("cwd")) or "",
            "host": host(),
            "machine_id": machine_id(),
            "slurm_job_id": reg["env"].get("SLURM_JOB_ID", ""),
            "pid": reg["pid"],
            "source": "snapshot",
            "exited": False,
        })
        if not quiet:
            print(f"recorded {name} ({mux}) -> {reg['sessionId']}")


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


def running_jobs():
    """Your job ids still in squeue (one call), or None if squeue failed."""
    try:
        p = subprocess.run(["squeue", "-h", "-u", os.environ.get("USER", ""),
                            "-t", "PD,R,S,CG", "-o", "%A"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return set(p.stdout.split())


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
    by_name = {}
    for reg in live_claudes():
        mux, name = mux_of(reg["env"])
        if mux == "zmx":
            by_name[name] = reg
    if sessions:
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
    else:
        print("No zmx sessions on this host. Start one with: mc [name]")
    records = load_records()
    # squeue only matters for records from other hosts; skip the call otherwise.
    mid = machine_id()
    jobs = running_jobs() if any(r.get("machine_id") != mid for r in records.values()) else set()
    n = len([r for r in plan_revive(records, sessions, jobs) if r["state"] == "revivable"])
    if n:
        print(f"\n{n} session(s) from ended jobs can be revived: mrevive")


# ----------------------------------------------------------------- revive ---

def plan_revive(records, sessions, jobs):
    """Annotate each record with a state: live, elsewhere, revivable, exited,
    no-transcript, unknown."""
    here, mid = host(), machine_id()
    live_ids = {reg.get("sessionId") for reg in live_claudes()}
    plan = []
    for rec in records.values():
        rec = dict(rec)
        transcript = rec.get("transcript_path") or ""
        if not os.path.exists(transcript):
            transcript = find_transcript(rec["claude_session_id"], rec.get("cwd")) or ""
        rec["transcript_path"] = transcript
        job = rec.get("slurm_job_id", "")
        if rec["claude_session_id"] in live_ids:
            rec["state"], rec["why"] = "live", f"running here ({host()})"
        elif rec.get("machine_id") == mid and rec.get("name") in sessions:
            rec["state"], rec["why"] = "live", "zmx session exists here"
        elif rec.get("machine_id") != mid and (jobs is None or (job and job in jobs)):
            # Running on another node: reviving it here would put two claudes
            # on one transcript.
            why = "squeue failed" if jobs is None else f"job {job} on {rec.get('host')}"
            rec["state"], rec["why"] = "elsewhere", why
        elif rec.get("machine_id") != mid and not job:
            rec["state"], rec["why"] = "unknown", f"not in a Slurm job, on {rec.get('host')}"
        elif not transcript:
            rec["state"], rec["why"] = "no-transcript", "conversation file is gone"
        elif rec.get("exited"):
            rec["state"], rec["why"] = "exited", "you quit claude"
        else:
            rec["state"], rec["why"] = "revivable", (
                f"job {job} ended" if job and job not in (jobs or ()) else "claude is gone")
        rec["last_active"] = (os.path.getmtime(transcript) if transcript
                              else rec.get("updated", 0))
        plan.append(rec)
    plan.sort(key=lambda r: -r["last_active"])
    return plan


def print_plan(plan):
    now = time.time()
    print(f"{'SESSION':<18} {'STATE':<13} {'ACTIVE':<7} {'TITLE':<38} DIR")
    for r in plan:
        title = transcript_title(r["transcript_path"]) if r["transcript_path"] else ""
        print(f"{r['name']:<18} {r['state']:<13} {age(now - r['last_active']) + ' ago':<7} "
              f"{clip(title, 38):<38} {short_path(r.get('cwd', ''))}")


def spawn_detached(name, cwd, inner):
    """Create zmx session NAME running `bash -ic INNER` without attaching to it.

    zmx only creates sessions from `attach`, which needs a terminal, so run it
    on a private pty, wait for the session to appear, then detach that client.
    """
    env = dict(os.environ)
    env.pop("ZMX_SESSION", None)  # else zmx switches the caller's terminal
    pid, fd = pty.fork()
    if pid == 0:
        try:
            import fcntl
            import termios
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", SPAWN_ROWS, SPAWN_COLS, 0, 0))
            os.chdir(cwd)
            os.execvpe("zmx", ["zmx", "attach", name, "bash", "-ic", inner], env)
        finally:
            os._exit(127)
    deadline = time.time() + 15
    created = False
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                os.read(fd, 65536)  # drain so the client never blocks on output
            except OSError:
                break
        if name in zmx_sessions():
            created = True
            break
    if created:
        subprocess.run(["zmx", "detach"], env={**env, "ZMX_SESSION": name},
                       capture_output=True)
    end = time.time() + 5
    while time.time() < end:
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            break
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                pass
    else:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    os.close(fd)
    return created


def cmd_revive(args):
    dry = "--dry-run" in args
    if "--forget" in args:
        forget([a for a in args if not a.startswith("--")])
        return 0
    names = [a for a in args if not a.startswith("--")]
    want_all = names == ["all"]
    sessions = zmx_sessions()
    plan = plan_revive(load_records(), sessions, running_jobs())
    if not names:
        if not plan:
            print("No recorded sessions yet. They are recorded while running inside zmx/zellij.")
            return 0
        print_plan(plan)
        n = len([r for r in plan if r["state"] == "revivable"])
        print(f"\n{n} revivable. `mrevive all` brings them all back; `mrevive NAME...` "
              "picks some (also works for 'exited'); `mrevive --forget NAME...` drops records.")
        return 0
    if not shutil.which("zmx"):
        print("mrevive: zmx is not installed (run $RSK_ROOT/lib/zmx_install.sh)", file=sys.stderr)
        return 1
    by_name = {r["name"]: r for r in plan}
    if want_all:
        targets = [r for r in plan if r["state"] == "revivable"]
    else:
        targets = []
        for n in names:
            r = by_name.get(n)
            if not r:
                print(f"mrevive: no record named {n}", file=sys.stderr)
            elif r["state"] not in ("revivable", "exited"):
                print(f"mrevive: skipping {n}: {r['state']} ({r['why']})", file=sys.stderr)
            else:
                targets.append(r)
    if not targets:
        print("Nothing to revive.")
        return 0
    rc = 0
    for r in targets:
        name, cwd = r["name"], r.get("cwd") or os.path.expanduser("~")
        if name in sessions:
            print(f"skip {name}: a zmx session with that name already exists here")
            continue
        if not os.path.isdir(cwd):
            print(f"skip {name}: directory {cwd} is gone")
            continue
        inner = f"{shlex.quote(C_BIN)} -r {shlex.quote(r['claude_session_id'])}; exec bash -i"
        print(f"{'would revive' if dry else 'reviving'} {name} in {short_path(cwd)} "
              f"(claude -r {r['claude_session_id']})")
        if dry:
            continue
        if spawn_detached(name, cwd, inner):
            rec = {k: v for k, v in r.items() if k not in ("state", "why", "last_active")}
            rec.update(mux="zmx", host=host(), machine_id=machine_id(),
                       slurm_job_id=os.environ.get("SLURM_JOB_ID", ""), pid=None,
                       source="revive", exited=False)
            write_record(rec)
        else:
            print(f"  failed to create zmx session {name}", file=sys.stderr)
            rc = 1
    if targets and not dry:
        print("Attach with: m a NAME")
    return rc


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("ls", [])
    if cmd == "hook":
        cmd_hook()
        return 0
    if cmd == "snapshot":
        cmd_snapshot(quiet="-v" not in args)
        return 0
    if cmd == "ls":
        cmd_ls()
        return 0
    if cmd == "revive":
        return cmd_revive(args)
    if cmd == "forget":
        forget(args)
        return 0
    if cmd == "end":
        return cmd_end(args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
