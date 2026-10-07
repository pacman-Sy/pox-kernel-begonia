#!/system/bin/sh
# Shared helpers for the SUSFS module (APatch flavour).

MODDIR=${MODDIR:-/data/adb/modules/susfs_apatch}
CONFDIR=${MODDIR}/conf

## Locate the stock susfs4ksu userspace tool.  The kernel speaks the same
## reboot(2) protocol as KernelSU does, so the upstream binary is used as is.
find_susfs_bin() {
	if [ -n "${SUSFS_BIN}" ] && [ -x "${SUSFS_BIN}" ]; then
		return 0
	fi
	for CANDIDATE in \
		"${MODDIR}/tools/ksu_susfs" \
		/data/adb/ap/bin/ksu_susfs \
		/data/adb/ksu/bin/ksu_susfs \
		/data/adb/modules/ksu/bin/ksu_susfs
	do
		if [ -x "${CANDIDATE}" ]; then
			SUSFS_BIN="${CANDIDATE}"
			return 0
		fi
	done
	return 1
}

## susfs_log <message...>
susfs_log() {
	echo "susfs: $*" | tee -a "${MODDIR}/susfs.log" 2>/dev/null || echo "susfs: $*"
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

## Kernel side sanity check: does this kernel speak the SUSFS protocol?
susfs_supported() {
	find_susfs_bin || return 1
	"${SUSFS_BIN}" show version 2>/dev/null | grep -q "v"
}