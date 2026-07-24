# Shared helpers for build_kernel.sh Bats tests.
#
# SC2034: WORK_DIR/KERNEL_DIR/etc. are consumed by the sourced script's
# functions, not by this helper directly.
# shellcheck disable=SC2034

# Absolute path to the repository root (parent of the tests/ directory).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="${REPO_ROOT}/build_kernel.sh"

# Source the script under test and point all of its work directories at a
# throwaway temp dir. The script guards `main`, so sourcing only defines the
# functions without kicking off a real build.
load_script() {
    # shellcheck disable=SC1090
    source "$SCRIPT_UNDER_TEST"

    # Relax the strict flags the script enables at the top so that assertions
    # in the test body are not aborted by a single non-zero command.
    set +e +u +o pipefail

    TEST_TMP="$(mktemp -d)"
    WORK_DIR="$TEST_TMP"
    KERNEL_DIR="$TEST_TMP/kernel"
    OUTPUT_DIR="$TEST_TMP/output"
    TOOLCHAIN_DIR="$TEST_TMP/toolchains"
}

teardown_tmp() {
    [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Create an isolated directory of stub executables and prepend it to PATH.
# Usage: make_stub git 'echo "$@" >> "$STUB_LOG"'
setup_stub_bin() {
    STUB_BIN="$(mktemp -d)"
    STUB_LOG="${STUB_BIN}/.calls.log"
    : > "$STUB_LOG"
    PATH="${STUB_BIN}:${PATH}"
}

make_stub() {
    local name="$1" body="$2"
    cat > "${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
STUB_LOG="${STUB_LOG}"
${body}
EOF
    chmod +x "${STUB_BIN}/${name}"
}

assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected to find: $needle" >&2
        echo "in: $haystack" >&2
        return 1
    fi
}

refute_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "did not expect to find: $needle" >&2
        echo "in: $haystack" >&2
        return 1
    fi
}
