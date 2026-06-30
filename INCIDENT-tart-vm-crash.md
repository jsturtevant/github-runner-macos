# Incident Report: Ephemeral Tart Runner Crashes (`VZErrorDomain Code=1`)

**Date:** 2026-06-29
**Host:** Simons-Mac-mini — `Mac16,10` (Apple M4)
**OS:** macOS 26.5.1 (build 25F80)
**Virtualization framework:** `com.apple.Virtualization.VirtualMachine` build 259.6.4
**Affected fleet:** `com.github.tart-runner-*` (Ubuntu 24.04 + nested KVM ephemeral runners)
**Status (2026-06-30):** Mitigated. Running a **single** runner (8 vCPU / 8 GB)
has been **crash-free for ~12 h** under real CI load. The underlying Apple
hypervisor bug is unfixed; the mitigation avoids the concurrency that triggers it.

---

## 1. Symptom

CI jobs running on the Tart/Ubuntu KVM runners fail intermittently. In the
GitHub Actions job log the only visible error is:

```
guest has stopped the virtual machine due to error: Error Domain=VZErrorDomain
Code=1 "The virtual machine stopped unexpectedly."
UserInfo={NSLocalizedFailure=Internal Virtualization error.,
NSLocalizedFailureReason=The virtual machine stopped unexpectedly.}
```

On the host side the runner loop observes the guest SSH session dying mid-job:

```
Read from remote host 192.168.64.x: Operation timed out
client_loop: send disconnect: Broken pipe
[runner N] Runner exited non-zero (job may have failed)
```

The job is `run-examples (kvm, apple, arm64, debug)` — a workload that uses
**nested virtualization** (`/dev/kvm`) inside the guest.

---

## 2. Root Cause

This is **not** a runner-script, configuration, networking, or resource
problem. The **host-side Apple Virtualization VM process aborts on an internal
Hypervisor assertion**, which instantly tears down the guest. The dead guest is
what the runner sees as an SSH timeout, and what GitHub reports as
`VZErrorDomain Code=1`.

The crash was captured from `~/Library/Logs/DiagnosticReports/
com.apple.Virtualization.VirtualMachine-*.ips`. The faulting thread backtrace:

```
EXC_BREAKPOINT (SIGTRAP) — "assertion failed" (libsystem_c)
Base::assertion_trap()
  └ HvCore::Hypervisor::VcpuStateManager::set_pstate(Base::Bitfield<Arm::Pstate>)
    └ HvCore::Hypervisor::VcpuStateManager::handle_exception_exit(Base::Bitfield<Arm::EsrElx>, …)
      └ Hv::Vcpu::handle_exception_exit()
        └ Hv::Vcpu::run()
        └ (com.apple.Virtualization.VirtualMachine worker thread)
```

Key facts:

- Crashing process is **Apple's `Virtualization.framework` XPC service**, not
  Tart and not our scripts.
- The crash coalition is `com.github.tart-runner-3`, confirming it is one of our
  runner VMs.
- The assertion fires in `set_pstate` during a **vCPU exception exit** — the
  code path exercised by **nested virtualization** (the guest running KVM).

### Consistency

The signature is **identical across every captured crash report** on this host
(`EXC_BREAKPOINT` / `assertion failed` / `set_pstate` → `handle_exception_exit`
→ `Hv::Vcpu::run`). This is a single, reproducible defect — not random
instability.

> Note on counting: macOS **throttles duplicate `.ips` crash reports** for the
> same process, so the number of `.ips` files **understates** the real crash
> count. Use the **runner logs** (`VZErrorDomain` / `Iteration failed` lines in
> `~/.github-runner-logs/tart-runner-N-stderr.log`) as the authoritative signal.

---

## 3. Conclusion

This is an **Apple Hypervisor / Virtualization.framework bug** in the
nested-virtualization vCPU PSTATE handling path on M4 + macOS 26.5.1. Because
the failing assertion is inside Apple's closed-source hypervisor, it **cannot be
fixed from our scripts or Tart configuration**. We can only avoid triggering it,
and report it to Apple.

**Empirical finding (see §4): the trigger is the _number of concurrent nested
VMs_, not per-guest vCPU count.** A single runner has been stable; adding a
second brings the crash back even at 1 vCPU. The working mitigation is therefore
to run **one** nested-virt runner on this host — and because vCPU count is *not*
the trigger, that single runner can be given many vCPUs for speed.

---

## 4. Experiments and results

All on M4 / macOS 26.5.1 under nested-KVM CI load (Hyperlight). Crash counts are
from the **runner logs** (see the throttling note in §2).

| Config (runners × vCPU / RAM) | Result |
| --- | --- |
| 3 × 4 vCPU / 8 GB | Frequent crashes (peak ~10/hr) |
| 2 × 2 vCPU / 4 GB | Crashes |
| 2 × 1 vCPU / 5 GB | Crashed within ~20 min |
| 1 × 2 vCPU / 5 GB | ~1.5 h crash-free |
| **1 × 8 vCPU / 8 GB** | **~12 h crash-free under real CI load ✅ (current)** |

