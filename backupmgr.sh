#!/usr/bin/env bash

# Variables globales
REMOTE_HOSTS=()
BASE_STOR=${BASE_STOR:-/BackUps}
REMOTE_HOSTS_FILE=${REMOTE_HOSTS_FILE:-/etc/backupMgr/hosts.list}

# Captura de prámetros
COMMAND=$1

function ERROREXIT(){
    printf 'Hubieron errores...Saliendo\n'
    exit 1
}

#
function getHostIPS(){
    :
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
    checkConfig
    if [[ ${COMMAND,,} == 'completa' ]]; then
        :
    fi
}

main
