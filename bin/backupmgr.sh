#!/usr/bin/env bash

REMOTE_HOSTS=()
BASE_STOR=${BASE_STOR:-/BackUps}
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}
MAILLIST=${BACKUPMGR_CONFIG_DIR}${MAILFILE:-/mail.list}
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"
REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"
SECONDARY_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${SECONDARY_HOSTS_FILE:-/secondary_hosts.list}"
OPENSSL_PUBKEY="${BACKUPMGR_CONFIG_DIR}${OPENSSL_PUBKEY:-/backupmgr.pubkey.pem}"

PKGLISTNAME='listado-paquetes.list.txt'

LOGFILE="${BACKUPMGR_CONFIG_DIR}/last-backup.log"
POSTMASTER='manuel@alcocer.net'

BACKUPTYPE=$1
LASTOPT=${@: -1}
ARGUMENTS=$2
CLEANARG=$3

EXCLUDE=()

ERRORFUNCTION=()

ALIASHOST=''
HOSTFILENAME=''
REMOTEUSERNAME=''
HOSTIP=''
BACKUPDIR=''
TARGETDIR=''
OSDISTRO=''
FULLTIME=''
INCRTIME=''

BACKUPNAME=''

NUMERRORS=0

function exitWithErr(){
    printf 'Hubieron errores...Saliendo\n'
    exit 1
}

function checkConfig(){
    if [[ ! -f ${REMOTE_HOSTS_FILE} ]]; then
        printf "No existe el fichero de hosts remotos ${REMOTE_HOSTS_FILE}\n"
        exitWithErr
    fi
    if [[ ! -d ${BASE_STOR} ]]; then
        printf "No existe la ruta de almacenamiento local ${BASE_STOR}\n"
        exitWithErr
    fi
    if [[ ! -f ${SECONDARY_HOSTS_FILE} ]]; then
        printf "No existe el fichero de almacenamiento secundario ${SECONDARY_HOSTS_FILE}\n"
        exitWithErr
    fi
}

function getRemoteHost(){
    while IFS= read -r linea; do
        REMOTE_HOSTS+=("${linea}")
    done < ${REMOTE_HOSTS_FILE}
}