**Conclusion:** crashes track the number of **concurrent nested VMs**, not the
per-guest vCPU count (2×1 crashed; 1×8 did not). A **single runner is the stable
configuration**, and it can be sized large (8 vCPU / 8 GB on this 10-core /
16 GB host) for throughput. This is a **mitigation, not a fix** — the Apple
hypervisor bug remains; one runner simply avoids the concurrency that triggers
it. True parallelism without the crash needs additional physical Macs or real
arm64 Linux/KVM hardware.

---

## 5. Recommendations

### A. Mitigations to reduce crash frequency (do now)

1. **Reduce runner concurrency.**
   Running 3 nested-virt VMs simultaneously sharply increases how often the
   hypervisor assert fires. Drop to a single runner and measure:

   ```bash
   sudo env TART_RUNNER_DEBUG=0 TART_KEEP_FAILED_VM=1 \
     bash bootstrap-tart-runners.sh --count 1 --org hyperlight-dev \
       --app-id 1272749 \
       --private-key /Users/simon/.config/github-runner-tart/app.private-key.pem \
       --install-launchd --launchd-scope daemon --launchd-user simon
   ```

2. **Do not bother lowering vCPU — it is not the trigger.**
   Tested: 2 × 1 vCPU still crashed, while 1 × 8 vCPU stayed crash-free. vCPU
   count does not drive the crash, so keep the single runner sized large for
   speed:

   ```bash
   tart set gha-ubuntu-kvm --cpu 8 --memory 8192
   ```

3. **Keep diagnostics on while validating.**
   `TART_KEEP_FAILED_VM=1` retains the failed clone for inspection; the runner
   loop already writes per-crash host diagnostics to
   `~/.github-runner-logs/tart-runner-N-vm-diagnostics.log`.

### B. Reporting to Apple (do this — it is the only real fix)

4. **File Feedback Assistant** with one of the `.ips` crash reports attached
   (e.g. `com.apple.Virtualization.VirtualMachine-2026-06-29-162417.ips`).
   Emphasize: assertion in `HvCore::Hypervisor::VcpuStateManager::set_pstate`
   during `handle_exception_exit`, reproducible with nested virtualization
   (Linux guest running KVM) on M4 / macOS 26.5.1.

5. **Track macOS + Tart updates.** The fix must come from an Apple
   Virtualization/Hypervisor update. Re-test on each new macOS build.

### C. Operational resilience (already in place / optional)

6. The runner loop already **self-heals**: on crash it tears down the clone and
   starts a fresh ephemeral runner, so the fleet recovers without intervention.
   The crashed *job* still fails in GitHub (the ephemeral runner had already
   claimed it), so consider **job-level retries** in critical workflows.

7. If nested-virt jobs are business-critical and the crash rate stays high at
   `--count 1 --cpus 2`, consider running those specific jobs on **dedicated
   bare-metal Linux/KVM** hardware until Apple resolves the hypervisor bug, and
   reserve the Mac KVM runners for lighter nested workloads.

---

## 6. How to reproduce / monitor

Watch all runners and auto-capture a snapshot on the next crash:

```bash
./monitor-tart-debug.sh auto all 200
```

After a crash, the per-runner host diagnostics (including the Hypervisor crash
excerpt) are in:

```bash
tail -n 200 ~/.github-runner-logs/tart-runner-1-vm-diagnostics.log
```

Summarize the crash signature across all captured reports:

```bash
ls ~/Library/Logs/DiagnosticReports/com.apple.Virtualization.VirtualMachine-*.ips
```

---

## 7. Update log

### 2026-06-30 — macOS 26.5.2 (25F84): **not fixed**

Updated `26.5.1 (25F80)` → `26.5.2 (25F84)` and compared a binary fingerprint of
the crash path before/after with `hv-fingerprint.sh` (disassembles the two
crashing functions from `Hypervisor.framework` in the dyld shared cache,
normalizes out load addresses, and hashes them).

**Result: the relevant binaries are byte-for-byte identical** — 26.5.2 did not
touch `Virtualization.framework` or `Hypervisor.framework`:

| Component | 25F80 | 25F84 |
| --- | --- | --- |
| Virtualization XPC CDHash | `99d2e87f…0373` | identical |
| Hypervisor.framework UUID | `5ACE59BA-…B6A6` | identical |
| `set_pstate` (normalized) | `dd6e64ea…72f6` (461 insns, 4 trap sites) | identical |
| `handle_exception_exit` (normalized) | `15dd4abc…21fc` (847 insns, 4 trap sites) | identical |

Snapshots: `hv-fingerprint/25F80-*` and `hv-fingerprint/25F84-*`. Conclusion: the
assertion-bearing code is unchanged, so the bug persists. The
single-runner mitigation remains in place. Next real levers are unchanged: file
Feedback Assistant, watch future macOS builds (re-run the fingerprint compare on
each), or move nested-KVM jobs to real arm64 Linux/KVM hardware.
