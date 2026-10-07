#!/bin/sh
# package.sh - build the module zips.
#
#   ./susfs/package.sh [outdir]
#
# Produces two zips from the same module tree:
#
#   susfs_apatch-module.zip           native WebUI (susfs/module/webroot)
#   susfs_apatch-module-upstream.zip  the ported upstream susfs4ksu WebUI
#                                     (susfs/module-upstream/webroot) plus the
#                                     UPSTREAM_UI marker that turns on the
#                                     compatibility layer in compat.sh
#
# The ksu_susfs binary is bundled when it can be fetched, so installing a zip
# needs nothing on the device but the zip itself.

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
MODDIR="${HERE}/module"
UPWEBROOT="${HERE}/module-upstream/webroot"
OUTDIR="${1:-${HERE}/../build}"
KSU_SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android15-6.6/ksu_module_susfs/tools/ksu_susfs_arm64"

mkdir -p "${OUTDIR}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

log() { echo "[package] $*"; }

# ── shared module tree ────────────────────────────────────────
stage_common() {
	TARGET="$1"
	mkdir -p "${TARGET}"
	cp -r "${MODDIR}/." "${TARGET}/"
	rm -rf "${TARGET}/tools" "${TARGET}/susfs.log" "${TARGET}/webroot-upstream"

	if ! [ -f "${TARGET}/tools/ksu_susfs" ]; then
		mkdir -p "${TARGET}/tools"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL -o "${TARGET}/tools/ksu_susfs" "${KSU_SUSFS_URL}" \
				|| log "warning: could not fetch ksu_susfs, the module will download it on device"
		fi
		[ -f "${TARGET}/tools/ksu_susfs" ] && chmod 0755 "${TARGET}/tools/ksu_susfs" \
			|| rm -f "${TARGET}/tools/ksu_susfs"
	fi
	chmod 0755 "${TARGET}"/*.sh
}

# ── native UI ─────────────────────────────────────────────────
NATIVE="${WORK}/native"
stage_common "${NATIVE}"
( cd "${NATIVE}" && zip -r9 "${OUTDIR}/susfs_apatch-module.zip" . -x 'susfs.log*' )
log "wrote ${OUTDIR}/susfs_apatch-module.zip"

# ── upstream UI ───────────────────────────────────────────────
if [ -d "${UPWEBROOT}" ]; then
	UP="${WORK}/upstream"
	stage_common "${UP}"
	rm -rf "${UP}/webroot"
	cp -r "${UPWEBROOT}" "${UP}/webroot"
	: > "${UP}/UPSTREAM_UI"
	( cd "${UP}" && zip -r9 "${OUTDIR}/susfs_apatch-module-upstream.zip" . -x 'susfs.log*' )
	log "wrote ${OUTDIR}/susfs_apatch-module-upstream.zip"
else
	log "warning: ${UPWEBROOT} missing, skipping the upstream-UI variant"
fi

ls -l "${OUTDIR}"/susfs_apatch-module*.zip