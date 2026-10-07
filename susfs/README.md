# SUSFS for APatch (susfs4ksu port)

Kernel level root hiding for the APatch flavour of this kernel.

SUSFS upstream lives at <https://gitlab.com/simonpunk/susfs4ksu>.  It is a set of
kernel patches (`fs/susfs.c` plus hunks in `fs/`, `security/selinux/`, ...) that
make root's artefacts invisible to ordinary apps: paths disappear from `stat()`
and directory listings, root's mounts disappear from `/proc/*/mountinfo`, mmapped
root files disappear from `/proc/*/maps`, inode numbers and timestamps of
replaced files can be spoofed, and so on.

Upstream SUSFS is built *around* the KernelSU driver: it expects KernelSU to hand
it four things.  This kernel is built for APatch, whose kernel side is the
prebuilt KernelPatch blob injected into `boot.img` - there is no KernelSU source
here at all.  This directory contains the port:

| what SUSFS needs from its host | APatch port |
| --- | --- |
| `susfs_is_current_ksu_domain()` | SELinux SID lookup of APatch's root contexts (`security/selinux/susfs_apatch.c`) |
| `susfs_is_current_zygote_domain()` | SELinux SID lookup of `u:r:zygote:s0` |
| `setup_selinux()`, `ksu_cred` | built here, using the APatch root context |
| `reboot(2)` command channel (`CMD_SUSFS_*`) | handled at the top of `SYSCALL_DEFINE4(reboot)` in `kernel/reboot.c` |
| `TIF_PROC_*` per process flags | maintained from `commit_creds()` (`kernel/cred.c`) |

Because the command channel is bit-for-bit the KernelSU protocol, the **stock
susfs4ksu `ksu_susfs` userspace tool is used unmodified** - there is no forked
tool to keep in sync.

One caveat: it must be a tool from a branch that speaks **v2**; the module's
`ksu_susfs.url` points at `gki-android15-6.6`.  Upstream freezes `master` at
susfs **1.3.8**, whose tool has no `show` subcommand and takes a five argument
`set_uname <sysname> <nodename> <release> <version> <machine>`.  Pointed at this
kernel it just prints its usage text and does nothing - the module detects that
and tells you, instead of pretending it applied your config.

## Kernel configuration

Enabled in `arch/arm64/configs/begonia_apatch_defconfig`:

```
CONFIG_KSU_SUSFS=y                      # fs/susfs.c + the APatch glue
CONFIG_KSU_SUSFS_SUS_PATH=y            # hide paths from stat/open/getdents
CONFIG_KSU_SUSFS_SUS_MOUNT=y           # hide root's mounts from /proc/*/mount*
CONFIG_KSU_SUSFS_SUS_KSTAT=y           # spoof stat() of replaced files
CONFIG_KSU_SUSFS_SPOOF_UNAME=y         # spoof uname()
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y       # redirect opens of a path to another one
CONFIG_KSU_SUSFS_SUS_MAP=y             # hide mmapped files from proc maps
CONFIG_KSU_SUSFS_ENABLE_LOG=y
# CONFIG_KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING is not set
```

The symbols keep their upstream `CONFIG_KSU_SUSFS_*` names on purpose: the SUSFS
sources and kernel hunks are used verbatim, so upstream updates apply without a
rename pass.  The menu lives in `fs/susfs_apatch.Kconfig`.

APatch specific options:

| option | default | meaning |
| --- | --- | --- |
| `SUSFS_APATCH_SU_DOMAINS` | `u:r:magisk:s0 u:r:su:s0` | contexts that count as "root".  APatch's su shell and `apd` (which performs the module mounts) run in `u:r:magisk:s0`, see `MAGISK_SCTX` in KernelPatch's `kernel/patch/android/userd.c` |
| `SUSFS_APATCH_ZYGOTE_DOMAIN` | `u:r:zygote:s0` | used to hand out believable mount ids to zygote-spawned processes |
| `SUSFS_APATCH_HIDE_UID_MIN` | `10000` | lowest uid (modulo the per-user range) treated as an ordinary app |

