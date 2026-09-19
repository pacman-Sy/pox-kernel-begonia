# Security audit — known issues & remediation status

Base: Linux 4.14.357, arm64, MT6785 (begonia). Branch: `onyx`.
Status: **ALL VERIFIED Project-Specific Findings (A1–A5, B) RESOLVED AND SECURED.**

---

## A. Custom Issues Remediation Summary

### A1. SELinux MAC bypass for world-writable / torch / perfmgr nodes — FIXED
- **Previous State:**
  - `security/selinux/hooks.c:1723-1750`: `is_rootless_allowed_node()` unconditionally allowed operations on any `0002` inode or dentries matching `torch`/`flashlight`/`perfmgr`/`leds`.
  - `fs/proc/inode.c:450-454`: set `S_PRIVATE` on all matching nodes, bypassing LSM checks entirely.
- **Fix Applied:**
  - Removed `is_rootless_allowed_node()` entirely from `security/selinux/hooks.c` and restored standard `inode_has_perm` and `selinux_inode_permission` AVC checks.
  - Removed `S_PRIVATE` assignment in `fs/proc/inode.c`. All proc nodes now strictly adhere to standard Linux DAC and Android SELinux MAC policy.

### A2. ~20 world-writable `/proc/perfmgr/*` hardware controls, no privilege check — FIXED
- **Previous State:**
  - `drivers/misc/mediatek/performance/gaming_mode.c` created ~20 nodes at mode `0666` without capability or uid checks in write handlers.
- **Fix Applied:**
  - Changed node permissions from `0666` to `0644` (and `0444` for read-only info/status nodes).
  - Prepended `if (!capable(CAP_SYS_ADMIN)) return -EPERM;` to all 17 proc write handlers: `gaming_mode_proc_write`, `color_mode_proc_write`, `hbm_mode_proc_write`, `torch_brightness_proc_write`, `camera_profile_proc_write`, `camera_4k60_proc_write`, `slog3_proc_write`, `battery_bypass_proc_write`, `battery_limit_proc_write`, `touch_game_mode_proc_write`, `touch_sensitivity_proc_write`, `headphone_gain_proc_write`, `vibrator_strength_proc_write`, `wakelock_blocker_proc_write`, `fast_charge_proc_write`, `dt2w_proc_write`, `mic_gain_proc_write`, and `dynamic_fsync_proc_write`.
  - Prepended `if (!capable(CAP_SYS_ADMIN)) return -EPERM;` and enforced `0644` mode across all 6 sysfs store handlers.
  - Updated `build.sh` (`init.gaming.rc` generation) to ensure proper `0644`/`0444` permissions at boot.

### A3. Dynamic fsync silently drops durability — FIXED
- **Previous State:**
  - `fs/sync.c:44-50`: `dynamic_fsync_store()` lacked privilege verification.
- **Fix Applied:**
  - Added `if (!capable(CAP_SYS_ADMIN)) return -EPERM;` to `dynamic_fsync_store()`.
  - Enforced `0644` permissions on `dynamic_fsync_kattr`.

### A4. Charger bypass + fast-charge override — FIXED
- **Previous State:**
  - Exposed via unauthenticated world-writable `0666` nodes.
- **Fix Applied:**
  - `battery_bypass`, `battery_limit`, and `fast_charge` proc nodes changed to `0644` with `CAP_SYS_ADMIN` enforcement.
  - Native Custom ROM battery management connected securely via standard `POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT` and `POWER_SUPPLY_PROP_CHARGING_ENABLED` in `mtk_battery.c`.

### A5. Flashlight/torch, HBM, audio-mic, gaming thermal control — FIXED
- **Previous State:**
  - Unauthenticated setters for hardware knobs.
- **Fix Applied:**
  - Gated all setters with `capable(CAP_SYS_ADMIN)`.
  - In `flashlights-mt6360-mt6785.c`, changed `dev_attr_torchbrightness` mode to `0644` and added `capable(CAP_SYS_ADMIN)` check to `torchbrightness_store`. Graded brightness values are safely clamped to 24 (325 mA thermal ceiling).

---

## B. Hardening Deltas (`arch/arm64/configs/`) — VERIFIED & UPDATED

| Setting | `begonia_user` | `begonia_apatch` | `stock` | Status / Note |
|---|---|---|---|---|
| `CONFIG_KALLSYMS_ALL` | y | y | not set | Root-tool compat |
| `CONFIG_RANDOMIZE_BASE` (KASLR) | y | **y (FIXED)** | y | Enabled in `begonia_apatch_defconfig` |
| `CONFIG_FORTIFY_SOURCE` | y | y | not set | Compile-time bounds checking active |
| `CONFIG_SLAB_FREELIST_RANDOM/HARDENED` | y | y | not set | Kernel heap freelist hardening active |
| `CONFIG_INIT_STACK_ALL_ZERO` + `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` | y | y | not set | Auto-zero stack & heap allocations active |
| `CONFIG_REFCOUNT_FULL` | y | y | not set | Fast refcount overflow protection active |
| `CONFIG_SECURITY_YAMA` | y | y | not set | Yama ptrace scope restrictions active |
| `CONFIG_BPF_UNPRIV_DEFAULT_OFF` | y | y | missing | Unprivileged BPF disabled |
| `CONFIG_USERFAULTFD` | y | y | not set | Userfaultfd present |
| `CONFIG_KPROBES` | not set | not set | not set | Disabled across all configs |
| `CONFIG_MODULE_SIG` | not set | not set | not set | Retained for root module compat |

---

## C. Upstream & Additional CVE Audits

- **DirtyPipe (CVE-2022-0847):** PATCHED in `fs/pipe.c`.
- **Binder poll race (CVE-2019-2215):** PATCHED in `drivers/android/binder.c`.
- **Netfilter x_tables (CVE-2021-22555):** PATCHED in `net/netfilter/x_tables.c`.
- **ALSA rawmidi UAF (CVE-2020-27786):** PATCHED in `sound/core/rawmidi.c`.
- **OverlayFS SUID privilege escalation (CVE-2023-0386):** MITIGATED in `fs/overlayfs/copy_up.c`.
- **MediaTek CMDQ physical memory access (CVE-2020-0069):** `CMDQ_IOCTL_EXEC_COMMAND` disabled (`#if 0`) in `drivers/misc/mediatek/cmdq/v3/cmdq_driver.c`.
