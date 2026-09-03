#!/usr/bin/env bash
# Zabin installer — downloads and installs prebuilt zabin-tui and zabctl
# (and optionally zabin-server) release binaries from
# https://github.com/zabin-app/zabin-releases.
#
#   curl -fsSL https://github.com/zabin-app/zabin-releases/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version v0.1.0 --with-server --prefix /opt/zabin
#
# Everything lives inside main(), called at the very end, so a script piped
# through `curl | bash` is read in full before any of it runs.
#
# This script uses bash-only syntax ([[ ]], local, arrays) below this guard,
# so it must not be invoked via `sh`. The guard itself is POSIX `sh`/dash
# safe — it is the only thing that runs before we know which shell we are in.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "install.sh: run this script with bash (curl -fsSL https://github.com/zabin-app/zabin-releases/releases/latest/download/install.sh | bash)" >&2
    exit 2
fi

set -euo pipefail

usage() {
    cat << 'EOF'
Usage: install.sh [OPTIONS]

Downloads and installs prebuilt Zabin release binaries from
https://github.com/zabin-app/zabin-releases.

Options:
  --version vX.Y.Z      Release to install (default: latest)
  --prefix DIR          Installation directory (default: $HOME/.local)
                        Can also be set via ZABIN_INSTALL_PREFIX
  --with-server         Also install zabin-server
  --help                Show this help message

Behavior:
  - Detects OS/arch (Linux x86_64/aarch64, macOS arm64)
  - Downloads the matching release tarball + SHA256SUMS and verifies the
    checksum before installing anything
  - Installs zabin-tui + zabctl (+ zabin-server with --with-server) to
    PREFIX/bin with mode 0755
  - Refuses to run as root unless a prefix is given explicitly
  - Warns if PREFIX/bin is not on PATH
  - Prints the installed version of each binary
  - Idempotent: re-running overwrites the existing binaries

Does not install the PM skill zip (zabin-pm-<version>.zip) — download it
separately from the release page and upload it as a custom skill in
claude.ai / Claude Desktop.

Exit codes:
  0   Success
  1   Error (download, checksum, or installation failure)
  2   Invalid arguments or permissions denied

Environment:
  ZABIN_INSTALL_PREFIX    Alternative to --prefix DIR
  ZABIN_RELEASE_BASE_URL  Override the release base URL (testing / mirrors).
                          Default: https://github.com/zabin-app/zabin-releases/releases
EOF
}

err() {
    echo "Error: $*" >&2
}

# Detect this host's release platform tag, or fail with a pointer to
# building from source. Echoes the platform tag on success.
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux)
            case "$arch" in
                x86_64) echo "linux-amd64" ;;
                aarch64 | arm64) echo "linux-arm64" ;;
                *)
                    err "Unsupported Linux architecture: $arch"
                    echo "Build from source instead: https://github.com/zabin-app/zabin" >&2
                    return 1
                    ;;
            esac
            ;;
        Darwin)
            case "$arch" in
                arm64)
                    echo "darwin-arm64"
                    ;;
                *)
                    err "Unsupported macOS architecture: $arch (only Apple Silicon is published)"
                    echo "Build from source instead: https://github.com/zabin-app/zabin" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            err "Unsupported OS: $os"
            echo "Build from source instead: https://github.com/zabin-app/zabin" >&2
            return 1
            ;;
    esac
}

# Verify a single "hash  filename" SHA256SUMS line against the file it
# names, resolved relative to $1.
verify_checksum() {
    local dir="$1"
    local line="$2"

    if command -v sha256sum > /dev/null 2>&1; then
        (cd "$dir" && printf '%s\n' "$line" | sha256sum -c - > /dev/null 2>&1)
    elif command -v shasum > /dev/null 2>&1; then
        (cd "$dir" && printf '%s\n' "$line" | shasum -a 256 -c - > /dev/null 2>&1)
    else
        err "Neither sha256sum nor shasum is available"
        return 1
    fi
}

# Verify every named binary exists and is executable inside $1, failing
# before any binary is installed if even one is missing. This is what makes
# the install step below all-or-nothing.
verify_extracted_binaries() {
    local dir="$1"
    shift
    local name
    for name in "$@"; do
        if [[ ! -f "$dir/$name" ]]; then
            err "Binary not found in release tarball: $name"
            exit 1
        fi
        if [[ ! -x "$dir/$name" ]]; then
            err "Binary in release tarball is not executable: $name"
            exit 1
        fi
    done
}

verify_binary() {
    local binary_path="$1"
    local binary_name="$2"
    local version_output

    if ! "$binary_path" --version > /dev/null 2>&1; then
        err "Installed binary verification failed: $binary_name"
        exit 1
    fi

    version_output="$("$binary_path" --version 2>&1)"
    echo "OK $binary_name: $version_output"
}

check_path() {
    local bindir="$1"
    local resolved
    resolved="$(cd "$bindir" && pwd)"

    case ":${PATH}:" in
        *":${resolved}:"*) ;;
        *)
            echo "Warning: $bindir is not on PATH" >&2
            echo "Add it with: export PATH=\"$bindir:\$PATH\"" >&2
            ;;
    esac
}

