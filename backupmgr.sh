#!/usr/bin/env bash

# Variables globales
REMOTE_HOSTS=()

# Directorio base para el almacén de las copias de seguridad
BASE_STOR=${BASE_STOR:-/BackUps}

# Directorio de configuración de la aplicación
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}

# Fichero con la definición de host remotos con formato: 'alias:usuario:IP'
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"

# cada host tiene asociado un fichero, de nombre el alias dado a la IP,
# en el directorio de la aplicación $REMOTE_HOSTS_DIR con formato por línea:
# (tipo de archivo: F-> Fichero, D-> Directorio):(Almacen cifrado: C, No cifrado: NC):(Ruta completa al fichero o directorio)[:(Excluir: E:F:RUTA)],
# quedando así: <F|D>:<C|NC>:Ruta[:E:F:Ruta], por ejemplo:
# F:NC:/etc/fstab
# D:C:/etc/ldap:E:F:/etc/ldap/schema
# D:NC:/var/cache/bind
# NOTA: las exclusiones solo se aplican a objetos directorios
REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"


# Captura de prámetros
COMMAND=$1

function exitWithErr(){
    printf 'Hubieron errores...Saliendo\n'
    exit 1
}

# Crear array con la lista de hosts
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
}

function rsyncCompleteFile(){
    # 1: usuario, 2:ip, 3:fichero, 4:destino local
    if [[ ! -d $4 ]]; then
        mkdir -p $4
    fi
    BCKPFILE=$(cut -d':' -f3 <<< $3)
    rsync -a --relative ${1}@${2}:${BCKPFILE} $4
}

function rsyncCompleteDir(){
    :
}

function completeRsync(){
    aliasHost=$(cut -d':' -f1 <<< $1)
    hostFile="${REMOTE_HOSTS_DIR}/${aliasHost}"
    remoteUser=$(cut -d':' -f2 <<< $1)
    hostIP=$(cut -d':' -f3 <<< $1)
    targetDir="${BASE_STOR}/${aliasHost}/fullSync/${2}"
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            case ${objectType,,} in
                f)
                    rsyncCompleteFile ${remoteUser} ${hostIP} ${linea} ${targetDir}
                    ;;
                d)
                    rsyncCompleteDir ${remoteUser} ${hostIP} ${linea} ${targetDir}
                    ;;
            esac
        fi
    done
}

function completeBackup(){
    getRemoteHost
    currentDate=$(date +%y%m%d%H%M)
    for remoteHost in "${REMOTE_HOSTS}"; do
        completeRsync ${remoteHost} ${currentDate}
    done
}

function main(){
    # comprobar ficheros necesarios
    checkConfig
    # Obtener IPS de equipos remotos
    if [[ ${COMMAND,,} == 'completa' ]]; then
        completeBackup
    fi
}

main
