#!/usr/bin/env bash

if ! type yq >/dev/null 2>&1; then
    echo "Error: missing yq installation"
    exit 1
fi

help() {
    echo "usage: $0 [OPTIONS]"
    echo "       $0 --uninstall"
    echo "       $0 --help"
    echo
    echo "OPTIONS:"
    echo "  -d,--movies <MOVIES_DIR>            Directory containing movies."
    echo "                                      Default is ${PWD}/movies."
    echo "  -t,--tv <TV_DIR>                    Directory containing tv shows."
    echo "                                      Default is ${PWD}/tv."
    echo "  -c,--config <CONFIG_DIR>            Directory to store bittorrent config files."
    echo "                                      Default is ${PWD}/config."
    echo "  -n,--network <host|novpn-docker>    Docker network to use. Default is host."
    echo "  -u,--uninstall                      Uninstall the files and reload the system."
    echo "  -h,--help                           Print this help menu."
}

NETWORK="host"
UNINSTALL=false
VALID_ARGS=$(getopt -o m:t:c:n:uh --long movies:,tv:,config:,network:,uninstall,help -- "$@")
eval set -- "$VALID_ARGS"
while true; do
    case "$1" in
        -m | --movies)
            MOVIES_DIR="$2"
            shift 2
            ;;
        -t | --tv)
            TV_DIR="$2"
            shift 2
            ;;
        -c | --config)
            CONFIG_DIR="$2"
            shift 2
            ;;
        -n | --network)
            NETWORK="$2"
            shift 2
            ;;
        -u | --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h | --help)
            help
            shift
            exit 0
            ;;
        --) shift;
            break
            ;;
    esac
done

echo "Cleaning up existing installation (if any)..."

DOCKER_COMPOSE_TMP=docker-compose.template
DOCKER_COMPOSE_YML=docker-compose.yml
rm -rf "$DOCKER_COMPOSE_YML"
docker compose down 2>/dev/null
yq '.services.*.container_name' "$DOCKER_COMPOSE_TMP" | xargs docker rm -f

SYSTEMD=/etc/systemd/system
SERVICE="plexecutor.service"
SERVICE_PATH="$SYSTEMD/$SERVICE"
if systemctl is-active "$SERVICE" --quiet; then
    echo "Stopping $SERVICE..."
    sudo systemctl stop "$SERVICE"
fi
if [ -f "$SERVICE_PATH" ]; then
    echo "Removing $SERVICE..."
    sudo rm -rf "$SERVICE_PATH"
fi

if "$UNINSTALL"; then
    exit 0
fi

cp "$DOCKER_COMPOSE_TMP" "$DOCKER_COMPOSE_YML"

# Enable hardware accelerated decoding if available
DRI_DIR=/dev/dri
if [[ -d "$DRI_DIR" ]]; then
    echo "Disabling accelerated video decoding, opencl, etc..."
    yq \
        ".services.plexecutor.devices += \"$DRI_DIR:$DRI_DIR\"" \
    -i "$DOCKER_COMPOSE_YML"
fi

# Set the movies, tv, and config directories
declare -A VOLUMES=(
    ["movies"]="$MOVIES_DIR"
    ["tv"]="$TV_DIR"
    ["config"]="$CONFIG_DIR"
)
for DST in "${!VOLUMES[@]}"; do
    SRC="${VOLUMES[$DST]}"
    if [[ -z "$SRC" ]]; then
        SRC=$PWD/$DST
        ! [[ -d "$SRC" ]] && mkdir "$SRC"
    fi
    if ! [[ -d "$SRC" ]]; then
        echo "Error: Specified $DST directory does not exist: $SRC"
        help
        exit 1
    fi
    echo "Using $DST directory at $SRC..."
    yq "\
        .services.plexecutor.volumes += \"$SRC:/$DST\" \
    " -i "$DOCKER_COMPOSE_YML"
done
yq "\
    .services.plexecutor.volumes.[] style=\"double\"
" -i $DOCKER_COMPOSE_YML


# Set the time zone uid and pid
TZ=$(</etc/timezone)
yq "\
    .services.plexecutor.environment += \"TZ=$TZ\" | \
    .services.plexecutor.environment += \"PUID=$(id -u)\" | \
    .services.plexecutor.environment += \"PGID=$(id -g)\" \
" -i "$DOCKER_COMPOSE_YML"

# Set the network
if [[ "$NETWORK" == "novpn-docker" ]]; then
    echo "Using $NETWORK network..."
    yq "\
        del(.services.plexecutor.network_mode) | \
        .services.plexecutor.networks.$NETWORK.ipv4_address = \"\${NOVPN_PLEXECUTOR}\" | \
        .networks.$NETWORK.external = true | \
        .networks.$NETWORK.name = \"$NETWORK\" \
    " -i "$DOCKER_COMPOSE_YML"
elif [[ "$NETWORK" != "host" ]]; then
    echo "Error: Invalid network: $NETWORK"
    help
    exit 1
fi

# Docker pull
echo "Downloading docker image(s)..."
docker compose pull 2>/dev/null

echo "Installing $SERVICE..."
if [[ "$NETWORK" == "novpn-docker" ]]; then
    sed "s|{{PWD}}|$PWD|g;s|{{NOVPN_RUNTIME_ENV}}|/var/run/novpn/env|g" "$SERVICE" | sudo sponge "$SERVICE_PATH"
else
    sed "s|{{PWD}}|$PWD|g;/NOVPN/d" "$SERVICE" | sudo sponge "$SERVICE_PATH"
fi
sudo systemctl daemon-reload

echo "...Done!"
