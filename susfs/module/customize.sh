#!/system/bin/sh
# customize.sh - module installer (runs inside the module zip install step).
#
# The kernel side is already compiled in, this only fetches the stock susfs4ksu
# tool and creates the default configuration.

MODDIR=${MODDIR:-/data/adb/modules/susfs_apatch}

. "${MODDIR}/utils.sh"

TOOLDIR="${MODDIR}/tools"
KSU_SUSFS_URL_DEFAULT="https://gitlab.com/simonpunk/susfs4ksu/-/raw/master/ksu_module_susfs/tools/ksu_susfs_arm64"

mkdir -p "${TOOLDIR}" "${CONFDIR}"

if find_susfs_bin; then
	susfs_log "using ${SUSFS_BIN}"
elif [ -x "${TOOLDIR}/ksu_susfs" ]; then
	:
else
	URL="$(cat "${MODDIR}/ksu_susfs.url" 2>/dev/null)"
	[ -n "${URL}" ] || URL="${KSU_SUSFS_URL_DEFAULT}"
	susfs_log "downloading ksu_susfs from ${URL}"
	if command -v curl >/dev/null 2>&1; then
		curl -L -o "${TOOLDIR}/ksu_susfs" "${URL}"
	else
		busybox wget -O "${TOOLDIR}/ksu_susfs" "${URL}"
	fi
	if [ -s "${TOOLDIR}/ksu_susfs" ]; then
		chmod 0755 "${TOOLDIR}/ksu_susfs"
	else
		rm -f "${TOOLDIR}/ksu_susfs"
		susfs_log "download failed - install the tool manually into ${TOOLDIR}"
	fi
fi

# Seed the config files on first install, never overwrite user edits.
[ -f "${CONFDIR}/sus_path.txt" ] || cat > "${CONFDIR}/sus_path.txt" <<'EOF'
# One path per line.  The path and everything below it becomes invisible to
# ordinary apps (stat, open, getdents, ...).
/data/adb
/data/adb/modules
EOF

[ -f "${CONFDIR}/sus_kstat.txt" ] || : > "${CONFDIR}/sus_kstat.txt"
[ -f "${CONFDIR}/sus_map.txt" ] || : > "${CONFDIR}/sus_map.txt"
[ -f "${CONFDIR}/open_redirect.txt" ] || : > "${CONFDIR}/open_redirect.txt"
[ -f "${CONFDIR}/enable_log.txt" ] || echo 0 > "${CONFDIR}/enable_log.txt"
[ -f "${CONFDIR}/uname.txt" ] || : > "${CONFDIR}/uname.txt"

# Snapshot the real kernel command line so the user can edit a fake one.
if [ ! -f "${CONFDIR}/fake_cmdline.txt" ] && [ -r /proc/cmdline ]; then
	cp /proc/cmdline "${CONFDIR}/fake_cmdline.txt" 2>/dev/null
	echo "${CONFDIR}/fake_cmdline.txt" > "${CONFDIR}/fake_cmdline_path.txt"
fi

# APatch exposes the usual Magisk-style helpers, but do not hard depend on them.
if command -v set_perm_recursive >/dev/null 2>&1; then
	set_perm_recursive "${MODDIR}" 0 0 0755 0644
else
	chmod 0755 "${MODDIR}"/*.sh 2>/dev/null
	chmod 0644 "${CONFDIR}"/* 2>/dev/null
	chmod 0755 "${TOOLDIR}"/* 2>/dev/null
fi

susfs_log "installed; edit ${CONFDIR} and reboot"