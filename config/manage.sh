#!/bin/bash
#
# Docker-Compose app management commands
# Globals:
#   PAAS_APP_DOMAIN
#   PAAS_ADD_DIR
#   PAAS_HIPACHE_DIR

readonly REDISCLI='docker run --link hipache_redis_1:redis redis:2.8 redis-cli -h redis'
readonly DOCKER0_IP=$(
  ifconfig docker0 \
    | grep "inet addr" \
    | awk -F: '{print $2}' \
    | awk '{print $1}'
)

#######################################
# Starts the Hipache proxy container
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function hipache_start {
  echo "Entering ${PAAS_HIPACHE_DIR}..."
  cd ${PAAS_HIPACHE_DIR}

  echo "Starting hipache..."
  docker-compose build
  docker-compose up -d
}

#######################################
# Update Hipache routing configuration
# Globals:
#   PAAS_APP_DOMAIN
#   REDISCLI
#   DOCKER0_IP
# Arguments:
#   $1 app name
#   $2 app ports (new line seperated)
# Returns:
#   None
#######################################
function hipache_frontend_update {
  local -r BASENAME=$1
  local -r HOSTNAME="$1.${PAAS_APP_DOMAIN}"
  local -r PORTS="$2"

  ${REDISCLI} DEL frontend:${HOSTNAME}
  ${REDISCLI} RPUSH frontend:${HOSTNAME} ${BASENAME}

  while read -r line; do
    port=`echo ${line} | awk -F: '{print $2}'`
    addr="http://$DOCKER0_IP:$port"

    ${REDISCLI} RPUSH frontend:${HOSTNAME} $addr

  done < <(echo "$PORTS")

  ${REDISCLI} LRANGE frontend:${HOSTNAME} 0 -1
}

#######################################
# Set environment variable for application
#######################################
# Globals:
#   PAAS_APP_DOMAIN
# Arguments:
#   $1 app name
#   $2 environment variable key
#   $2 environment variable val
# Returns:
#   None
function hipache_config_set {
  local -r HOSTNAME="$1.${PAAS_APP_DOMAIN}"
  local -r KEY="$2"
  local -r VAL="$3"

  if [[ ${VAL} ]]; then
    ${REDISCLI} HSET config:${HOSTNAME} ${KEY} "${VAL}"
  else
    ${REDISCLI} HDEL config:${HOSTNAME} ${KEY}
  fi
}

#######################################
# Get environment variables for application
#######################################
function hipache_config_get {
  local -r HOSTNAME="$1.${PAAS_APP_DOMAIN}"

  while read -r line; do
    if [[ ${key} ]]; then
      echo "${key}=${line}"
      unset -v key
    else
      key=${line}
    fi
  done < <(${REDISCLI} HGETALL config:${HOSTNAME})
}

#######################################
# Start application
#######################################
function app_start {
  local -r BASENAME=$(basename $1)

  echo "Entering $1..."
  cd $1

  # Create a subshell to prevent poluting our environment since we need to
  # export the necessary environemnt variables for this application.
  (
    echo "Fetching environment..."
    while read -r env; do
      echo ${env}
      export ${env}
    done < <(hipache_config_get ${BASENAME})

    echo "Starting containers..."
    docker-compose build
    docker-compose up -d
  )

  echo "Updating routes..."
  hipache_frontend_update ${BASENAME} $(docker-compose port www 8080)
}

#######################################
# Stop application
# TODO:
#   Remove application from Hipache
#######################################
function app_stop {
  echo "Entering $1..."
  cd $1

  echo "Stopping containers..."
  docker-compose stop
  docker-compose rm --force
}

#######################################
# CLI definition
#######################################
case "$1" in
  start)
    for path in ${PAAS_APP_DIR}/*; do
      app_start ${path}
    done

    exit 0
    ;;

  stop)
    for path in ${PAAS_APP_DIR}/*; do
      app_stop ${path}
    done

    exit 0
    ;;

  config)
    APP=$2
    KEY=$3
    VAL=$4

    if [[ ${APP} ]]; then
      if [[ ${KEY} && ${VAL} ]]; then
        if [[ ${VAL} == "--rm" ]]; then
          hipache_config_set ${APP} ${KEY}
        else
          hipache_config_set ${APP} ${KEY} ${VAL}
        fi
      else
        hipache_config_get ${APP} # ${KEY}
      fi
    else
      echo "Usage: manage.sh config APP KEY [VAL]"
      exit 1
    fi
    ;;

  hipache)
    case $2 in
      "start")
        hipache_start
        exit 0
        ;;

      "stop")
        echo "Command Error: Not Implemented"
        exit 1
        ;;

      *)
        echo "Usage: manage.sh hipache [stop|start]"
        exit 1
        ;;
    esac
    ;;

  *)
    echo "Usage: manage.sh [start|stop]"
    exit 1
    ;;
esac

