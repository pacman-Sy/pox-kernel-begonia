#!/bin/bash
# shellcheck disable=SC2154
MODDIR=${0%/*}
KSU_BIN=/nonexistent/apatch-port   # KernelSU-only, see utils.sh
KSU_MODULES_DIR=/data/adb/modules
SUSFS_BIN=${DEST_BIN_DIR:-/data/adb/ap/bin}/susfs
PERSISTENT_DIR=/data/adb/brene
DEST_BIN_DIR=${DEST_BIN_DIR:-/data/adb/ap/bin}

rm -rf "${PERSISTENT_DIR}"
rm -f "${SUSFS_BIN}"
rm -f "${DEST_BIN_DIR}/sus"
rm -f "${DEST_BIN_DIR}/ksu_susfs"
