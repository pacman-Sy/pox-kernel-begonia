#!/system/bin/sh
# compat.sh - support for the ported upstream susfs4ksu WebUI.
#
# The upstream UI (susfs4ksu-module by sidex15) is not configurable: it writes
# its lists at the module root with fixed names, reads a JSON file for static
# kstat entries, and expects a handful of snapshot/log files to exist.  It is
# shipped as the second zip variant, so these helpers only do anything when that
# UI is actually installed (marker: UPSTREAM_UI in the module directory).
#
# The native WebUI in webroot/ uses conf/ and never trips any of this.

UPSTREAM_MARKER="${MODDIR}/UPSTREAM_UI"
LEGACYDIR="${MODDIR}"

susfs_upstream_installed() {
	[ -f "${UPSTREAM_MARKER}" ]
}

## Import the upstream list files into conf/ so the normal apply path covers
## them too.  Import is one way: conf/ is the source of truth afterwards, and
## re-imports append only what is missing so a delete in the UI sticks.
import_legacy_conf() {
	susfs_upstream_installed || return 0

	# <upstream file>:<conf file>
	for PAIR in \
		"sus_path.txt:sus_path.txt" \
		"sus_path_loop.txt:sus_path_loop.txt" \
		"sus_maps.txt:sus_map.txt" \
		"sus_open_redirect.txt:open_redirect.txt" \
		"sus_mount.txt:sus_mount.txt"
	do
		SRC="${LEGACYDIR}/${PAIR%%:*}"
		DST="${CONFDIR}/${PAIR##*:}"
		[ -f "${SRC}" ] || continue
		[ -f "${DST}" ] || : > "${DST}"
		grep -v "^[[:space:]]*#" "${SRC}" 2>/dev/null | while IFS= read -r LINE; do
			case "${LINE}" in ''|' '*) continue ;; esac
			grep -F -x -q "${LINE}" "${DST}" 2>/dev/null ||
				printf '%s\n' "${LINE}" >> "${DST}"
		done
		susfs_log "compat: merged ${PAIR%%:*} -> conf/${PAIR##*:}"
	done
}

## Static kstat entries, as the upstream UI stores them: a JSON array of
## objects.  Parsed with one awk pass per object, the same trick upstream uses.
apply_kstat_json() {
	JSON="${LEGACYDIR}/sus_kstat_statically.json"
	[ -f "${JSON}" ] || return 0
	grep -q '"path"' "${JSON}" 2>/dev/null || return 0

	awk '/^[[:space:]]*\{/,/^[[:space:]]*\}/' "${JSON}" | {
		OBJ=""
		while IFS= read -r LINE; do
			case "${LINE}" in
				*[[:space:]]\{*) OBJ="" ;;
			esac
			OBJ="${OBJ} ${LINE}"
			case "${LINE}" in
				*[[:space:]]\}*)
					IFS='	' read -r P INO DEV NLINK SIZE AT ATNS MT MTNS CT CTNS BLK BLKS <<EOF
$(echo "${OBJ}" | awk '
					{
						while (match($0, /"[a-z_]+"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
							pair = substr($0, RSTART, RLENGTH)
							$0 = substr($0, RSTART + RLENGTH)
							k = pair; sub(/"[[:space:]]*:.*/, "", k); sub(/^"/, "", k)
							v = pair; sub(/^[^:]*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
							if (!(k in seen)) { seen[k] = 1; val[k] = v }
						}
					}
					END {
						printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
							val["path"], val["ino"], val["dev"], val["nlink"], val["size"], \
							val["atime"], val["atime_nsec"], val["mtime"], val["mtime_nsec"], \
							val["ctime"], val["ctime_nsec"], val["blocks"], val["blksize"]
					}')
EOF
					[ -n "${P}" ] && "${SUSFS_BIN}" add_sus_kstat_statically \
						"${P}" "${INO:-default}" "${DEV:-default}" "${NLINK:-default}" "${SIZE:-default}" \
						"${AT:-default}" "${ATNS:-default}" "${MT:-default}" "${MTNS:-default}" \
						"${CT:-default}" "${CTNS:-default}" "${BLK:-default}" "${BLKS:-default}" \
						>/dev/null 2>&1 && susfs_log "compat: kstat ${P}"
					OBJ=""
					;;
			esac
		done
	}
}

## Files the upstream UI reads but does not create.
write_snapshots() {
	susfs_upstream_installed || return 0
	mkdir -p "${LEGACYDIR}/logs" 2>/dev/null

	dmesg > "${LEGACYDIR}/dmesg.log" 2>/dev/null
	cp "${LEGACYDIR}/dmesg.log" "${LEGACYDIR}/latest_dmesg_susfs.log" 2>/dev/null
	cat /proc/1/mountinfo > "${LEGACYDIR}/pid1_mountinfo.txt" 2>/dev/null
	cat /proc/1/maps > "${LEGACYDIR}/zygote64_maps.txt" 2>/dev/null
	cp "${LEGACYDIR}/zygote64_maps.txt" "${LEGACYDIR}/zygote64_mountinfo.txt" 2>/dev/null
	ls /data/adb/modules > "${LEGACYDIR}/ksu_module_list.txt" 2>/dev/null

	# the UI shows this one, and upstream keeps it under logs/
	mkdir -p "${LEGACYDIR}/logs" 2>/dev/null
	[ -f "${LOGFILE}" ] && cp -f "${LOGFILE}" "${LEGACYDIR}/logs/susfs.log" 2>/dev/null
	return 0
}