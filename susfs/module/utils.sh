#!/system/bin/sh
# Shared helpers for the SUSFS module (APatch flavour).
#
# APatch runs module scripts as `busybox sh <script>` with cwd set to the
# module directory and only these variables exported: AP_MODULE, APATCH,
# APATCH_VER, PATH.  There is no MODDIR, and nothing a module prints shows up in
# the manager UI, so every message goes to three places:
#   * stdout  -> apd's logcat (journalctl / logcat -s apd)
#   * the log file below, which is what you read after tapping Action
#   * /dev/kmsg, so `dmesg | grep susfs` shows it too

MODDIR=${MODDIR:-$(dirname "$0")}
[ -d "${MODDIR}" ] || MODDIR=/data/adb/modules/susfs_apatch
CONFDIR=${MODDIR}/conf
LOGFILE=${MODDIR}/susfs.log

## susfs_log <message...>
susfs_log() {
	LINE="susfs: $*"
	echo "${LINE}"
	# keep the log from growing forever across boots
	if [ -f "${LOGFILE}" ] && [ "$(wc -c < "${LOGFILE}" 2>/dev/null || echo 0)" -gt 65536 ]; then
		tail -n 200 "${LOGFILE}" > "${LOGFILE}.tmp" 2>/dev/null &&
			mv "${LOGFILE}.tmp" "${LOGFILE}"
	fi
	echo "${LINE}" >> "${LOGFILE}" 2>/dev/null
	echo "${LINE}" > /dev/kmsg 2>/dev/null
}

## susfs_die <message...> - report a fatal problem for this stage and stop
susfs_die() {
	susfs_log "ERROR: $*"
	susfs_log "ERROR: see ${LOGFILE} and 'dmesg | grep susfs'"
	exit 0
}

## Locate the stock susfs4ksu tool.  The kernel speaks the same reboot(2)
## protocol as KernelSU does, so the upstream binary is used as is.
find_susfs_bin() {
	if [ -n "${SUSFS_BIN}" ] && [ -x "${SUSFS_BIN}" ]; then
		return 0
	fi
	for CANDIDATE in \
		"${MODDIR}/tools/ksu_susfs" \
		/data/adb/ap/bin/ksu_susfs \
		/data/adb/ksu/bin/ksu_susfs
	do
		if [ -x "${CANDIDATE}" ]; then
			SUSFS_BIN="${CANDIDATE}"
			export SUSFS_BIN
			return 0
		fi
	done
	return 1
}

## Everything that has to be true before a SUSFS command can work.
require_susfs() {
	if [ "$(id -u)" != "0" ]; then
		susfs_die "not running as root (uid $(id -u))"
	fi
	if ! find_susfs_bin; then
		susfs_die "ksu_susfs not found. Install it as ${MODDIR}/tools/ksu_susfs"
	fi
	# A real kernel-side SUSFS answers 'show version'; without it every
	# command returns EINVAL, which is the usual "nothing happens".
	if ! SUSFS_VERSION="$("${SUSFS_BIN}" show version 2>/dev/null)" || [ -z "${SUSFS_VERSION}" ]; then
		susfs_die "this kernel has no SUSFS (or the tool cannot reach it) - flash the susfs-apatch kernel"
	fi
	[ -z "${SUSFS_FEATURES}" ] && SUSFS_FEATURES="$("${SUSFS_BIN}" show enabled_features 2>/dev/null | tr '\n' ' ')"
}

## Print the full state; this is what the Action button is for.
susfs_diagnose() {
	susfs_log "--- susfs state ---"
	susfs_log "uid=$(id -u) module=${MODDIR}"
	if find_susfs_bin; then
		susfs_log "tool=${SUSFS_BIN}"
		V="$("${SUSFS_BIN}" show version 2>/dev/null)"
		if [ -n "${V}" ]; then
			susfs_log "kernel susfs=${V}"
			susfs_log "features=$("${SUSFS_BIN}" show enabled_features 2>/dev/null | tr '\n' ' ')"
		else
			susfs_log "kernel susfs=NONE (reboot with magic reached no SUSFS handler)"
		fi
	else
		susfs_log "tool=MISSING (expected ${MODDIR}/tools/ksu_susfs)"
	fi
	susfs_log "mounts seen from here: $(grep -c ' /data/adb' /proc/self/mounts 2>/dev/null) /data/adb entries"
	susfs_log "--- end state ---"
}

## Read a config file, one entry per line, ignoring blanks and '#' comments.
read_conf() {
	CONF="$1"
	[ -f "${CONFDIR}/${CONF}" ] || return 0
	while IFS= read -r LINE; do
		case "${LINE}" in
			''|'#'*) continue ;;
			' '*|'	'*) continue ;;
		esac
		echo "${LINE}"
	done < "${CONFDIR}/${CONF}"
}

## Clone owner/permission/SELinux context of $2 onto $1.
clone_perm() {
	TO="$1"
	FROM="$2"
	[ -e "${TO}" ] || return 0
	[ -e "${FROM}" ] || return 0
	CLONED="$(stat -c "%a %u %g" "${FROM}")"
	# shellcheck disable=SC2086
	set -- ${CLONED}
	chmod "$1" "${TO}" 2>/dev/null
	chown "$2":"$3" "${TO}" 2>/dev/null
	chcon --reference="${FROM}" "${TO}" 2>/dev/null
}