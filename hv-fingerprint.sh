#!/bin/bash
#
# hv-fingerprint.sh — Capture a comparable fingerprint of the Apple hypervisor
# components implicated in the nested-virt VM crash (see INCIDENT-tart-vm-crash.md),
# so we can tell whether a macOS update actually changed the crashing code.
#
# What it captures, into ./hv-fingerprint/<build>-<timestamp>/:
#   - macOS product version + build
#   - Virtualization XPC binary: cdhash + LC_UUID (it is a real file on disk)
#   - Hypervisor.framework image UUID (lives in the dyld shared cache)
#   - Disassembly of the two crashing functions, normalized for comparison:
#         HvCore::Hypervisor::VcpuStateManager::set_pstate
#         HvCore::Hypervisor::VcpuStateManager::handle_exception_exit
#
# The disassembly is normalized by stripping the (ASLR-varying) load-address
# column and masking absolute hex operands, keeping the function-relative
# <+offset> + mnemonic + register/immediate operands. That yields a stable
# sha256 + instruction count: if these match before vs after an update, the
# function's machine code is effectively unchanged → the bug is almost certainly
# NOT fixed. If they differ, Apple modified that exact code path.
#
# Usage:
#   bash hv-fingerprint.sh                 # capture a snapshot
#   bash hv-fingerprint.sh --compare A B   # diff two snapshot directories

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="${SCRIPT_DIR}/hv-fingerprint"

XPC_BIN="/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
HV_DYLIB="/System/Library/Frameworks/Hypervisor.framework/Hypervisor"
FUNCS=(set_pstate handle_exception_exit)

# Reduce a raw lldb disassembly to a stable, address-independent form.
normalize_disasm() {
    # Keep only instruction lines, drop everything up to and including "<+N>:",
    # mask absolute hex addresses, strip "; ..." comments, squeeze whitespace.
    grep -E '<\+[0-9]+>:' \
        | sed -E 's/.*<\+[0-9]+>:[[:space:]]*//; s/0x[0-9a-fA-F]+/0xX/g; s/[[:space:]]*;.*$//; s/[[:space:]]+/ /g; s/[[:space:]]*$//'
}

