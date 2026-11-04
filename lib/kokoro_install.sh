#!/bin/bash
# Install Kokoro (https://github.com/hexgrad/kokoro), the text-to-speech model
# behind `speak` and Claude's /speak, into $RSK_DATA_DIR/kokoro:
# - venv/: kokoro-onnx, which runs the model with onnxruntime on the CPU
# - kokoro-v1.0.onnx and voices-v1.0.bin: the model and its voices
# - espeak-ng/: the espeak-ng library and data that turn words into phonemes
#
# kokoro-onnx brings its own espeak-ng, but that build needs glibc 2.29 and
# RHEL 8 (FASRC) has 2.28. The one in the piper-phonemize wheel needs only
# 2.14, so this takes the library and its data from that wheel.
#
# Downloads are pinned by sha256. Takes about 750 MB. Run it again to repair
# a partial install.
#
# Usage: lib/kokoro_install.sh
set -euo pipefail

KOKORO_ONNX_VERSION="0.6.1"
SOUNDFILE_VERSION="0.14.0"
MODELS_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
declare -A MODEL_SHA256=(
    [kokoro-v1.0.onnx]="beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a"
    [voices-v1.0.bin]="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"
)
PIPER_WHEEL_URL="https://files.pythonhosted.org/packages/b8/b7/a8fc2584d509ca36d5713693d675a88f80e4c3725e16a8c7ff1451f0ba99/piper_phonemize-1.1.0-cp311-cp311-manylinux_2_28_x86_64.whl"
PIPER_WHEEL_SHA256="c1062e00c94835e9115df7ce1d7b3b5c40c6d845cd70b2c121954faf5b8d23c7"

if [[ "$(uname -s)/$(uname -m)" != "Linux/x86_64" ]]; then
    echo "kokoro_install: only Linux x86_64 is set up; install Kokoro yourself." >&2
    exit 1
fi

data_dir="${RSK_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit}"
dest="$data_dir/kokoro"
mkdir -p "$dest"
tmp="$(mktemp -d "$dest/.download.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Downloads $1 to $2, unless $2 is there with sha256 $3.
fetch() {
    local url=$1 file=$2 sha=$3
    if [[ -f $file ]] && echo "$sha  $file" | sha256sum -c --status; then
        return
    fi
    echo "Downloading $(basename "$file")"
    curl -fL --progress-bar -o "$tmp/download" "$url"
    if ! echo "$sha  $tmp/download" | sha256sum -c --status; then
        echo "kokoro_install: $(basename "$file") does not match its pinned sha256" >&2
        exit 1
    fi
    mv "$tmp/download" "$file"
}

# 1. The Python packages. --no-cache-dir keeps pip's cache out of home.
if [[ ! -x $dest/venv/bin/python ]]; then
    echo "Making a venv at $dest/venv"
    python3 -m venv "$dest/venv"
fi
"$dest/venv/bin/pip" install --no-cache-dir -q \
    "kokoro-onnx==$KOKORO_ONNX_VERSION" "soundfile==$SOUNDFILE_VERSION"

# 2. The model and voices.
for f in "${!MODEL_SHA256[@]}"; do
    fetch "$MODELS_URL/$f" "$dest/$f" "${MODEL_SHA256[$f]}"
done

# 3. espeak-ng, from the piper-phonemize wheel.
if [[ ! -f $dest/espeak-ng/libespeak-ng.so.1 || ! -d $dest/espeak-ng/espeak-ng-data ]]; then
    fetch "$PIPER_WHEEL_URL" "$tmp/piper.whl" "$PIPER_WHEEL_SHA256"
    "$dest/venv/bin/python" - "$tmp/piper.whl" "$tmp/espeak-ng" <<'EOF'
import sys, zipfile
from pathlib import Path
wheel, out = zipfile.ZipFile(sys.argv[1]), Path(sys.argv[2])
for name in wheel.namelist():
    if name.startswith("piper_phonemize.libs/libespeak-ng"):
        target = out / "libespeak-ng.so.1"
    elif name.startswith("piper_phonemize/espeak-ng-data/") and not name.endswith("/"):
        target = out / name.removeprefix("piper_phonemize/")
    else:
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(wheel.read(name))
EOF
    rm -rf "$dest/espeak-ng"
    mv "$tmp/espeak-ng" "$dest/espeak-ng"
fi

echo "Kokoro is installed in $dest. Try: speak 'Hello there.'"
