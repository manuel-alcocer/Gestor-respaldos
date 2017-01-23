#!/usr/bin/env bash
/root/.local/bin/backupmgr.sh full --secondary-stor
if [[ $(grep -Ei 'ok' /etc/backupMgr/last-backup.log) ]]; then
    backupID=$(cut -d':' -f2 < /etc/backupMgr/last-backup.log)
    /root/.local/bin/backupmgr.sh cleanfull ${backupID} --secondary-stor
fi