function genExcludes(){
    EXCLUDE=()
    excludeVal=$(cut -d':' -f4 <<< $1)
    if [[ ${excludeVal^^} == 'E' ]]; then
        excludeVals=${1#*:E:}
        SAVEIFS=$IFS
        IFS=:
        for field in ${excludeVals}; do
            EXCLUDE+=("--exclude ${field}")
        done
        IFS=$SAVEIFS
    fi
}

function rsyncToSecondaryNow(){
    secRemUser=$(cut -d':' -f2 <<< $1)
    secRemHost=$(cut -d':' -f3 <<< $1)
    secRemDir="$(cut -d':' -f4 <<< $1)/${2}/${3}"
    rsync $4 ${secRemUser}@${secRemHost}:${secRemDir}
    if [[ $? != 0 ]]; then
        ((NUMERRORS++))
        ERRORFUNCTION+=("$ALIASHOST - Error subiendo a secundario: ${secRemHost} - ${secRemDir}\n")
    fi
}

function uploadBackupDir(){
    temporaryTar=/tmp/${2##*/}-${1}-${3}.tar.gz
    tar czf ${temporaryTar} ${2} &>/dev/null
    while IFS= read -r linea; do
        rsyncToSecondaryNow ${linea} $1 $3 ${temporaryTar}
    done < ${SECONDARY_HOSTS_FILE}
    rm ${temporaryTar}
}

function lastFullRsync(){
    baseDir="${BASE_STOR}/${1}/fullSync"
    lastDir="$(ls -t ${baseDir} | head -n1)"
    printf "${lastDir}\n"
}

function setVars(){
    ALIASHOST=$(cut -d':' -f1 <<< $1)
    HOSTFILENAME="${REMOTE_HOSTS_DIR}/${ALIASHOST}"
    REMOTEUSERNAME=$(cut -d':' -f2 <<< $1)
    HOSTIP=$(cut -d':' -f3 <<< $1)
    FULLTIME=$(cut -d':' -f4 <<< $1)
    INCRTIME=$(cut -d':' -f5 <<< $1)
    OSDISTRO=$(cut -d':' -f6 <<< $1)
    if [[ $3 == 'full' ]]; then
        TARGETDIR="${BASE_STOR}/${ALIASHOST}/fullSync/${2}"
        BACKUPDIR="${TARGETDIR}"
    else
        TARGETDIR="${BASE_STOR}/${ALIASHOST}/fullSync/$(lastFullRsync ${ALIASHOST})"
        BACKUPDIR="${BASE_STOR}/${ALIASHOST}/incrSync/${2}"
    fi
}

function rsyncNow(){
    if [[ ! -d ${BACKUPDIR} ]]; then
        mkdir -p ${BACKUPDIR}
    fi
    BCKPOBJ=$(cut -d':' -f3 <<< $2)
    if [[ ${HOSTIP,,} != 'localhost' ]]; then
        BCKPOBJ="${REMOTEUSERNAME}@${HOSTIP}:${BCKPOBJ}"
    fi
    # si la ruta de respaldos es cifrada, hay que hacerla completa pero guardándola en incr
    if [[ $1 == 'incrFC' || $1 == 'incrDC' ]]; then
        TARGETDIR=$BACKUPDIR
    fi
    rsync ${rsyncOPTS} ${BCKPOBJ} ${TARGETDIR}
    if [[ $? != 0 ]]; then
        ((NUMERRORS++))
        ERRORFUNCTION+=("${ALIASHOST} - Error sincronizando: ${BCKPOBJ} - ${BACKUPDIR}\n")
    fi
}

function setRsyncOptions(){
    case $1 in
        incrFNC)
            rsyncOPTS="-ab --checksum --backup-dir=${BACKUPDIR} --relative"
            ;;
        fullF*|incrFC)
            rsyncOPTS="-a --relative"
            ;;
        incrDNC)
            genExcludes $2
            rsyncOPTS="-ab --checksum ${EXCLUDE} --delete --backup-dir=${BACKUPDIR} --relative"
            ;;
        fullD*|incrDC)
            genExcludes $2
            rsyncOPTS="-a ${EXCLUDE} --relative"
            ;;
    esac
    rsyncNow $1 $2
}

function encryptObject(){
    targetObject=$(cut -d':' -f3 <<< $1)
    targetFullPath="${BACKUPDIR}/${targetObject/\//}"
    targetTar="${targetFullPath}.tar.gz"
    targetEncryptedTar="${BACKUPDIR}/${targetObject//\//-}.ENCRYPTED.tar.gz"
    tar czf "${targetFullPath}.tar.gz" "${targetFullPath}" &>/dev/null
    openssl smime -encrypt -binary -aes-256-cbc -in ${targetTar} -out ${targetEncryptedTar} -outform DER ${OPENSSL_PUBKEY}
    rm -rf ${targetFullPath} ${targetTar}
}

function mainRsync(){
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            storSecurity=$(cut -d':' -f2 <<< ${linea})
            setRsyncOptions ${1}${objectType^^}${storSecurity} ${linea}
            if [[ ${storSecurity^^} == 'C' ]]; then
                encryptObject ${linea}
            fi
        fi
    done < $HOSTFILENAME
}

function checkArgs(){
    if [[ ${ARGUMENTS} == '--secondary-stor' ]]; then
        uploadBackupDir ${ALIASHOST} ${BACKUPDIR} ${1}
    fi
}

function sendError(){
    while IFS= read linea; do
        mail -s "Error: $1" $linea < ${LOGFILE}
    done < ${MAILLIST}
}

