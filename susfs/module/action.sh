#!/system/bin/sh
# Action button: re-apply the configuration and report what happened.
#
# APatch does not show module output anywhere, so everything below is also
# appended to ${MODDIR}/susfs.log and echoed to /dev/kmsg.

MODDIR=${MODDIR:-$(dirname "$0")}
[ -d "${MODDIR}" ] || MODDIR=/data/adb/modules/susfs_apatch

. "${MODDIR}/utils.sh"

susfs_log "action tapped"
susfs_diagnose

if find_susfs_bin && [ -n "$("${SUSFS_BIN}" show version 2>/dev/null)" ]; then
	sh "${MODDIR}/service.sh"
	sh "${MODDIR}/boot-completed.sh"
	susfs_log "action done, log: ${LOGFILE}"
else
	susfs_die "cannot apply: see the state above"
fi