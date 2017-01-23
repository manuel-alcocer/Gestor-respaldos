#!/usr/bin/env bash

REMOTE_HOSTS=()
BASE_STOR=${BASE_STOR:-/BackUps}
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"
REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"
SECONDARY_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${SECONDARY_HOSTS_FILE:-/secondary_hosts.list}"
OPENSSL_PUBKEY="${BACKUPMGR_CONFIG_DIR}${OPENSSL_PUBKEY:-/backupmgr.pubkey.pem}"

PKGLISTNAME='listado-paquetes.list.txt'

BACKUPTYPE=$1
LASTOPT=${@: -1}
ARGUMENTS=$2

EXCLUDE=()

ALIASHOST=''
HOSTFILENAME=''
REMOTEUSERNAME=''
HOSTIP=''
BACKUPDIR=''
TARGETDIR=''
OSDISTRO=''
FULLTIME=''
INCRTIME=''

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
}

function uploadBackupDir(){
    temporaryTar=/tmp/${2##*/}-${1}-${3}.tar.gz
    tar czf ${temporaryTar} ${2}
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
    tar czf "${targetFullPath}.tar.gz" "${targetFullPath}"
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
    for argument in ${ARGUMENTS}; do
        case ${argument} in
            '--secondary-stor')
                uploadBackupDir ${ALIASHOST} ${BACKUPDIR} ${1}
                ;;
        esac
    done
}

function makeBackup(){
    getRemoteHost
    currentDate=$(date +%s)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        setVars "${remoteHost}" "${currentDate}" $1
        mainRsync $1
        checkArgs $1
    done
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
            daysOfYear=$(date -d "$(date +%Y)-12-31" +%j)
            LIMITTIME=$(( LIMITTIME * ${daysOfYear} * 24 * 3600 ))
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
    esac
    printf "$LIMITTIME\n"
}

function cleanIncr(){
    fullPath="${BASE_STOR}/${ALIASHOST}/incrSync"
    cd $fullPath
    INCRTIME=$(calcSecs $INCRTIME)
    for backUPDir in *; do
        diffTime=$((ARGUMENTS - backUPDir))
        if [[ $diffTime > INCRTIME ]]; then
            :
        fi
        printf "ARG: $ARGUMENTS\n"
        printf "backUPDir: ${backUPDir}\n"
        printf "diff: ${diffTime}"
    done
    print "${INCRTIME}\n"
}

function cleanUp(){
    getRemoteHost
    currentDate=$(date +%s)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        setVars "${remoteHost}" "${currentDate}"
        if [[ $1 == 'incr' ]]; then
            cleanIncr
        elif [[ $1 == 'full' ]]; then
            cleanFull
        fi
    done
}

function main(){
    checkConfig
    case ${BACKUPTYPE,,} in
        full)
            makeBackup full
            ;;
        incr)
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
