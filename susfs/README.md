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
  `/proc/<pid>/{mounts,mountinfo,stat,statfs}` for processes that are not
  allowed to use su.  No userspace configuration is needed: everything `apd`
  mounts is hidden from apps automatically.
* **Which processes are "no su".**  `susfs_apatch_update_proc_flags()` runs from
  `commit_creds()`, so zygote dropping a child to its app uid, an app calling
  `setuid()`, and APatch's `commit_su()` granting root are all covered - in both
  directions, so a su shell sees everything again.  su shells, `adb` and system
  services keep seeing root's mounts on purpose.
* **Command channel.**  `ksu_susfs` calls
  `reboot(0xDEADBEEF, 0xFAFAFAFA, CMD_SUSFS_*, &info)` as root; the magic pair is
  answered at the very top of `SYSCALL_DEFINE4(reboot)` and never reaches the
  real reboot path.  APatch/KernelPatch hijacks syscall 45 for its own supercall
  and does not touch `reboot(2)`, so the two do not collide.

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
`ksu_susfs.url`); drop your own build into `susfs/module/tools/` to override it.

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

## Verifying on device

```sh
# kernel side reports which features are compiled in
ksu_susfs show version
ksu_susfs show enabled_features

# from a normal (non root) app, or from adb after hiding was configured
cat /proc/mounts | grep modules      # root's module mounts must be gone
ls /data/adb                         # must not exist
stat /data/adb/modules/foo           # ENOENT

# from a su shell everything must still be visible
ls /data/adb && cat /proc/mounts | grep modules
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