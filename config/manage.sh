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
# Update Hipache routing configuration
# Globals:
#   PAAS_APP_DOMAIN
#   REDISCLI
#   DOCKER0_IP
# Arguments:
#   1 APP_NAME
#   2 APP_PORTS (new line seperated)
# Returns:
#   None
#######################################
function hipache_frontend_update {
  local -r APP_NAME=$1
  local -r APP_HOSTNAME="$1.${PAAS_APP_DOMAIN}"
  local -r APP_PORTS="$2"

  ${REDISCLI} DEL frontend:${APP_HOSTNAME}
  ${REDISCLI} RPUSH frontend:${APP_HOSTNAME} ${APP_NAME}

  while read -r line; do
    port=`echo ${line} | awk -F: '{print $2}'`
    addr="http://$DOCKER0_IP:$port"

    ${REDISCLI} RPUSH frontend:${APP_HOSTNAME} $addr

  done < <(echo "$APP_PORTS")

  ${REDISCLI} LRANGE frontend:${APP_HOSTNAME} 0 -1
}

#######################################
# Remove Hipache routing configuration
# Globals:
#   PAAS_APP_DOMAIN
#   REDISCLI
# Arguments:
#   1 APP_NAME
# Returns:
#   None
#######################################
function hipache_frontend_remove {
  local -r APP_NAME=$1
  local -r APP_HOSTNAME="$1.${PAAS_APP_DOMAIN}"

  ${REDISCLI} DEL frontend:${APP_HOSTNAME}
}

#######################################
# Set environment variable for application
# Globals:
#   PAAS_APP_DOMAIN
#   REDIS_CLI
# Arguments:
#   1 APP_NAME
#   2 KEY - environment variable key
#   2 VAL - environment variable val
# Returns:
#   None
#######################################
function hipache_config_set {
  local -r APP_HOSTNAME="$1.${PAAS_APP_DOMAIN}"
  local -r KEY="$2"
  local -r VAL="$3"

  if [[ ${VAL} ]]; then
    ${REDISCLI} HSET config:${APP_HOSTNAME} ${KEY} "${VAL}"
  else
    ${REDISCLI} HDEL config:${APP_HOSTNAME} ${KEY}
  fi
}

#######################################
# Get environment variables for application
# Globals:
#   PAAS_APP_DOMAIN
#   REDIS_CLI
# Arguments:
#   1 APP_NAME
# Returns:
#   None
#######################################
function hipache_config_get {
  local -r APP_HOSTNAME="$1.${PAAS_APP_DOMAIN}"

  while read -r line; do
    if [[ ${key} ]]; then
      echo "${key}=${line}"
      unset -v key
    else
      key=${line}
    fi
  done < <(${REDISCLI} HGETALL config:${APP_HOSTNAME})
}

#######################################
# Create new application
# Globals:
#   None
# Arguments:
#   1 APP_NAME
#   2 APP_PATH
#   3 APP_REPO
#   4 APP_BRANCH
# Returns:
#   None
#######################################
function app_create {
  local -r APP_NAME=$1
  local -r APP_PATH=$2
  local -r APP_REPO=$3
  local -r APP_BRANCH=$4

  echo "Cloning repository..."
  git clone -v --single-branch --branch ${APP_BRANCH} -- ${APP_REPO} ${APP_PATH}

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  echo "Updating submodules..."
  git submodule init
  git submodule update
}

#######################################
# Start application
# Globals:
#   None
# Arguments:
#   1 APP_NAME
#   2 APP_PATH
#   3 CONTAINER_REBUILD
#   4 ROUTE_UPDATE
# Returns:
#   None
#######################################
function app_start {
  local -r APP_NAME=$1
  local -r APP_PATH=$2
  local -r CONTAINER_REBUILD=$3
  local -r ROUTE_UPDATE=$4

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  # Create a subshell to prevent poluting our environment since we need to
  # export the necessary environemnt variables for this application.
  (
    # Skip fetching environment if it's hipache we're starting
    if [[ ${APP_NAME} != "hipache" ]]; then
      echo "Fetching environment..."
      while read -r env; do
        echo ${env}
        export ${env}
      done < <(hipache_config_get ${APP_NAME})
    fi

    if [[ "${CONTAINER_REBUILD}" == "true" ]]; then
      echo "(Re)building containers..."
      docker-compose pull && docker-compose build || exit 1
    fi

    echo "Starting containers..."
    docker-compose up -d || exit 1
  )

  if [[ "${ROUTE_UPDATE}" == "true" ]]; then
    echo "Updating routes..."
    hipache_frontend_update ${APP_NAME} $(docker-compose port www 8080)
  fi
}

