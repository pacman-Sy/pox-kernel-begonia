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

# Absolute, because the zip calls below run from inside the staging directory.
mkdir -p "${OUTDIR}"
OUTDIR=$(cd "${OUTDIR}" && pwd)
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

# ── BRENE, ported to APatch ───────────────────────────────────
# Kept as its own zip: it is a different module (id: brene) with its own id,
# its own WebUI and AGPL-3.0 licensing, so it must not be merged with the one
# above.  susfs/brene/ is the upstream module with APatch paths.
BRENE="${HERE}/brene"
if [ -f "${BRENE}/module.prop" ]; then
	BRENE_OUT="${WORK}/brene"
	mkdir -p "${BRENE_OUT}"
	cp -r "${BRENE}/." "${BRENE_OUT}/"
	rm -f "${BRENE_OUT}/README.upstream.md"
	# keep the tool BRENE ships (same v2 protocol our kernel speaks); fall
	# back to the canonical build only if it is somehow absent
	if [ ! -f "${BRENE_OUT}/tools/susfs" ]; then
		mkdir -p "${BRENE_OUT}/tools"
		command -v curl >/dev/null 2>&1 &&
			curl -fsSL -o "${BRENE_OUT}/tools/susfs" "${KSU_SUSFS_URL}"
	fi
	[ -f "${BRENE_OUT}/tools/susfs" ] && chmod 0755 "${BRENE_OUT}/tools/susfs"
	chmod 0755 "${BRENE_OUT}"/*.sh
	( cd "${BRENE_OUT}" && zip -r9 "${OUTDIR}/susfs_apatch-brene.zip" . -x 'susfs.log*' )
	log "wrote ${OUTDIR}/susfs_apatch-brene.zip"
else
	log "warning: ${BRENE} missing, skipping the BRENE variant"
fi

ls -l "${OUTDIR}"/susfs_apatch-*.zip