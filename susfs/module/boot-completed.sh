#!/system/bin/sh
# boot-completed: last pass, everything the system is done setting up.

MODDIR=${MODDIR:-/data/adb/modules/susfs_apatch}

. "${MODDIR}/utils.sh"

find_susfs_bin || exit 0

# uname spoof: conf/uname.txt holds "<release>|<version>".
UNAME_LINE=$(read_conf uname.txt | head -n1)
if [ -n "${UNAME_LINE}" ]; then
	RELEASE="${UNAME_LINE%%|*}"
	VERSION="${UNAME_LINE#*|}"
	if [ -n "${RELEASE}" ] && [ -n "${VERSION}" ]; then
		"${SUSFS_BIN}" set_uname "${RELEASE}" "${VERSION}" \
			&& susfs_log "uname spoof: ${RELEASE} / ${VERSION}"
	fi
fi

# Re-add the paths: an app process that was started before post-fs-data ran
# (or a path that only appeared later) may still be visible.
read_conf sus_path.txt | while IFS= read -r P; do
	[ -n "${P}" ] || continue
	"${SUSFS_BIN}" add_sus_path "${P}" >/dev/null 2>&1
done

"${SUSFS_BIN}" hide_sus_mnts_for_non_su_procs 1

susfs_log "configuration done"
exit 0