#!/usr/bin/env bash
/root/.local/bin/backupmgr.sh incr --secondary-stor
if [[ $(grep -Ei 'ok' /etc/backupMgr/last-backup.log) ]]; then
    backupID=$(cut -d':' -f2 < /etc/backupMgr/last-backup.log)
    /root/.local/bin/backupmgr.sh cleanincr ${backupID} --secondary-stor
fi
