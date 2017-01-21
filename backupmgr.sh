#!/usr/bin/env bash

# Variables globales y de entorno
# ###############################
REMOTE_HOSTS=()

# Directorio base para el almacén de las copias de seguridad
# Se puede cambiar estableciendo la variable del entorno BASE_STOR
BASE_STOR=${BASE_STOR:-/BackUps}

# Directorio de configuración de la aplicación
# Se puede cambiar estableciendo la variable del entorno BACKUPMGR_CONFIG_DIR
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}

# Fichero con la definición de host remotos con formato: 'alias:usuario:IP'
# Se puede cambiar este fichero estableciendo la variable del entorno REMOTE_HOSTS_FILE
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"

# cada host tiene asociado un fichero, de nombre el alias dado a la IP,
# Se puede cambiar este directorio estableciendo la variable del entorno REMOTE_HOSTS_DIR
# en el directorio de la aplicación $REMOTE_HOSTS_DIR con formato por línea:
# (tipo de archivo: F-> Fichero, D-> Directorio):(Almacen cifrado: C, No cifrado: NC):(Ruta completa al fichero o directorio)[:(Excluir: E:F:RUTA)],
# quedando así: <F|D>:<C|NC>:<Ruta>[:E:Ruta-o-fichero1:ruta-o-fichero-2:...], por ejemplo:
# F:NC:/etc/fstab
# D:C:/etc/ldap:E:/etc/ldap/schema:/etc/fstab
# D:NC:/var/cache/bind
# NOTA: las exclusiones solo se aplican a objetos directorios, las exclusiones pueden ser ficheros o directorios
# Se permite el uso de comentarios en las líneas siempre que estas empiecen por #
REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"

# Lista de hosts de almacenamiento secundarios
# Se admiten varios destinos
# formato:
# alias:usuario:ip:/ruta-absoluta
# ejemplo:
# saturno:malcocer:172.22.111.11:/Backup-ASO/malcocer
SECONDARY_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${SECONDARY_HOSTS_FILE:-/secondary_hosts.list}"

# Captura de parámetros
COMMAND=$1
LASTOPT=${@: -1}
OPTIONS=$2

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
    if [[ ! -f ${SECONDARY_HOSTS_FILE} ]]; then
        printf "No existe el fichero de almacenamiento secundario ${SECONDARY_HOSTS_FILE}\n"
        exitWithErr
    fi
}

# Generar lista de exclusiones
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

# ############################################ #
# ZONA DE SUBIDA A ALMACENAMIENTOS SECUNDARIOS #
# ############################################ #
function uploadBackupDir(){
    temporaryTar=/tmp/${2##*/}-${1}-${3}.tar.gz
    tar czf ${temporaryTar} ${2}
    while IFS= read -r linea; do
        rsyncToSecondary ${linea} $1 $3 ${temporaryTar}
    done < ${SECONDARY_HOSTS_FILE}
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

# ##############################################
# ##############################################

# Creación de variables para rutas de respaldo y destino
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
    # 1:tipo, 2: usuario, 3:ip, 4:linea-completa, 5:destino local, 6:destino backup
    # Configuración de opciones para completa o incremental 
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
    # Si la IP es localhost, el respaldo es local
    if [[ ${HOSTIP,,} != 'localhost' ]]; then
        BCKPOBJ="${REMOTEUSERNAME}@${HOSTIP}:${BCKPOBJ}"
    fi
    # Ejecución del respaldo
    rsync ${rsyncOPTS} ${BCKPOBJ} ${TARGETDIR}
}

function mainRsync(){
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            case ${objectType,,} in
                f)
                    #rsyncObjects ${1}F ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR} ${BACKUPDIR}
                    rsyncObjects ${1}F ${linea}
                    ;;
                d)
                    #rsyncObjects ${1}D ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR} ${BACKUPDIR}
                    rsyncObjects ${1}D ${linea}
                    ;;
            esac
        fi
    done < $HOSTFILENAME
    if [[ ${OPTIONS} == '--secondary-stor' ]]; then
        uploadBackupDir ${ALIASHOST} ${BACKUPDIR} ${1}
    fi
}

# ########################### #
# ZONA DE RESPALDOS COMPLETOS #
# ########################### #
function fullRsync(){
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            case ${objectType,,} in
                f)
                    rsyncObjects fullF ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR}
                    ;;
                d)
                    rsyncObjects fullD ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR}
                    ;;
            esac
        fi
    done < $HOSTFILENAME
    if [[ ${OPTIONS} == '--secondary-stor' ]]; then
        uploadBackupDir ${ALIASHOST} ${TARGETDIR} full
    fi
}

# Función principal de backups completos
# ######################################
function fullBackup(){
    getRemoteHost
    currentDate=$(date +%y-%U-%m%d-%H%M)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        createVars "${remoteHost}" "${currentDate}" full
        fullRsync
    done
}

# ############################# #
# ZONA DE BACKUPS INCREMENTALES #
# ############################# #
function incrRsync(){
    while IFS= read -r linea; do
        if [[ ! ${linea} =~ ^[[:space:]]*#.* ]]; then
            objectType=$(cut -d':' -f1 <<< ${linea})
            case ${objectType,,} in
                f)
                    rsyncObjects incrF ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR} ${BACKUPDIR}
                    ;;
                d)
                    rsyncObjects incrD ${REMOTEUSERNAME} ${HOSTIP} ${linea} ${TARGETDIR} ${BACKUPDIR}
                    ;;
            esac
        fi
    done < $HOSTFILENAME
    if [[ ${OPTIONS} == '--secondary-stor' ]]; then
        uploadBackupDir ${ALIASHOST} ${BACKUPDIR} incr
    fi
}

# Función principal de backups incrementales
# ##########################################
function incrementalBackup(){
    getRemoteHost
    currentDate=$(date +%y-%U-%m%d-%H%M)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        createVars "${remoteHost}" "${currentDate}" incr
        incrRsync
    done
}

function makeBackup(){
    getRemoteHost
    currentDate=$(date +%y-%U-%m%d-%H%M)
    for remoteHost in "${REMOTE_HOSTS[@]}"; do
        createVars "${remoteHost}" "${currentDate}" incr
        mainRsync $1
    done
}

# ############################ #
# FUNCIÓN DE LLAMADA PRINCIPAL #
# ############################ #
function main(){
    # comprobar ficheros necesarios
    checkConfig
    # Obtener IPS de equipos remotos
    case ${COMMAND,,} in
        full)
            #fullBackup $OPTIONS
            makeBackup full
            ;;
        incr)
            #incrementalBackup $OPTIONS
            makeBackup incr
            ;;
    esac
}

# Llamada principal
[[ $LASTOPT == '-d' ]] && set -x
main $OPTIONS
[[ $LASTOPT == '-d' ]] && set +x