do_capture() {
    local build ver ts outdir fphost
    ver="$(sw_vers -productVersion)"
    build="$(sw_vers -buildVersion)"
    ts="$(date +%Y%m%d-%H%M%S)"
    outdir="${OUT_ROOT}/${build}-${ts}"
    mkdir -p "$outdir"

    echo "Capturing hypervisor fingerprint -> $outdir"

    # Debuggable stub so lldb can attach (system binaries are SIP-restricted).
    fphost="$(mktemp -d)/fphost"
    printf '#include <unistd.h>\nint main(void){ pause(); return 0; }\n' > "${fphost}.c"
    clang -o "$fphost" "${fphost}.c"

    {
        echo "captured_at: $(date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "macos_version: $ver"
        echo "macos_build: $build"
        echo ""
        echo "== Virtualization XPC binary =="
        echo "path: $XPC_BIN"
        codesign -dvvv "$XPC_BIN" 2>&1 | grep -iE 'cdhash|identifier|version' || true
        dwarfdump --uuid "$XPC_BIN" 2>/dev/null | awk '{print "uuid: "$2}' || true
    } > "$outdir/summary.txt"

    # Disassemble each crashing function in its own focused lldb run (system
    # binaries are SIP-restricted, so we attach to the compiled stub and dlopen
    # Hypervisor into it). Each run also dumps `image list Hypervisor` so we can
    # record the framework UUID once.
    local hv_uuid=""
    echo "" >> "$outdir/summary.txt"
    echo "== Crashing functions (normalized) ==" >> "$outdir/summary.txt"
    local f
    for f in "${FUNCS[@]}"; do
        local fn_raw="$outdir/${f}.raw.txt"
        lldb -b \
            -o "target create $fphost" -o 'breakpoint set -n main' -o 'run' \
            -o "expr -- (void*)dlopen(\"$HV_DYLIB\", 2)" \
            -o 'image list Hypervisor' \
            -o "disassemble -n $f" -o 'quit' > "$fn_raw" 2>&1 || true

        if [ -z "$hv_uuid" ]; then
            hv_uuid="$(grep -E '/System/Library/Frameworks/Hypervisor.framework' "$fn_raw" \
                | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
                | sed -n '1p' || true)"
        fi

        local fn_norm="$outdir/${f}.norm.txt"
        normalize_disasm < "$fn_raw" > "$fn_norm"

        # Control-flow + call sites with resolved symbol comments PRESERVED
        # (only numeric addresses masked). This keeps WHICH functions are
        # called — crucially the `; ...assertion_trap` site and its guarding
        # branch — which is the key evidence for judging whether a change targets
        # our specific assertion bug.
        local fn_calls="$outdir/${f}.calls.txt"
        grep -E '<\+[0-9]+>:' "$fn_raw" \
            | sed -E 's/.*<\+[0-9]+>:[[:space:]]*//' \
            | grep -E '^(bl|b|b\.[a-z]+|cbn?z|tbn?z|brk|udf|ret)\b' \
            | sed -E 's/0x[0-9a-fA-F]+/0xX/g; s/[[:space:]]+/ /g; s/[[:space:]]*$//' \
            > "$fn_calls" || true

        local count hash traps
        count="$(wc -l < "$fn_norm" | tr -d ' ')"
        hash="$(shasum -a 256 "$fn_norm" | awk '{print $1}')"
        traps="$(grep -cE 'assertion_trap|__assert|brk|udf|panic' "$fn_calls" 2>/dev/null || true)"
        printf '%-22s insns=%-5s traps=%-3s sha256=%s\n' "$f" "$count" "${traps:-0}" "$hash" >> "$outdir/summary.txt"
    done

    {
        echo ""
        echo "== Hypervisor.framework =="
        echo "uuid: ${hv_uuid:-unknown}"
    } >> "$outdir/summary.txt"

    rm -rf "$(dirname "$fphost")"

    echo ""
    cat "$outdir/summary.txt"
    echo ""
    echo "Snapshot saved: $outdir"
}

do_compare() {
    local a="$1" b="$2" f
    echo "Comparing:"
    echo "  A = $a"
    echo "  B = $b"
    echo ""
    echo "== summary diff =="
    diff -u "$a/summary.txt" "$b/summary.txt" || true
    echo ""
    for f in "${FUNCS[@]}"; do
        echo "== $f =="
        if cmp -s "$a/${f}.norm.txt" "$b/${f}.norm.txt"; then
            echo "  IDENTICAL — machine code unchanged (bug almost certainly NOT fixed)"
        else
            echo "  CHANGED — Apple modified this function."
            local ta tb
            ta="$(grep -cE 'assertion_trap|__assert|brk|udf' "$a/${f}.calls.txt" 2>/dev/null || true)"
            tb="$(grep -cE 'assertion_trap|__assert|brk|udf' "$b/${f}.calls.txt" 2>/dev/null || true)"
            echo "  assertion/trap sites:  before=${ta:-0}  after=${tb:-0}"
            if [ "${ta:-0}" != "${tb:-0}" ]; then
                echo "  >>> trap-site COUNT changed — a targeted fix to the assertion path is PLAUSIBLE"
            else
                echo "  (trap-site count unchanged — change may be unrelated to our assertion; verify empirically)"
            fi
            echo "  --- control-flow / call-site diff (symbols kept) ---"
            diff -u "$a/${f}.calls.txt" "$b/${f}.calls.txt" | sed -n '1,50p' || true
            echo "  --- normalized instruction diff (first 40 lines) ---"
            diff -u "$a/${f}.norm.txt" "$b/${f}.norm.txt" | sed -n '1,40p' || true
        fi
        echo ""
    done
}

main() {
    if [ "${1:-}" = "--compare" ]; then
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: $0 --compare <dirA> <dirB>" >&2; exit 1; }
        do_compare "$2" "$3"
    else
        do_capture
    fi
}

main "$@"