If the root context is changed inside APatch, it has to be listed in
`SUSFS_APATCH_SU_DOMAINS`, otherwise SUSFS cannot tell root's mounts from system
mounts and no mount is hidden.  `dmesg` then contains
`susfs-apatch: cannot resolve '...'`.

## How the pieces line up

* **Which mounts are hidden.**  `fs/namespace.c` (SUSFS) gives every mount that
  is created from the APatch root context an `mnt_id` from the `2000000000`
  range, and `fs/proc_namespace.c` skips those ids when it prints
  `/proc/<pid>/{mounts,mountinfo,stat,statfs}`.  No userspace configuration is
  needed: everything `apd` mounts disappears from those files automatically.
  Note that in this v2.3.0 port that filter is **unconditional** - it tests the
  mount id only, with no per-process check - so those entries are absent for
  every process, su shells included.  (It also makes
  `hide_sus_mnts_for_non_su_procs` a no-op here: `fs/susfs.c` records the
  toggle and never consults it.)
* **Which processes are "no su".**  This governs the *file* hiding - `sus_path`,
  `sus_kstat`, `open_redirect`, `sus_map` - and it runs from `commit_creds()`,
  so zygote dropping a child to its app uid, an app calling `setuid()`, and
  APatch's `commit_su()` granting root are all covered, in both directions.  uid
  0 therefore still sees `/data/adb/modules`, an ordinary app does not.  `adb`
  and system services (uid < 10000) also see it, which is intentional:
  breaking them would break the system.
* **Command channel.**  `ksu_susfs` calls
  `reboot(0xDEADBEEF, 0xFAFAFAFA, CMD_SUSFS_*, &info)` as root; the magic pair is
  answered at the very top of `SYSCALL_DEFINE4(reboot)` and never reaches the
  real reboot path.  APatch/KernelPatch hijacks syscall 45 for its own supercall
  and does not touch `reboot(2)`, so the two do not collide.

## User interface

The module ships a `webroot/`, so APatch shows a WebUI button on the module in
the manager (APatch serves `/data/adb/modules/<id>/webroot` and injects the same
`window.ksu` bridge KernelSU does - `exec()` runs in a root shell and returns
stdout).  Two variants are published:

| zip | UI | notes |
| --- | --- | --- |
| `susfs_apatch-module.zip` | native, this repo | tabs for status, `sus_path`, `sus_kstat`, `sus_map`, `open_redirect`, uname/cmdline spoofing, toggles and logs; edits `conf/` |
| `susfs_apatch-module-upstream.zip` | the community UI from [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) | path literals rewritten from KernelSU to this module; sections that need kernel features we do not build (`legit_mounts`, `try_umount`, sus_su) are inert |

`./susfs/package.sh build` builds both.  The upstream variant is wired up by
`susfs/module/compat.sh`, which is a no-op unless the `UPSTREAM_UI` marker is
present:

* imports the upstream root-level lists (`sus_path.txt`, `sus_maps.txt`,
  `sus_open_redirect.txt`, `sus_path_loop.txt`, `sus_mount.txt`) into `conf/`
* applies `sus_kstat_statically.json` through the same awk parsing upstream uses
* writes the snapshot/log files that UI reads (`dmesg.log`, `logs/susfs.log`,
  `pid1_mountinfo.txt`, `zygote64_maps.txt`, `ksu_module_list.txt`, ...)

The UI is only a front end: every change it saves is applied by running the
tool, because the kernel state lives in memory and nothing happens until the
tool is invoked.

## Userspace

`susfs/module` is an APatch module (Magisk layout) that runs the tool at the
right stages:

```
conf/sus_path.txt        paths hidden from apps (stat, open, getdents, ...)
conf/sus_kstat.txt       files whose stat should be spoofed
conf/sus_map.txt         files hidden from /proc/<pid>/maps|smaps|map_files
conf/open_redirect.txt   <target> <redirected> <uid_scheme>
conf/uname.txt           <release>|<version>
conf/fake_cmdline.txt    copy of /proc/cmdline with the values you want to hide
conf/enable_log.txt      1 = verbose SUSFS logging in dmesg
```

`customize.sh` downloads the stock `ksu_susfs` arm64 binary on install (URL in
`ksu_susfs.url`).

Stock Android has no `curl`, and APatch's installer environment has no `wget`
either - it ships its own busybox at `/data/adb/ap/bin/busybox`, which the
installer falls back to.  If that download is blocked (no network at first
boot, captive portal, ...), the module keeps looking for the tool in these
places, so you can always supply it by hand:

```sh
# on your PC
curl -LO https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android15-6.6/ksu_module_susfs/tools/ksu_susfs_arm64
adb push ksu_susfs_arm64 /data/local/tmp/ksu_susfs
```

then tap Action again - no reboot needed.  Search order:
`${MODDIR}/tools/ksu_susfs`, `/data/adb/ap/bin/ksu_susfs`,
`/data/adb/ksu/bin/ksu_susfs`, `/data/local/tmp/ksu_susfs`.

### Where the output goes

APatch runs a module script as `busybox sh <script>` with its cwd set to the
module directory, exports only `AP_MODULE`/`APATCH`/`PATH` (**no `MODDIR`**), and
shows nothing from the Action button in the UI.  Every message the module emits
therefore goes to three places:

* `stdout` -> apd's logcat (`logcat | grep susfs`)
* `/data/adb/modules/susfs_apatch/susfs.log` (capped at 64 KiB)
* `/dev/kmsg`, so `dmesg | grep susfs` works too

### Troubleshooting "the Action button does nothing"

`action.sh` prints the whole state; read it from the log file:

```sh
su -c 'cat /data/adb/modules/susfs_apatch/susfs.log'
su -c 'logcat -d | grep susfs'
```

The three states it can end in:

| log says | meaning | fix |
| --- | --- | --- |
| `tool=MISSING` | `ksu_susfs` was not downloaded | put the arm64 binary in `/data/adb/modules/susfs_apatch/tools/ksu_susfs`, `chmod 755`, tap Action again |
| `wrong tool` | you installed upstream's `master` tool (susfs 1.3.8) | install the one from the release zip, which is bundled |
| `kernel susfs=NONE` | the tool runs but the kernel does not answer the magic | flash the kernel built from this branch (`ksu_susfs show version` must print `v2.3.0`) |
| `ERROR: cannot apply` | one of the two above | as above |

If the state looks fine but nothing changes, make sure the paths are actually
listed in `conf/` - an empty config is a successful run that does nothing.
Set `conf/enable_log.txt` to `1` for kernel-side logging (then `dmesg | grep
susfs` shows every command), and note that the changes only affect **ordinary
apps**: from a su shell everything stays visible by design, so test with
`adb shell` after `pm` ... as an app, e.g.:

```sh
su -c '/data/adb/modules/susfs_apatch/tools/ksu_susfs add_sus_path /data/adb'
# then, as a normal app: stat /data/adb  ->  ENOENT
```

Build the tool from source if you prefer:

```sh
git clone https://gitlab.com/simonpunk/susfs4ksu.git
cd susfs4ksu && ./build_ksu_susfs_tool.sh      # needs the Android NDK
```

## Known differences from the KernelSU flavour

* **`CONFIG_KSU_SUSFS_TRY_UMOUNT` is not offered.**  SUSFS v2.3.0 dropped
  `susfs_try_umount()`; what is left of it in `fs/namespace.c` stays compiled
  out, exactly as in the `ksun` branch of this repository.
