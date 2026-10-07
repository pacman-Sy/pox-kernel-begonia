#!/system/bin/sh
# customize.sh - module installer, sourced by APatch's installer with $MODPATH
# and the whole module tree already extracted.

MODDIR=${MODDIR:-${MODPATH:-/data/adb/modules/susfs_apatch}}
[ -d "${MODDIR}" ] || MODDIR=/data/adb/modules/susfs_apatch

. "${MODDIR}/utils.sh"

TOOLDIR="${MODDIR}/tools"
mkdir -p "${TOOLDIR}" "${CONFDIR}"

## Several places carry the prebuilt arm64 tool; try them in order.  The one in
## ksu_susfs.url wins, so a user can point it somewhere else.
try_download() {
	URL="$1"
	DST="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "${DST}" "${URL}" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "${DST}" "${URL}" 2>/dev/null
	elif [ -x /data/adb/ap/bin/busybox ]; then
		/data/adb/ap/bin/busybox wget -q -O "${DST}" "${URL}" 2>/dev/null
	else
		return 1
	fi
}

if find_susfs_bin; then
	susfs_log "using existing tool ${SUSFS_BIN}"
elif [ -x "${TOOLDIR}/ksu_susfs" ]; then
	susfs_log "using ${TOOLDIR}/ksu_susfs"
else
	rm -f "${TOOLDIR}/ksu_susfs"
	while IFS= read -r URL; do
		case "${URL}" in ''|'#'*) continue ;; esac
		susfs_log "downloading ksu_susfs from ${URL}"
		if try_download "${URL}" "${TOOLDIR}/ksu_susfs" && [ -s "${TOOLDIR}/ksu_susfs" ]; then
			# reject html error pages and git-lfs pointers
			if head -c 4 "${TOOLDIR}/ksu_susfs" | grep -q "version"; then
				rm -f "${TOOLDIR}/ksu_susfs"
				continue
			fi
			chmod 0755 "${TOOLDIR}/ksu_susfs"
			break
		fi
		rm -f "${TOOLDIR}/ksu_susfs"
	done <<EOF
$(cat "${MODDIR}/ksu_susfs.url" 2>/dev/null)
https://gitlab.com/simonpunk/susfs4ksu/-/raw/master/ksu_module_susfs/tools/ksu_susfs_arm64
EOF
fi

if find_susfs_bin; then
	chmod 0755 "${SUSFS_BIN}" 2>/dev/null
	susfs_log "tool ready: ${SUSFS_BIN}"
	if [ -n "$("${SUSFS_BIN}" show version 2>/dev/null)" ]; then
		susfs_log "kernel side SUSFS is present"
	else
		susfs_log "WARNING: the tool is installed but the kernel has no SUSFS"
		susfs_log "WARNING: flash the kernel built from the susfs-apatch branch"
	fi
else
	susfs_log "ERROR: could not download ksu_susfs"
	susfs_log "ERROR: put the arm64 binary in ${TOOLDIR}/ksu_susfs (chmod 755) and reinstall"
fi

## Seed the config files on first install, never overwrite user edits.
[ -f "${CONFDIR}/sus_path.txt" ] || cat > "${CONFDIR}/sus_path.txt" <<'EOF'
# One path per line.  The path and everything below it becomes invisible to
# ordinary apps (stat, open, getdents, ...).
/data/adb/modules
EOF
[ -f "${CONFDIR}/sus_kstat.txt" ] || : > "${CONFDIR}/sus_kstat.txt"
[ -f "${CONFDIR}/sus_map.txt" ] || : > "${CONFDIR}/sus_map.txt"
[ -f "${CONFDIR}/open_redirect.txt" ] || : > "${CONFDIR}/open_redirect.txt"
[ -f "${CONFDIR}/enable_log.txt" ] || echo 0 > "${CONFDIR}/enable_log.txt"
[ -f "${CONFDIR}/uname.txt" ] || : > "${CONFDIR}/uname.txt"

## Snapshot the real kernel command line so the user can edit a fake one.
if [ ! -f "${CONFDIR}/fake_cmdline.txt" ] && [ -r /proc/cmdline ]; then
	cp /proc/cmdline "${CONFDIR}/fake_cmdline.txt" 2>/dev/null
	echo "${CONFDIR}/fake_cmdline.txt" > "${CONFDIR}/fake_cmdline_path.txt"
fi

if command -v set_perm_recursive >/dev/null 2>&1; then
	set_perm_recursive "${MODDIR}" 0 0 0755 0644
else
	chmod 0755 "${MODDIR}"/*.sh 2>/dev/null
	chmod 0644 "${CONFDIR}"/* 2>/dev/null
	chmod 0755 "${TOOLDIR}"/* 2>/dev/null
fi

susfs_log "installed; edit ${CONFDIR} and reboot"