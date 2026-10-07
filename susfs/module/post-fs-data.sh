#!/system/bin/sh
# post-fs-data: everything that has to be in place before zygote starts.
#
# Runs early so that paths are hidden from the very first app processes, and so
# that root's module mounts (which APatch's apd creates around this point) are
# already marked as "sus mounts" by the kernel.

MODDIR=${MODDIR:-$(dirname "$0")}
[ -d "${MODDIR}" ] || MODDIR=/data/adb/modules/susfs_apatch

. "${MODDIR}/utils.sh"

require_susfs
susfs_log "post-fs-data: kernel susfs ${SUSFS_VERSION}"
susfs_log "features: ${SUSFS_FEATURES}"

# only does anything in the upstream-UI zip variant
[ -f "${MODDIR}/compat.sh" ] && . "${MODDIR}/compat.sh"
susfs_upstream_installed && import_legacy_conf

# Kernel logging off by default; conf/enable_log contains 1 to turn it on.
[ "$(read_conf enable_log.txt | head -n1)" = "1" ] && "${SUSFS_BIN}" enable_log 1

# Hiding root's mounts has to happen before zygote caches the mount list, so
# switch it on as early as possible and leave it on until service.sh.
"${SUSFS_BIN}" hide_sus_mnts_for_non_su_procs 1

# Paths (one per line) that must look like they do not exist to apps.
read_conf sus_path.txt | while IFS= read -r P; do
	[ -n "${P}" ] || continue
	if "${SUSFS_BIN}" add_sus_path "${P}"; then
		susfs_log "sus_path ${P}"
	else
		susfs_log "sus_path ${P} FAILED (already added or not found)"
	fi
done