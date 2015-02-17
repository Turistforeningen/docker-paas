#!/bin/bash
#
# Docker-Compose app management commands
# Globals:
#   PAAS_APP_DOMAIN
#   PAAS_APP_DIR
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
# Remove Hipache routing configuration
# Globals:
#   REDISCLI
# Arguments:
#   $1 app name
# Returns:
#   None
#######################################
function hipache_frontend_remove {
  local -r BASENAME=$1
  local -r HOSTNAME="$1.${PAAS_APP_DOMAIN}"

  ${REDISCLI} DEL frontend:${HOSTNAME}
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
# Arguments:
#   - $1 APP_NAME
#   - $2 APP_PATH
#   - $3 REBUILD
#######################################
function app_start {
  local -r APP_NAME=$1
  local -r APP_PATH=$2
  local -r REBUILD=$3

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  # Create a subshell to prevent poluting our environment since we need to
  # export the necessary environemnt variables for this application.
  (
    echo "Fetching environment..."
    while read -r env; do
      echo ${env}
      export ${env}
    done < <(hipache_config_get ${APP_NAME})

    if [[ ${REBUILD} ]]; then
      echo "(Re)building containers..."
      docker-compose pull && docker-compose build || exit 1
    fi

    echo "Starting containers..."
    docker-compose up -d || exit 1
  )

  echo "Updating routes..."
  hipache_frontend_update ${APP_NAME} $(docker-compose port www 8080)
}

#######################################
# Stop application
# Arguments:
#   - $1 APP_NAME
#   - $2 APP_PATH
#   - $3 RM
#######################################
function app_stop {
  local -r APP_NAME=$1
  local -r APP_PATH=$2

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  echo "Stopping containers..."
  docker-compose stop || exit 1

  if [[ $3 ]]; then
    echo "Removing container data..."
    docker-compose rm --force || exit 1
  fi

  echo "Updating routes..."
  hipache_frontend_remove ${APP_NAME}
}

#######################################
# CLI definition
# Arguments:
#   - $1 APP_NAME
#   - $2 CMD
#######################################

APP_NAME=$1

# Is it hipache you
if [[ ${APP_NAME} == "hipache" ]]; then
  APP_PATH="${PAAS_HIPACHE_DIR}"
else
  APP_PATH="${PAAS_APP_DIR}/${APP_NAME}"
fi

# Check if app exists
if [[ ! -d "${APP_PATH}" && $2 != "add" ]]; then
  echo "The application '${APP_NAME}' does not exist!"
  exit 1
fi

# CLI commands
case "$2" in
  add)
    if [[ $3 == "-h" || $3 == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] add [GIT_REPO] [GIT_BRANCH]"
      exit 0
    fi

    echo "Add not implemented"
    exit 1
    ;;

  config)
    if [[ $3 == "-h" || $3 == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] config [KEY [VAL|--rm]]"
      exit 0
    fi

    APP_CONFIG_KEY=$3
    APP_CONFIG_VAL=$4

    if [[ ${APP_CONFIG_KEY} && ${APP_CONFIG_VAL} ]]; then
      if [[ ${APP_CONFIG_VAL} == "--rm" ]]; then
        hipache_config_set ${APP_NAME} ${APP_CONFIG_KEY}
        exit 0
      else
        hipache_config_set ${APP_NAME} ${APP_CONFIG_KEY} ${APP_CONFIG_VAL}
        exit 0
      fi
    else
      hipache_config_get ${APP_NAME}
      exit 0
    fi

    ;;

  start)
    APP_START_HARD=false
    APP_START_SOFT=false

    if [[ $3 == "-h" || $3 == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] start [--rebuild]"
      exit 0
    fi

    for arg; do
      if [[ $arg == "--rebuild" ]]; then
        APP_START_HARD=true
      fi
    done

    if [[ $APP_NAME == "hipache" ]]; then
      hipache_start
      exit 0
    else
      app_start $APP_NAME $APP_PATH $APP_START_HARD
      exit 0
    fi

    ;;

  status)
    echo "Status not implemeted"
    exit 1
    ;;

  stop)
    APP_STOP_RM=false

    for arg; do
      if [[ $arg == "--rm" ]]; then
        APP_STOP_RM=true
      fi
    done

    app_stop $APP_NAME $APP_PATH $APP_STOP_RM
    exit 0
    ;;

  *)
    cat << EOF
Docker PaaS by @turistforeningen

Usage:
  docker-paas [APPLICATION] [COMMAND] [ARGS...]
  docker-paas -h|--help

Commands:
  add     Add a new application
  config  Manage app environment variables
  run     Run command on application
  start   Start existing application
  status  Get status of application
  stop    Stop running application
EOF
    exit 1
    ;;
esac

