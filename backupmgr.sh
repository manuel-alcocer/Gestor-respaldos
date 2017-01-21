#!/usr/bin/env bash

# Variables globales
REMOTE_HOSTS=()

# Directorio base para el almacén de las copias de seguridad
BASE_STOR=${BASE_STOR:-/BackUps}

# Directorio de configuración de la aplicación
BACKUPMGR_CONFIG_DIR=${BACKUPMGR_CONFIG_DIR:-/etc/backupMgr}

# Fichero con la definición de host remotos con formato: 'alias:IP'
REMOTE_HOSTS_FILE="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_FILE:-/hosts.list}"
# cada host tiene asociado un fichero, de nombre el alias dado a la IP,
# en el directorio de la aplicación $REMOTE_HOSTS_DIR con formato por línea:
# (tipo de archivo: F-> Fichero, D-> Directorio):(Almacen cifrado: C, No cifrado: NC):(Ruta completa al fichero o directorio)[:(Excluir: E:F:RUTA)],
# quedando así: <F|D>:<C|NC>:Ruta[:E:F:Ruta], por ejemplo:
# F:NC:/etc/fstab
# D:C:/etc/ldap:E:F:/etc/ldap/schema
# D:NC:/var/cache/bind
# NOTA: Es de perogrullo decir que las exclusiones solo se aplican a objetos directorios

REMOTE_HOSTS_DIR="${BACKUPMGR_CONFIG_DIR}${REMOTE_HOSTS_DIR:-/hosts.list.d}"

# Captura de prámetros
COMMAND=$1

function ERROREXIT(){
    printf 'Hubieron errores...Saliendo\n'
    exit 1
}

#
function getRemoteHost(){
    while IFS= read -r linea; do
        REMOTE_HOSTS+=("${linea}")
    done
}

function checkConfig(){
    if [[ ! -f ${REMOTE_HOSTS_FILE} ]]; then
        printf "No existe el fichero de hosts remotos ${REMOTE_HOSTS_FILE}\n"
        ERROREXIT
    fi
    if [[ ! -d ${BASE_STOR} ]]; then
        printf "No existe la ruta de almacenamiento local ${BASE_STOR}\n"
        ERROREXIT
    fi

}

function main(){
    # comprobar ficheros necesarios
    checkConfig
    # Obtener IPS de equipos remotos
    getRemoteHost
    if [[ ${COMMAND,,} == 'completa' ]]; then
        :
    fi
}

main