function makeBackup(){
    getRemoteHost
    currentDate=$(date +%s)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        setVars "${remoteHost}" "${currentDate}" $1
        mainRsync $1
        checkArgs $1
    done
    if [[ ${NUMERRORS} == 0 ]]; then
        MSG=("OK:$currentDate\n")
        printf "$MSG" > $LOGFILE
    else
        MSG=("ERROR:$currentDate.\nError mientras se hacia la copia de seguridad.\n")
        for errormsg in "${ERRORFUNCTION[@]}"; do
            MSG+=$errormsg
        done
        printf "$MSG" > $LOGFILE
        sendError $currentDate
    fi
}

function genPkgList(){
    case ${OSDISTRO,,} in
        debian|ubuntu)
            PKGCMD='dpkg --get-selections'
            ;;
        centos)
            PKGCMD='yum list installed'
            ;;
    esac
    ssh ${REMOTEUSERNAME}@${HOSTIP} "$PKGCMD > $PKGLISTNAME"
}


function pkgSave(){
    getRemoteHost
    currentDate=$(date +%s)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        setVars "${remoteHost}" "${currentDate}"
        genPkgList
    done
}

function calcSecs(){
    case $1 in
        *y)
            LIMITTIME=${1%y}
            LIMITTIME=$(( LIMITTIME * 365 * 24 * 3600 ))
            ;;
        *m)
            LIMITTIME=${1%m}
            LIMITTIME=$(( LIMITTIME * 30 * 24 * 3600 ))
            ;;
        *w)
            LIMITTIME=${1%w}
            LIMITTIME=$(( LIMITTIME * 7 * 24 * 3600 ))
            ;;
        *d)
            LIMITTIME=${1%d}
            LIMITTIME=$(( LIMITTIME * 24 * 3600 ))
            ;;
        *h)
            LIMITTIME=${1%h}
            LIMITTIME=$(( LIMITTIME * 3600 ))
            ;;
        *s)
            LIMITTIME=${1%s}
            ;;
    esac
    printf "$LIMITTIME\n"
}

function cleanSecondaryNow(){
    secRemUser=$(cut -d':' -f2 <<< $1)
    secRemHost=$(cut -d':' -f3 <<< $1)
    secRemDir="$(cut -d':' -f4 <<< $1)/${2}/${3%Sync}"
    secFullPath="${secRemDir}/${4}-${2}-${3%Sync}.tar.gz"
    ssh ${secRemUser}@${secRemHost} "rm ${secFullPath}"
}

function cleanSecondary(){
    while IFS= read -r linea; do
        cleanSecondaryNow ${linea} $2 $3 $1
    done < ${SECONDARY_HOSTS_FILE}
}

function cleanDirNow(){
    fullPath="${BASE_STOR}/${ALIASHOST}/$1"
    COMPTIME=$(calcSecs $2)
    actualDir=${ARGUMENTS}
    for backUPDir in ${fullPath}/*; do
        compDir=${backUPDir##*/}
        diffTime=$((actualDir - compDir))
        if [[ $diffTime -gt $COMPTIME ]]; then
            rm -rf $backUPDir
            if [[ $CLEANARG == '--secondary-stor' ]]; then
                cleanSecondary $compDir ${ALIASHOST} $1
            fi
        fi
    done
}

function cleanUp(){
    getRemoteHost
    currentDate=$(date +%s)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        setVars "${remoteHost}" "${currentDate}"
        if [[ $1 == 'incr' ]]; then
            cleanDirNow incrSync $INCRTIME
        elif [[ $1 == 'full' ]]; then
            cleanDirNow fullSync $FULLTIME
        fi
    done
}

function main(){
    checkConfig
    case ${BACKUPTYPE,,} in
        full)
            pkgSave
            makeBackup full
            ;;
        incr)
            pkgSave
            makeBackup incr
            ;;
        pkgsave)
            pkgSave
            ;;
        cleanincr)
            cleanUp incr
            ;;
        cleanfull)
            cleanUp full
            ;;
        *)
            printf 'Error en el comando\n'
            ;;
    esac
}

[[ $LASTOPT == '-d' ]] && set -x
main
[[ $LASTOPT == '-d' ]] && set +x