* **`CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS` is not offered.**  The kallsyms
  hiding hook is not part of the 4.14 port of `fs/susfs.c`, so the symbol is not
  declared - otherwise `ksu_susfs show enabled_features` would advertise a
  feature that does nothing.
* **`susfs_start_sdcard_monitor_fn()` is never called.**  KernelSU calls it when
  it receives its boot-complete event.  It forces `/data/media/0/Android` to look
  decrypted to apps; here it is left off, because the thread it starts needs the
  root context and SELinux to be available at that moment.  Everything else in
  SUSFS is unaffected - the flag it clears
  (`susfs_is_sdcard_android_data_not_decrypted`) starts out enabled.
* **`SUS_SU` (non-kprobe `su` hooks) does not exist** for non-GKI kernels
  upstream either, so it is not part of this port.
* **Auto-added sus mounts are not needed.**  The `AUTO_ADD_SUS_*` options that
  tell SUSFS which KernelSU mounts to hide stay off: APatch's `apd` runs in the
  root context, so `fs/namespace.c` gives *every* mount it creates an `mnt_id`
  from the sus range and they are all hidden from apps.

## Verified on device

Checked on the released kernel (`Pox-0.9-SUSFS-APatch`) with the bundled
`ksu_susfs` from `gki-android15-6.6`:

```
ksu_susfs show version          -> v2.3.0
ksu_susfs show enabled_features -> the eight CONFIG_KSU_SUSFS_* options below
cat /proc/self/mounts | grep -c /data/adb            -> 0
su 10001 -c cat /data/local/tmp/susfs_probe           -> No such file or directory
cat /data/local/tmp/susfs_probe                       -> probe   (as root)
```

So the glue's `reboot(2)` channel answers, sus mounts are gone from
`/proc/*/mount*`, and `sus_path` hides the marked inode from an app uid while
uid 0 is untouched.

## Verifying on device

```sh
# kernel side reports which features are compiled in
ksu_susfs show version
ksu_susfs show enabled_features

# mounts: root's module mounts are gone from these files, for everyone
cat /proc/self/mounts | grep -c /data/adb

# paths: visible as root, invisible from an app uid.
# Use a probe under a *traversable* directory: /data/adb is mode 0700, so an
# app uid gets EACCES from plain DAC long before susfs is consulted, which
# looks like "susfs does not work" but is not.
/data/local/tmp is 0771, so any uid can stat a known name inside it:
echo probe > /data/local/tmp/susfs_probe
su 10001 -c 'cat /data/local/tmp/susfs_probe'      # -> probe
ksu_susfs add_sus_path /data/local/tmp/susfs_probe
su 10001 -c 'cat /data/local/tmp/susfs_probe'      # -> No such file or directory
cat /data/local/tmp/susfs_probe                    # root still sees it
```

## Files

| path | role |
| --- | --- |
| `fs/susfs.c`, `include/linux/susfs{,_def}.h` | upstream SUSFS, verbatim |
| `fs/{namei,namespace,open,readdir,stat,statfs,proc*,notify/fdinfo}.c`, `kernel/sys.c`, `security/selinux/{avc,selinuxfs}.c` | upstream SUSFS kernel hunks |
| `security/selinux/susfs_apatch.c` | **new** - APatch glue |
| `kernel/reboot.c` | **new** - SUSFS command channel |
| `kernel/cred.c` | **new** - `TIF_PROC_*` maintenance |
| `fs/susfs_apatch.Kconfig`, `fs/Kconfig`, `fs/Makefile`, `security/selinux/Makefile` | **new** - wiring |
| `susfs/module/` | **new** - APatch module around the stock `ksu_susfs` tool |
| `susfs/module/webroot/` | **new** - native WebUI (`conf/` backed) |
| `susfs/module-upstream/webroot/` | **new** - upstream UI, KernelSU paths rewritten |
| `susfs/module/compat.sh` | **new** - lets the upstream UI's file layout work |
| `susfs/package.sh`, `susfs/tests/` | **new** - zip builder, jsdom UI test |