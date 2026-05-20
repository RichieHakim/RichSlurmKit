# Auto-installer for the Microsoft devtunnel CLI.
# Used by `vclean` to delete stale VS Code tunnel registrations at the account
# level (`code tunnel unregister` only handles the local CLI dir, which is gone
# once SLURM hard-kills a job).
#
# Sets $RSK_DEVTUNNEL_BIN on success.

rsk_install_devtunnel() {
    local dest_dir="${RSK_DATA_DIR:-$HOME/.local/share/richslurmkit}/bin"
    local dest="${dest_dir}/devtunnel"
    local url="https://aka.ms/TunnelsCliDownload/linux-x64"

    RSK_DEVTUNNEL_BIN="$dest"

    if [[ -x "$dest" ]]; then
        return 0
    fi

    mkdir -p "$dest_dir"
    local tmp
    tmp=$(mktemp "${dest}.tmp.XXXXXX")
    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        echo "RichSlurmKit: failed to download devtunnel from $url" >&2
        return 1
    fi
    chmod 700 "$tmp"
    mv "$tmp" "$dest"
}