#######################################
# Stop application
# Globals:
#   None
# Arguments:
#   1 APP_NAME
#   2 APP_PATH
#   3 CONTAINER_RM
#   4 ROUTE_UPDATE
# Returns:
#   None
#######################################
function app_stop {
  local -r APP_NAME=$1
  local -r APP_PATH=$2
  local -r CONTAINER_RM=$3
  local -r ROUTE_UPDATE=$4

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  echo "Stopping containers..."
  docker-compose stop || exit 1

  if [[ "${CONTAINER_RM}" == "true" ]]; then
    echo "Removing container data..."
    docker-compose rm --force || exit 1
  fi

  if [[ "${ROUTE_UPDATE}" == "true" ]]; then
    echo "Updating routes..."
    hipache_frontend_remove ${APP_NAME}
  fi
}

function app_run {
  local -r APP_NAME=$1
  local -r APP_PATH=$2
  local -r APP_WORKER=$3
  local -r APP_CMD=${@:4}

  echo "Entering ${APP_PATH}..."
  cd ${APP_PATH}

  # Create a subshell to prevent poluting our environment since we need to
  # export the necessary environemnt variables for this application.
  (
    # Skip fetching environment if it's hipache we're starting
    if [[ ${APP_NAME} != "hipache" ]]; then
      echo "Fetching environment..."
      while read -r env; do
        export ${env}
      done < <(hipache_config_get ${APP_NAME})
    fi

    echo "Executing command..."
    docker-compose run ${APP_WORKER} ${APP_CMD}
  )
}

#######################################
# CLI definition
# Arguments:
#   1 APP_NAME
#   2 CMD
#######################################
APP_NAME=$1
CMD=$2

# Is it hipache you
if [[ "${APP_NAME}" == "hipache" ]]; then
  APP_PATH="${PAAS_HIPACHE_DIR}"
else
  APP_PATH="${PAAS_APP_DIR}/${APP_NAME}"
fi

# Check if app does not exist
if [[ ! -d "${APP_PATH}" && "${CMD}" != "add" ]]; then
  echo "The application '${APP_NAME}' does not exist!"
  exit 1
fi

# Check if app does exists when creating a new app
if [[   -d "${APP_PATH}" && "${CMD}" == "add" ]]; then
  echo "The application name '${APP_AME}' has already been taken!"
  exit 1
fi

# CLI commands
case "${CMD}" in
  add)
    if [[ "$3" == "-h" || "$3" == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] add [GIT_REPO] [GIT_BRANCH]"
      exit 0
    fi

    APP_REPO=$3
    APP_BRANCH=$4

    if [[ -z ${APP_BRANCH} ]]; then
      APP_BRANCH=master
    fi

    app_create ${APP_NAME} ${APP_PATH} ${APP_REPO} ${APP_BRANCH}
    ;;

  config)
    if [[ "$3" == "-h" || "$3" == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] config [KEY [VAL|--rm]]"
      exit 0
    fi

    APP_CONFIG_KEY=$3
    APP_CONFIG_VAL=$4

    if [[ ${APP_CONFIG_KEY} && ${APP_CONFIG_VAL} ]]; then
      if [[ "${APP_CONFIG_VAL}" == "--rm" ]]; then
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

  run)
    if [[ "$3" == "-h" || "$3" == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] run [WORKER] [CMD..]"
      exit 0
    fi

    APP_WORKER=$3
    APP_CMD=${@:4}

    app_run ${APP_NAME} ${APP_PATH} ${APP_WORKER} ${APP_CMD}
    exit 0
    ;;

  start)
    if [[ "$3" == "-h" || "$3" == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] start [--rebuild]"
      exit 0
    fi

    APP_START_REBUILD=false
    APP_START_ROUTE_UPDATE=true

    for arg; do
      if [[ "${arg}" == "--rebuild" ]]; then
        APP_START_REBUILD=true
      fi
    done

    if [[ "${APP_NAME}" == "hipache" ]]; then
      APP_START_ROUTE_UPDATE=false
    fi

    app_start $APP_NAME $APP_PATH $APP_START_REBUILD $APP_START_ROUTE_UPDATE
    exit 0
    ;;

  status)
    echo "Status not implemeted"
    exit 1
    ;;

  stop)
    if [[ "$3" == "-h" || "$3" == "--help" ]]; then
      echo "Usage: docker-paas [APPLICATION] stop [--rm]"
      exit 0
    fi

    APP_STOP_RM=false
    APP_STOP_ROUTE_UPDATE=true

    for arg; do
      if [[ "${arg}" == "--rm" ]]; then
        APP_STOP_RM=true
      fi
    done

    if [[ "${APP_NAME}" == "hipache" ]]; then
      APP_STOP_RM=false
      APP_STOP_ROUTE_UPDATE=false
    fi

    app_stop $APP_NAME $APP_PATH $APP_STOP_RM $APP_STOP_ROUTE_UPDATE
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

