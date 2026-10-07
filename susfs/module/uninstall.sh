#!/system/bin/sh
# Everything SUSFS configured lives in kernel memory only, so a reboot is all
# it takes to remove it.  Nothing to undo on disk.
rm -f /data/adb/modules/susfs_apatch/susfs.log 2>/dev/null
