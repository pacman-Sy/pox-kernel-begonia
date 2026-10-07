#!/system/bin/sh
# service stage: the module mounts exist by now, so the stat of the mounted
# files can be cloned, maps can be hidden and the command line can be spoofed.

MODDIR=${MODDIR:-$(dirname "$0")}
[ -d "${MODDIR}" ] || MODDIR=/data/adb/modules/susfs_apatch

. "${MODDIR}/utils.sh"

require_susfs

# sus_path_loop: same as sus_path but re-marks the inode when it reappears
read_conf sus_path_loop.txt | while IFS= read -r P; do
	[ -n "${P}" ] || continue
	"${SUSFS_BIN}" add_sus_path_loop "${P}" >/dev/null 2>&1 && susfs_log "sus_path_loop ${P}"
done

# sus_kstat: make the mounted file look like the file it replaced.
# Format: <target> <ino|default> <dev|default> <nlink|default> <size|default>
read_conf sus_kstat.txt | while IFS= read -r LINE; do
	[ -n "${LINE}" ] || continue
	# shellcheck disable=SC2086
	set -- ${LINE}
	if [ $# -lt 2 ]; then
		continue
	fi
	TARGET="$1"
	INO="${2:-default}"
	# 'default' ino/dev tells susfs to clone them from the current inode.
	if "${SUSFS_BIN}" add_sus_kstat "${TARGET}" >/dev/null 2>&1; then
		susfs_log "sus_kstat ${TARGET}"
	elif [ "${INO}" != "default" ]; then
		susfs_log "sus_kstat ${TARGET} failed"
	fi
done

# sus_map: hide mmapped root files from /proc/<pid>/{maps,smaps,map_files}.
read_conf sus_map.txt | while IFS= read -r P; do
	[ -n "${P}" ] || continue
	"${SUSFS_BIN}" add_sus_map "${P}" >/dev/null 2>&1 && susfs_log "sus_map ${P}"
done

# open_redirect: <target> <redirected> [uid_scheme]
# uid_scheme: 0 = non app processes, 1 = root but not su, 2 = non su,
#             3 = umounted app, 4 = any umounted process
read_conf open_redirect.txt | while IFS= read -r LINE; do
	[ -n "${LINE}" ] || continue
	# shellcheck disable=SC2086
	set -- ${LINE}
	[ $# -ge 2 ] || continue
	"${SUSFS_BIN}" add_open_redirect "$1" "$2" "${3:-0}" >/dev/null 2>&1 \
		&& susfs_log "open_redirect $1 -> $2 (scheme ${3:-0})"
done

# Fake /proc/cmdline or a fake bootconfig file, whichever conf/fake_cmdline.txt
# points at (created by customize.sh from the real one).
FAKE_CMDLINE=$(read_conf fake_cmdline_path.txt | head -n1)
if [ -n "${FAKE_CMDLINE}" ] && [ -f "${FAKE_CMDLINE}" ]; then
	"${SUSFS_BIN}" set_cmdline_or_bootconfig "${FAKE_CMDLINE}" \
		&& susfs_log "spoofed cmdline from ${FAKE_CMDLINE}"
fi

# Keep hiding root's mounts: apd has created all of them at this point.
"${SUSFS_BIN}" hide_sus_mnts_for_non_su_procs 1

# upstream UI variant: its JSON kstat list and the files it reads
if [ -f "${MODDIR}/compat.sh" ]; then
	. "${MODDIR}/compat.sh"
	susfs_upstream_installed && {
		apply_kstat_json
		write_snapshots
	}
fi

exit 0