#!/usr/bin/env bash

REMOTE_HOSTS=()
BASE_STOR=${BASE_STOR:-/BackUps}
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"
REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"
SECONDARY_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${SECONDARY_HOSTS_FILE:-/secondary_hosts.list}"
OPENSSL_PUBKEY="${BACKUPMGR_CONFIG_DIR}${OPENSSL_PUBKEY:-/backupmgr.pubkey.pem}"

BACKUPTYPE=$1
LASTOPT=${@: -1}
ARGUMENTS="${@:2}"

EXCLUDE=()

ALIASHOST=''
HOSTFILENAME=''
REMOTEUSERNAME=''
HOSTIP=''
BACKUPDIR=''
TARGETDIR=''

function exitWithErr(){
    printf 'Hubieron errores...Saliendo\n'
    exit 1
}

function getRemoteHost(){
    while IFS= read -r linea; do
        REMOTE_HOSTS+=("${linea}")
    done < ${REMOTE_HOSTS_FILE}
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

function uploadBackupDir(){
    temporaryTar=/tmp/${2##*/}-${1}-${3}.tar.gz
    tar czf ${temporaryTar} ${2}
    while IFS= read -r linea; do
        rsyncToSecondary ${linea} $1 $3 ${temporaryTar}
    done < ${SECONDARY_HOSTS_FILE}
    rm ${temporaryTar}
}

function rsyncToSecondary(){
    secRemUser=$(cut -d':' -f2 <<< $1)
    secRemHost=$(cut -d':' -f3 <<< $1)
    secRemDir="$(cut -d':' -f4 <<< $1)/${2}/${3}"
    rsync $4 ${secRemUser}@${secRemHost}:${secRemDir}
}

function lastFullRsync(){
    baseDir="${BASE_STOR}/${1}/fullSync"
    lastDir="$(ls -t ${baseDir} | head -n1)"
    printf "${lastDir}\n"
}

function createVars(){
    ALIASHOST=$(cut -d':' -f1 <<< $1)
    HOSTFILENAME="${REMOTE_HOSTS_DIR}/${ALIASHOST}"
    REMOTEUSERNAME=$(cut -d':' -f2 <<< $1)
    HOSTIP=$(cut -d':' -f3 <<< $1)
    if [[ $3 == 'full' ]]; then
        TARGETDIR="${BASE_STOR}/${ALIASHOST}/fullSync/${2}"
        BACKUPDIR="${TARGETDIR}"
    else
        TARGETDIR="${BASE_STOR}/${ALIASHOST}/fullSync/$(lastFullRsync ${ALIASHOST})"
        BACKUPDIR="${BASE_STOR}/${ALIASHOST}/incrSync/${2}"
    fi
}

function rsyncObjects(){
    case $1 in
        incrF)
            rsyncOPTS="-ab --checksum --backup-dir=${BACKUPDIR} --relative"
            ;;
        fullF)
            rsyncOPTS="-a --relative"
            ;;
        incrD)
            genExcludes $2
            rsyncOPTS="-ab --checksum ${EXCLUDE} --delete --backup-dir=${BACKUPDIR} --relative"
            ;;
        fullD)
            genExcludes $2
            rsyncOPTS="-a ${EXCLUDE} --relative"
            ;;
    esac
    if [[ ! -d ${TARGETDIR} ]]; then
        mkdir -p ${TARGETDIR}
    fi
    BCKPOBJ=$(cut -d':' -f3 <<< $2)
    if [[ ${HOSTIP,,} != 'localhost' ]]; then
        BCKPOBJ="${REMOTEUSERNAME}@${HOSTIP}:${BCKPOBJ}"
    fi
    rsync ${rsyncOPTS} ${BCKPOBJ} ${TARGETDIR}
}

function encryptObject(){
    targetObject=$(cut -d':' -f3 <<< $1)
    targetFullPath="${BACKUPDIR}/${targetObject/\//}"
    targetTar="${targetFullPath}.tar.gz"
    targetEncryptedTar="${BACKUPDIR}/${targetObject//\//-}.ENCRYPTED.tar.gz"
    tar czf "${targetFullPath}.tar.gz" "${targetFullPath}"
    openssl smime -encrypt -binary -aes-256-cbc -in ${targetTar} -out ${targetEncryptedTar} -outform DER ${OPENSSL_PUBKEY}
    #rm -rf ${targetFullPath} ${targetTar}
}

function mainRsync(){
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            rsyncObjects ${1}${objectType^^} ${linea}
            unset storSecurity
            storSecurity=$(cut -d':' -f2 <<< ${linea})
            if [[ ${storSecurity^^} == 'C' ]]; then
                encryptObject ${linea}
            fi
        fi
    done < $HOSTFILENAME
}

function removeBackups(){
    :
}

function checkArgs(){
    for argument in ${ARGUMENTS}; do
        case ${argument} in
            '--secondary-stor')
                uploadBackupDir ${ALIASHOST} ${BACKUPDIR} ${1}
                ;;
            '--remove')
                removeBackups ${ALIASHOST} ${BACKUPDIR} ${1}
                ;;
        esac
    done
}

function makeBackup(){
    getRemoteHost
    currentDate=$(date +%y-%U-%m%d-%H%M)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        createVars "${remoteHost}" "${currentDate}" $1
        mainRsync $1
        checkArgs $1
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
        *)
            printf 'Error en el comando\n'
            ;;
    esac
}

[[ $LASTOPT == '-d' ]] && set -x
main
[[ $LASTOPT == '-d' ]] && set +x