main() {
    local version=""
    local prefix="${ZABIN_INSTALL_PREFIX:-$HOME/.local}"
    local prefix_explicit=0
    local with_server=0
    local base_url="${ZABIN_RELEASE_BASE_URL:-https://github.com/zabin-app/zabin-releases/releases}"

    if [[ -n "${ZABIN_INSTALL_PREFIX:-}" ]]; then
        prefix_explicit=1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                version="${2:-}"
                if [[ -z "$version" ]]; then
                    err "--version requires an argument"
                    exit 2
                fi
                shift 2
                ;;
            --prefix)
                prefix="${2:-}"
                if [[ -z "$prefix" ]]; then
                    err "--prefix requires an argument"
                    exit 2
                fi
                prefix_explicit=1
                shift 2
                ;;
            --with-server)
                with_server=1
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    if [[ "$EUID" -eq 0 ]] && [[ $prefix_explicit -eq 0 ]]; then
        err "Refusing to install as root to $prefix"
        echo "Use --prefix (or ZABIN_INSTALL_PREFIX) to explicitly specify an installation directory" >&2
        exit 2
    fi

    local platform
    if ! platform="$(detect_platform)"; then
        exit 1
    fi

    local bindir="$prefix/bin"
    mkdir -p "$bindir"

    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    local download_base
    if [[ -n "$version" ]]; then
        download_base="$base_url/download/$version"
    else
        download_base="$base_url/latest/download"
    fi

    echo "=== Resolving release ==="
    echo "Platform: $platform"
    echo "Base URL: $download_base"

    local sums_file="$tmpdir/SHA256SUMS"
    if ! curl -fsSL "$download_base/SHA256SUMS" -o "$sums_file"; then
        err "Failed to download SHA256SUMS from $download_base"
        exit 1
    fi

    # Build the tarball name we expect ourselves, from the release naming
    # convention plus the platform we just detected (and the requested
    # version, when pinned). We never trust the SHA256SUMS filename field
    # verbatim: an untrusted or corrupted sums file could otherwise name a
    # path like "../x.tar.gz" and smuggle a traversal into the -o path
    # below. Only a version segment is left as a pattern for the "latest"
    # case, and it is restricted to digits/letters/dots/dashes — no slashes.
    local version_segment
    if [[ -n "$version" ]]; then
        version_segment="${version#v}"
    else
        version_segment='[0-9][0-9A-Za-z._-]*'
    fi
    local expected_name_re="zabin-${version_segment}-${platform}\\.tar\\.gz"

    local sums_line_count
    sums_line_count="$(grep -cE "^[0-9a-fA-F]+[[:space:]]+${expected_name_re}\$" "$sums_file" || true)"
    if [[ "$sums_line_count" -eq 0 ]]; then
        err "No release asset for platform $platform found in SHA256SUMS"
        exit 1
    fi
    if [[ "$sums_line_count" -gt 1 ]]; then
        err "Ambiguous SHA256SUMS entries matching platform $platform"
        exit 1
    fi

    local sums_line
    sums_line="$(grep -E "^[0-9a-fA-F]+[[:space:]]+${expected_name_re}\$" "$sums_file")"

    local tarball_name
    tarball_name="$(awk '{print $2}' <<< "$sums_line")"
    # Defense in depth: even though the anchored match above already rules
    # out a name containing a path separator, never let anything derived
    # from file content reach a `curl -o` path without a basename applied.
    tarball_name="$(basename -- "$tarball_name")"

    echo ""
    echo "=== Downloading $tarball_name ==="
    local tarball_path="$tmpdir/$tarball_name"
    if ! curl -fsSL "$download_base/$tarball_name" -o "$tarball_path"; then
        err "Failed to download $tarball_name from $download_base"
        exit 1
    fi

    echo ""
    echo "=== Verifying checksum ==="
    if ! verify_checksum "$tmpdir" "$sums_line"; then
        err "Checksum verification failed for $tarball_name"
        exit 1
    fi
    echo "Checksum OK"

    echo ""
    echo "=== Extracting ==="
    # The tarball wraps its contents in a zabin-<version>-<platform>/ directory;
    # strip that one path component so binaries land directly in $tmpdir.
    tar -xzf "$tarball_path" -C "$tmpdir" --strip-components=1

    local required_binaries=(zabin-tui zabctl)
    if [[ $with_server -eq 1 ]]; then
        required_binaries+=(zabin-server)
    fi

    echo ""
    echo "=== Verifying extracted binaries ==="
    verify_extracted_binaries "$tmpdir" "${required_binaries[@]}"

    # Stage the verified binaries under $tmpdir before touching PREFIX/bin at
    # all. Every binary in required_binaries was just confirmed present and
    # executable, so a missing tarball entry can no longer leave PREFIX/bin
    # with a partial set. The final copy below is still one `install` call
    # per file — not atomic across files as a whole — but it can no longer
    # be interrupted midway by a *missing* binary, only by a lower-level
    # failure (e.g. disk full), which is reported and aborts immediately.
    local stagedir="$tmpdir/stage"
    mkdir -p "$stagedir"
    local name
    for name in "${required_binaries[@]}"; do
        install -m 0755 "$tmpdir/$name" "$stagedir/$name"
    done

    echo ""
    echo "=== Installing to $bindir ==="
    for name in "${required_binaries[@]}"; do
        install -m 0755 "$stagedir/$name" "$bindir/$name"
        echo "Installed: $bindir/$name"
    done

    echo ""
    echo "=== Verifying installation ==="
    for name in "${required_binaries[@]}"; do
        verify_binary "$bindir/$name" "$name"
    done

    echo ""
    check_path "$bindir"

    echo ""
    echo "Installation complete! Installed to: $bindir"
    echo "The PM skill zip is not installed by this script — download"
    echo "zabin-pm-<version>.zip from the release page and upload it as a"
    echo "custom skill (see README.md)."
}

main "$@"
