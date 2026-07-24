#!/usr/bin/env bats
#
# Unit tests for build_kernel.sh.
#
# The script is sourced (its `main` invocation is guarded) so individual
# functions can be exercised in isolation. External commands that touch the
# network or the real build (git, curl, ...) are replaced with stubs; the
# deterministic text-transformation logic runs for real against fixture files.

load test_helper

setup() {
    load_script
    setup_stub_bin
}

teardown() {
    teardown_tmp
    [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
}

# --------------------------------------------------------------------------
# logging helpers
# --------------------------------------------------------------------------

@test "log prints the [+] prefix and the message" {
    run log "hello world"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[+]"
    assert_contains "$output" "hello world"
}

@test "err prints the [x] prefix and exits non-zero" {
    run err "boom"
    [ "$status" -eq 1 ]
    assert_contains "$output" "[x]"
    assert_contains "$output" "boom"
}

# --------------------------------------------------------------------------
# download_kernel_source
# --------------------------------------------------------------------------

@test "download_kernel_source is a no-op when the kernel Makefile already exists" {
    mkdir -p "$KERNEL_DIR"
    touch "$KERNEL_DIR/Makefile"
    # A git stub that would fail loudly if it were called.
    make_stub git 'echo "git-was-called $*" >> "$STUB_LOG"; exit 3'

    run download_kernel_source
    [ "$status" -eq 0 ]
    refute_contains "$(cat "$STUB_LOG")" "git-was-called"
}

@test "download_kernel_source clones the A04 kernel source when missing" {
    rm -rf "$KERNEL_DIR"
    make_stub git 'echo "clone $*" >> "$STUB_LOG"'

    run download_kernel_source
    [ "$status" -eq 0 ]
    log_contents="$(cat "$STUB_LOG")"
    assert_contains "$log_contents" "clone"
    assert_contains "$log_contents" "android_kernel_samsung_a04m.git"
}

# --------------------------------------------------------------------------
# apply_419_compat_patches
# --------------------------------------------------------------------------

@test "apply_419_compat_patches rewrites access_ok, MODULE_IMPORT_NS and pgtable include in C sources" {
    local d="$TEST_TMP/tree"
    mkdir -p "$d"
    cat > "$d/foo.c" <<'EOF'
#include <linux/pgtable.h>
MODULE_IMPORT_NS(VFS_internal);
if (access_ok(ptr)) { do_thing(); }
EOF

    run apply_419_compat_patches "$d"
    [ "$status" -eq 0 ]

    local result
    result="$(cat "$d/foo.c")"
    assert_contains "$result" "access_ok(0, ptr)"
    assert_contains "$result" "#include <linux/mm.h>"
    refute_contains "$result" "#include <linux/pgtable.h>"
    refute_contains "$result" "MODULE_IMPORT_NS"
}

@test "apply_419_compat_patches applies to .h headers too" {
    local d="$TEST_TMP/tree"
    mkdir -p "$d"
    printf 'if (access_ok(x)) return;\n' > "$d/bar.h"

    run apply_419_compat_patches "$d"
    [ "$status" -eq 0 ]
    assert_contains "$(cat "$d/bar.h")" "access_ok(0, x)"
}

@test "apply_419_compat_patches leaves non C/H files untouched" {
    local d="$TEST_TMP/tree"
    mkdir -p "$d"
    printf 'access_ok(x)\n' > "$d/README.md"

    run apply_419_compat_patches "$d"
    [ "$status" -eq 0 ]
    assert_contains "$(cat "$d/README.md")" "access_ok(x)"
    refute_contains "$(cat "$d/README.md")" "access_ok(0, x)"
}

@test "apply_419_compat_patches succeeds on an empty directory" {
    local d="$TEST_TMP/empty"
    mkdir -p "$d"
    run apply_419_compat_patches "$d"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# patch_file_wrapper
# --------------------------------------------------------------------------

@test "patch_file_wrapper comments out iopoll/remap and stubs wrapper symbols" {
    local f="$TEST_TMP/file_wrapper.c"
    cat > "$f" <<'EOF'
struct file_operations ksu_fops = {
    .iopoll = ksu_wrapper_iopoll,
    .remap_file_range = ksu_wrapper_remap_file_range,
};
int flags = REMAP_FILE_DEDUP;
EOF

    run patch_file_wrapper "$f"
    [ "$status" -eq 0 ]

    local result
    result="$(cat "$f")"
    # version.h is prepended.
    [ "$(head -n1 "$f")" = "#include <linux/version.h>" ]
    assert_contains "$result" "// .iopoll ="
    assert_contains "$result" "// .remap_file_range ="
    assert_contains "$result" "flags = 0;"
    refute_contains "$result" "REMAP_FILE_DEDUP"
    refute_contains "$result" "ksu_wrapper_iopoll"
    refute_contains "$result" "ksu_wrapper_remap_file_range"
}

@test "patch_file_wrapper does not add the version include twice" {
    local f="$TEST_TMP/file_wrapper.c"
    printf '#include <linux/version.h>\nint x;\n' > "$f"

    run patch_file_wrapper "$f"
    [ "$status" -eq 0 ]
    local count
    count="$(grep -c 'linux/version.h' "$f")"
    [ "$count" -eq 1 ]
}

@test "patch_file_wrapper is a no-op when the file is absent" {
    run patch_file_wrapper "$TEST_TMP/does_not_exist.c"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# sourcing guard
# --------------------------------------------------------------------------

@test "sourcing the script does not trigger a build" {
    run bash -c "source '$SCRIPT_UNDER_TEST'; echo SOURCED_OK"
    [ "$status" -eq 0 ]
    assert_contains "$output" "SOURCED_OK"
    refute_contains "$output" "Cloning Samsung Galaxy A04 kernel source"
    refute_contains "$output" "Integrating SUSFS"
}

@test "main is defined after sourcing" {
    run declare -F main
    [ "$status" -eq 0 ]
}
