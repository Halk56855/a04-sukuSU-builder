#!/bin/bash
# ==============================================================================
# Shared build utilities for the Samsung Galaxy A04 SukiSU-Ultra kernel builder.
#
# Source this file from both build_kernel.sh and the CI workflow so that the
# repeated git-clone, source-patching and toolchain-download patterns live in a
# single place:
#
#     source "path/to/scripts/lib.sh"
# ==============================================================================

# --- Logging ------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }
err() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# --- Git ----------------------------------------------------------------------
# clone_shallow <url> <dest> [branch]
# Shallow-clone a repository, optionally from a specific branch.
clone_shallow() {
    local url="$1" dest="$2" branch="${3:-}"
    if [ -n "$branch" ]; then
        git clone --depth=1 -b "$branch" "$url" "$dest"
    else
        git clone --depth=1 "$url" "$dest"
    fi
}

# --- Source patching ----------------------------------------------------------
# sed_c_h <dir> <sed-expression>
# Apply an in-place sed expression to every *.c / *.h file under <dir>.
sed_c_h() {
    local dir="$1" expr="$2"
    find "$dir" -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i "$expr" {} +
}

# --- Toolchain downloads ------------------------------------------------------
# fetch_tar <dest> <url> [fallback-url...]
# Download and extract a gzip tarball into <dest>, trying each URL in turn until
# one downloads and extracts successfully.
fetch_tar() {
    local dest="$1"; shift
    mkdir -p "$dest"
    local url tmp
    tmp="$(mktemp)"
    for url in "$@"; do
        if curl -L -o "$tmp" "$url" && tar -xzf "$tmp" -C "$dest" 2>/dev/null; then
            rm -f "$tmp"
            return 0
        fi
    done
    rm -f "$tmp"
    return 1
}
