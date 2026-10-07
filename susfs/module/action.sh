#!/system/bin/sh
# Re-apply the configuration without rebooting (useful while testing).
MODDIR=${MODDIR:-/data/adb/modules/susfs_apatch}
MODDIR="${0%/action.sh}"
sh "${MODDIR}/service.sh"
sh "${MODDIR}/boot-completed.sh"
