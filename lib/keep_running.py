#!/usr/bin/env python3
"""Run a command, and resume it whenever a SIGTSTP stops it.

When Slurm pauses a job (FASRC does this for monthly maintenance), it sends
SIGTSTP to every process in the job, waits 2 seconds, and then freezes them
all. The SIGTSTP stops programs like the zmx client and claude. The shell
that started such a program sees it stop and takes the terminal back, and
after the pause the program runs on without a keyboard: mouse moves print
junk at the shell's prompt. A shell running `claude; exec bash -i` instead
goes on to the exec, which sends SIGTERM to the stopped claude.

This wrapper runs between the shell and the program. The shell sees only the
wrapper, which ignores SIGTSTP (by catching it, so the program still gets the
default), and the wrapper resumes the program as soon as a SIGTSTP stops it,
before the freeze. Shells can't see the freeze itself. One side effect:
Ctrl+Z in claude, which stops itself with SIGTSTP, does nothing.

When the wrapper starts in the terminal's foreground, it puts the program in
a process group of its own and gives it the terminal, as a shell would. So
the terminal's foreground process, which VS Code names the terminal tab
after, is the program and not this wrapper, and Ctrl+C and window resizes go
to the program alone.

Stops by other signals (SIGSTOP, or SIGTTIN/SIGTTOU) are passed up: the
wrapper stops too, so the shell sees the job stop, and `fg` resumes both.

Usage: keep_running.py [--name ARGV0] command [args...]
  --name  run the command with ARGV0 as its argv[0], which is what VS Code
          shows as the tab's name
"""
import os
import signal
import sys


def foreground_tty():
    """fd 0 if it's a terminal and this process is in its foreground, else None."""
    try:
        if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
            return 0
    except OSError:
        pass
    return None


def main():
    argv = sys.argv[1:]
    argv0 = None
    if argv[:1] == ["--name"] and len(argv) >= 2:
        argv0, argv = argv[1], argv[2:]
    if not argv:
        sys.exit("usage: keep_running.py [--name ARGV0] command [args...]")
    tty = foreground_tty()

    # Before the fork, so a SIGTSTP that comes before the child's exec can't
    # stop this process. SIGTTOU is ignored so this process can hand the
    # terminal back and forth from outside the foreground.
    signal.signal(signal.SIGTSTP, lambda signum, frame: None)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)

    pid = os.fork()
    if pid == 0:
        if tty is not None:
            os.setpgid(0, 0)
            os.tcsetpgrp(tty, os.getpgrp())
        # exec resets caught signals to the default. Python ignores SIGPIPE
        # and SIGXFSZ itself, so put those back too, along with SIGTTOU.
        for sig in (signal.SIGTSTP, signal.SIGTTOU, signal.SIGPIPE, signal.SIGXFSZ):
            signal.signal(sig, signal.SIG_DFL)
        try:
            os.execvp(argv[0], [argv0 or argv[0]] + argv[1:])
        except OSError as e:
            print(f"keep_running.py: {argv[0]}: {e.strerror}", file=sys.stderr)
            os._exit(127)

    if tty is not None:
        # The child does the same; whichever runs first wins, as in a shell.
        try:
            os.setpgid(pid, pid)
            os.tcsetpgrp(tty, pid)
        except OSError:
            pass

    def signal_child(sig):
        try:
            if tty is not None:
                os.killpg(pid, sig)
            else:
                os.kill(pid, sig)
        except ProcessLookupError:
            pass

    # A shell's `kill %1`, or closing the terminal, reaches only this
    # process's group. Pass them on and exit when the program does.
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: signal_child(signum))
    # The terminal sends these to the foreground group. Leave them to the
    # program, as if the wrapper weren't there.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGQUIT, signal.SIG_IGN)

    while True:
        _, status = os.waitpid(pid, os.WUNTRACED)
        if not os.WIFSTOPPED(status):
            break
        if os.WSTOPSIG(status) == signal.SIGTSTP:
            signal_child(signal.SIGCONT)
            continue
        # Stop too, with the terminal back in this group, so the shell sees
        # the job stop. When `fg` resumes this process, resume the program.
        if tty is not None:
            os.tcsetpgrp(tty, os.getpgrp())
        os.kill(os.getpid(), signal.SIGSTOP)
        if tty is not None:
            os.tcsetpgrp(tty, pid)
        signal_child(signal.SIGCONT)

    # Take the terminal back, for a parent that isn't a job-control shell.
    if tty is not None:
        try:
            os.tcsetpgrp(tty, os.getpgrp())
        except OSError:
            pass
    if os.WIFSIGNALED(status):
        # Die the same way, so the shell reports what happened.
        sig = os.WTERMSIG(status)
        try:
            signal.signal(sig, signal.SIG_DFL)
        except (OSError, ValueError):
            pass
        os.kill(os.getpid(), sig)
        sys.exit(128 + sig)
    sys.exit(os.WEXITSTATUS(status))


if __name__ == "__main__":
    main()
