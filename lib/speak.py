"""Read text aloud into an audio file with Kokoro, and print the file's path.

Run by bin/speak with the Python of the venv lib/kokoro_install.sh makes. The
text is a reply of Claude's, in markdown, so it's first turned into what a
person would read out: code blocks are skipped, links read as their words,
table rows as lists, and a path as its last part.

Files go to ~/.cache/rsk-speak, named by time and first words, and ones older
than a week are deleted.

Usage: python lib/speak.py [--voice V] [--speed S] [text...]
  text     what to read; read from standard input when none is given
  --voice  a Kokoro voice (default af_heart, or $RSK_SPEAK_VOICE)
  --speed  1 is normal (default 1, or $RSK_SPEAK_SPEED)
"""
import argparse
import os
import re
import sys
import time
from pathlib import Path

KEEP_DAYS = 7


def kokoro_dir():
    data = os.environ.get("RSK_DATA_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "richslurmkit"
    )
    return Path(data) / "kokoro"


def cache_dir():
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return Path(cache) / "rsk-speak"


# A path, read as its last part: absolute, from ~ or ., or relative with two
# slashes or a file name at the end (lib/mx.sh). Not "and/or".
NAME = r"[\w.+@%=,-]+"
PATH = re.compile(
    rf"(?<![\w/])(?:(?:~|\.{{1,2}})?(?:/{NAME})+|{NAME}/{NAME}(?:/{NAME})+|{NAME}/[\w-]+\.[A-Za-z]\w*)/?(?::\d+(?::\d+)?)?"
)
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
TABLE_RULE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
MARKER = re.compile(r"^\s*(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)+")


def last_part(m):
    path = re.sub(r"(:\d+)+$", "", m.group(0)).rstrip("/")
    return path.rsplit("/", 1)[-1] or path


def speakable_line(line):
    line = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", line)
    line = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)
    line = re.sub(r"<[a-z][\w+.-]*:[^>\s]*>", "link", line)
    line = re.sub(r"\b[a-z][\w+.-]*://\S+", "link", line)
    line = re.sub(r"`+([^`]+)`+", r"\1", line)
    line = re.sub(r"(\*\*|__)(.+?)\1", r"\2", line)
    line = re.sub(r"(?<![\w*])\*(\S(?:.*?\S)?)\*(?![\w*])", r"\1", line)
    line = re.sub(r"(?<!\w)_(\S(?:.*?\S)?)_(?!\w)", r"\1", line)
    line = PATH.sub(last_part, line)
    line = line.replace("->", " to ").replace("→", " to ").replace("&", " and ")
    line = re.sub(r"<[^>]+>", "", line)
    return re.sub(r"\s+", " ", line).strip()


def speakable(markdown):
    """The words of a markdown reply, one sentence or item per line."""
    out = []
    fence = None
    for line in markdown.splitlines():
        m = FENCE.match(line)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and line.strip(" `~") == "":
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        if TABLE_RULE.match(line) and "-" in line:
            continue
        if line.strip().startswith("|"):
            line = ", ".join(c.strip() for c in line.strip().strip("|").split("|") if c.strip())
        line = speakable_line(MARKER.sub("", line))
        if not line:
            continue
        # A heading, list item or table row ends without a full stop; give it
        # one so the voice pauses there.
        if line[-1] not in ".!?:;,":
            line += "."
        out.append(line)
    return "\n".join(out)


def file_name(text, ext):
    words = re.findall(r"[a-z0-9]+", text.lower())[:5]
    slug = "-".join(words)[:40].strip("-") or "speech"
    return f"{time.strftime('%Y%m%d-%H%M%S')}-{slug}.{ext}"


def prune(folder):
    cutoff = time.time() - KEEP_DAYS * 86400
    for f in folder.iterdir():
        try:
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink()
        except OSError:
            pass


def synthesize(text, voice, speed):
    import onnxruntime as ort
    from kokoro_onnx import EspeakConfig, Kokoro

    folder = kokoro_dir()
    options = ort.SessionOptions()
    # The CPUs this job may use, not every CPU on the node.
    options.intra_op_num_threads = len(os.sched_getaffinity(0))
    session = ort.InferenceSession(str(folder / "kokoro-v1.0.onnx"), options, providers=["CPUExecutionProvider"])
    # The espeak-ng lib/kokoro_install.sh put there; see that script for why.
    espeak = EspeakConfig(
        lib_path=str(folder / "espeak-ng" / "libespeak-ng.so.1"), data_path=str(folder / "espeak-ng" / "espeak-ng-data")
    )
    kokoro = Kokoro.from_session(session, str(folder / "voices-v1.0.bin"), espeak_config=espeak)
    # Kokoro splits long text into pieces the model takes, and pauses after
    # each sentence.
    return kokoro.create(text, voice=voice, speed=speed, lang="en-us")


def write(samples, rate, text):
    import soundfile as sf

    folder = cache_dir()
    folder.mkdir(parents=True, exist_ok=True)
    prune(folder)
    formats = sf.available_formats()
    ext, fmt = ("mp3", "MP3") if "MP3" in formats else ("ogg", "OGG") if "OGG" in formats else ("wav", "WAV")
    path = folder / file_name(text, ext)
    sf.write(str(path), samples, rate, format=fmt)
    return path


def main():
    parser = argparse.ArgumentParser(description="Read text aloud into an audio file.")
    parser.add_argument("text", nargs="*")
    parser.add_argument("--voice", default=os.environ.get("RSK_SPEAK_VOICE", "af_heart"))
    parser.add_argument("--speed", type=float, default=float(os.environ.get("RSK_SPEAK_SPEED", "1")))
    args = parser.parse_args()
    raw = " ".join(args.text) if args.text else sys.stdin.read()
    text = speakable(raw)
    if not text:
        sys.exit("speak: nothing to read")
    samples, rate = synthesize(text, args.voice, args.speed)
    print(write(samples, rate, text))


if __name__ == "__main__":
    main()
