#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CYBICS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# When run via the landing UI container, CYBICS_COMPOSE_DIR and CYBICS_COMPOSE_FILE
# are injected as environment variables (see landing service definition).
# Fall back to computed paths when invoked manually from the workspace.
_COMPOSE_DIR="${CYBICS_COMPOSE_DIR:-$CYBICS_DIR/.devcontainer/virtual}"
CYBICS_COMPOSE_FILE="${CYBICS_COMPOSE_FILE:-$_COMPOSE_DIR/docker-compose.yml}"
CTF_OVERRIDE="$_COMPOSE_DIR/docker-compose.ctf.yml"

ROUTER_CONTAINER="${ROUTER_CONTAINER:-open-wrt-openwrt-1}"
INT_NET="${INT_NET:-virtual_virt-cybics}"
EXT_NET="${EXT_NET:-ext_ctf}"
EXT_SUBNET="172.22.0.0/24"
EXT_GATEWAY="172.22.0.1"
INT_SUBNET="172.18.0.0"
INT_NETMASK="255.255.255.0"
INT_GATEWAY="172.18.0.1"
ROUTER_INT_IP="172.18.0.50"
ROUTER_EXT_IP="172.22.0.2"
ATTACK_EXT_IP="172.22.0.100"
ATTACK_CONTAINER="${ATTACK_CONTAINER:-attack-machine}"
ATTACK_SERVICE="${ATTACK_SERVICE:-attack-machine}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-attack}"
ATTACK_INT_IP="172.18.0.100"

container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

container_in_network() {
    docker inspect "$1" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        2>/dev/null | grep -qw "$2"
}

find_container() {
    docker ps -a --format '{{.Names}}' | grep -i "$1" | head -1
}

wait_for_ssh() {
    local deadline=$(( $(date +%s) + 60 ))
    printf "Waiting for router SSH"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if nc -z -w1 127.0.0.1 2222 2>/dev/null; then
            banner=$(nc -w2 127.0.0.1 2222 2>/dev/null | head -1)
            if echo "$banner" | grep -qi "ssh"; then
                echo " ready"
                return 0
            fi
        fi
        printf "."
        sleep 2
    done
    echo " timed out"
    return 1
}

check_attack_ssh() {
    local attack="$1"
    [ -n "$attack" ] || return 1
    docker exec "$attack" sh -c "nc -z -w1 $ROUTER_EXT_IP 22" >/dev/null 2>&1
}

check_attack_vnc() {
    local attack="$1"
    [ -n "$attack" ] || return 1
    docker exec "$attack" sh -c "nc -z -w1 127.0.0.1 6081" >/dev/null 2>&1
}

compose_path_needs_volume_reset() {
    case "$CYBICS_COMPOSE_FILE" in
        /workspace/*|/CybICS/*) return 0 ;;
        *) return 1 ;;
    esac
}

start_attack_machine() {
    local attack
    local override_file=""

    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        if container_running "$attack"; then
            return 0
        fi

        if docker start "$attack" >/dev/null 2>&1; then
            return 0
        fi

        echo "Warning: existing attack machine container could not be started; recreating it."
        docker rm -f "$attack" >/dev/null 2>&1 || true
    fi

    if compose_path_needs_volume_reset; then
        override_file="$(mktemp /tmp/cybics-attack-compose.XXXXXX.yml)" || return 1
        {
            echo "services:"
            echo "  $ATTACK_SERVICE:"
            echo "    volumes: !reset []"
        } > "$override_file"

        docker compose \
            -f "$CYBICS_COMPOSE_FILE" \
            -f "$override_file" \
            --profile "$COMPOSE_PROFILES" \
            up -d --no-deps --force-recreate \
            "$ATTACK_SERVICE"
        local result=$?
        rm -f "$override_file"
        return "$result"
    fi

    docker compose \
        -f "$CYBICS_COMPOSE_FILE" \
        --profile "$COMPOSE_PROFILES" \
        up -d --no-deps --force-recreate \
        "$ATTACK_SERVICE"
}

configure_attack_ctf_routes() {
    local attack="$1"
    [ -n "$attack" ] || return 1

    docker exec \
        -e ATTACK_INT_IP="$ATTACK_INT_IP" \
        -e ATTACK_EXT_IP="$ATTACK_EXT_IP" \
        -e INT_SUBNET="$INT_SUBNET" \
        -e INT_NETMASK="$INT_NETMASK" \
        -e INT_GATEWAY="$INT_GATEWAY" \
        -e ROUTER_EXT_IP="$ROUTER_EXT_IP" \
        "$attack" sh -c '
find_iface_by_ip() {
    ifconfig | awk -v ip="$1" '"'"'
        /^[^ \t]/ { iface=$1; sub(":", "", iface) }
        $1 == "inet" && $2 == ip { print iface; exit }
    '"'"'
}

int_if="$(find_iface_by_ip "$ATTACK_INT_IP")"
ext_if="$(find_iface_by_ip "$ATTACK_EXT_IP")"

[ -n "$int_if" ] || { echo "could not find interface for $ATTACK_INT_IP" >&2; exit 1; }
[ -n "$ext_if" ] || { echo "could not find interface for $ATTACK_EXT_IP" >&2; exit 1; }

route add -host "$INT_GATEWAY" dev "$int_if" 2>/dev/null || true
route del -net "$INT_SUBNET" netmask "$INT_NETMASK" dev "$int_if" 2>/dev/null || true
route del -net "$INT_SUBNET" netmask "$INT_NETMASK" gw "$ROUTER_EXT_IP" 2>/dev/null || true
route add -net "$INT_SUBNET" netmask "$INT_NETMASK" gw "$ROUTER_EXT_IP" dev "$ext_if"
'
}

restore_attack_normal_routes() {
    local attack="$1"
    [ -n "$attack" ] || return 0

    docker exec \
        -e ATTACK_INT_IP="$ATTACK_INT_IP" \
        -e INT_SUBNET="$INT_SUBNET" \
        -e INT_NETMASK="$INT_NETMASK" \
        -e ROUTER_EXT_IP="$ROUTER_EXT_IP" \
        "$attack" sh -c '
find_iface_by_ip() {
    ifconfig | awk -v ip="$1" '"'"'
        /^[^ \t]/ { iface=$1; sub(":", "", iface) }
        $1 == "inet" && $2 == ip { print iface; exit }
    '"'"'
}

int_if="$(find_iface_by_ip "$ATTACK_INT_IP")"
[ -n "$int_if" ] || exit 0

route del -net "$INT_SUBNET" netmask "$INT_NETMASK" gw "$ROUTER_EXT_IP" 2>/dev/null || true
route add -net "$INT_SUBNET" netmask "$INT_NETMASK" dev "$int_if" 2>/dev/null || true
'
}

wait_for_attack_ssh() {
    local attack="$1"
    local deadline=$(( $(date +%s) + 120 ))
    printf "Waiting for attack-machine SSH path"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if check_attack_ssh "$attack"; then
            echo " ready"
            return 0
        fi
        printf "."
        sleep 2
    done
    echo " timed out"
    return 1
}


do_start() {
    echo "Starting CTF router challenge..."

    if [ ! -f "$CYBICS_COMPOSE_FILE" ]; then
        echo "ERROR: Compose file not found: $CYBICS_COMPOSE_FILE"
        exit 1
    fi
    if [ ! -f "$CTF_OVERRIDE" ]; then
        echo "ERROR: CTF override file not found: $CTF_OVERRIDE"
        exit 1
    fi

    if ! docker network ls --format '{{.Name}}' | grep -q "^${INT_NET}$"; then
        echo "ERROR: Network '$INT_NET' not found. Start CybICS first."
        exit 1
    fi

    local attack
    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        docker network disconnect "$EXT_NET" "$attack" 2>/dev/null || true
    fi

    (cd "$SCRIPT_DIR" && docker compose down --remove-orphans --timeout 5 2>/dev/null) || true
    docker rm -f "$ROUTER_CONTAINER" 2>/dev/null || true
    docker network rm "$EXT_NET" 2>/dev/null || true

    echo "Restarting ICS stack in CTF mode..."
    docker compose \
        -f "$CYBICS_COMPOSE_FILE" \
        -f "$CTF_OVERRIDE" \
        --profile "$COMPOSE_PROFILES" \
        up -d --remove-orphans --force-recreate \
        openplc fuxa hwio opcua s7com stm32 firmware-updater update-server

    docker network create \
        --driver bridge \
        --subnet "$EXT_SUBNET" \
        --gateway "$EXT_GATEWAY" \
        "$EXT_NET"

    (cd "$SCRIPT_DIR" && docker compose --profile full up -d --build --remove-orphans)

    start_attack_machine || { echo "ERROR: attack machine did not start"; exit 1; }

    attack=$(find_container "$ATTACK_CONTAINER")
    [ -n "$attack" ] || { echo "ERROR: attack machine container not found"; exit 1; }
    container_running "$attack" || { echo "ERROR: attack machine container is not running"; exit 1; }

    container_in_network "$attack" "$EXT_NET" \
        || docker network connect --ip "$ATTACK_EXT_IP" "$EXT_NET" "$attack"
    configure_attack_ctf_routes "$attack" || echo "Warning: attack-machine CTF routes not configured."

    wait_for_attack_ssh "$attack" || echo "Warning: attack-machine SSH path not confirmed."
}

do_stop() {
    echo "Stopping CTF router challenge..."

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[127.0.0.1]:2222" 2>/dev/null || true

    local attack
    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        # Attack-Machine vom CTF-Netz trennen
        container_in_network "$attack" "$EXT_NET" \
            && docker network disconnect "$EXT_NET" "$attack" 2>/dev/null || true
    fi

    (cd "$SCRIPT_DIR" && docker compose down --remove-orphans --timeout 5 2>/dev/null) || true
    docker rm -f "$ROUTER_CONTAINER" 2>/dev/null || true

    docker network rm "$EXT_NET" 2>/dev/null || true

    echo "Restarting ICS stack in normal mode (host ports restored)..."
    docker compose \
        -f "$CYBICS_COMPOSE_FILE" \
        --profile "$COMPOSE_PROFILES" \
        up -d --remove-orphans \
        openplc fuxa hwio opcua s7com stm32 firmware-updater update-server

    start_attack_machine || echo "Warning: attack machine did not start."

    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        container_in_network "$attack" "$INT_NET" \
            || docker network connect --ip "$ATTACK_INT_IP" "$INT_NET" "$attack"
        restore_attack_normal_routes "$attack" || true
    fi

    echo "Done. Back to normal."
}

do_health() {
    container_running "$ROUTER_CONTAINER" || { echo "router container not running"; exit 1; }
    container_in_network "$ROUTER_CONTAINER" "$INT_NET" || { echo "router not in $INT_NET"; exit 1; }
    container_in_network "$ROUTER_CONTAINER" "$EXT_NET" || { echo "router not in $EXT_NET"; exit 1; }
    local attack
    attack=$(find_container "$ATTACK_CONTAINER")
    [ -n "$attack" ] || { echo "attack machine not found"; exit 1; }
    container_in_network "$attack" "$EXT_NET" || { echo "attack machine not in $EXT_NET"; exit 1; }
    container_in_network "$attack" "$INT_NET" || { echo "attack machine not in $INT_NET (required for host VNC forwarding)"; exit 1; }
    check_attack_ssh "$attack" || { echo "router SSH not reachable from attack machine at $ROUTER_EXT_IP:22"; exit 1; }
    check_attack_vnc "$attack" || { echo "attack machine noVNC not reachable inside container at 127.0.0.1:6081"; exit 1; }
    echo "router healthy"
}

do_status() {
    echo "CTF Router Challenge status:"
    echo ""

    if container_running "$ROUTER_CONTAINER"; then
        echo "  router:   running"
        container_in_network "$ROUTER_CONTAINER" "$INT_NET" && echo "    -> $INT_NET  ($ROUTER_INT_IP)"
        container_in_network "$ROUTER_CONTAINER" "$EXT_NET" && echo "    -> $EXT_NET  ($ROUTER_EXT_IP)"
    else
        echo "  router:   not running"
    fi

    if docker network ls --format '{{.Name}}' | grep -q "^${EXT_NET}$"; then
        echo "  ext_ctf:  exists"
    else
        echo "  ext_ctf:  not created"
    fi

    local attack
    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        local in_ext in_int
        container_in_network "$attack" "$EXT_NET" && in_ext=1 || in_ext=0
        container_in_network "$attack" "$INT_NET" && in_int=1 || in_int=0
        if [ "$in_ext" = "1" ] && [ "$in_int" = "1" ]; then
            echo "  attack:   ctf mode (ext_ctf + host VNC bridge)"
            check_attack_ssh "$attack" \
                && echo "    -> router SSH reachable ($ROUTER_EXT_IP:22)" \
                || echo "    -> router SSH not reachable ($ROUTER_EXT_IP:22)"
            check_attack_vnc "$attack" \
                && echo "    -> noVNC reachable inside container (host port 6081 published)" \
                || echo "    -> noVNC not reachable inside container"
        elif [ "$in_ext" = "0" ] && [ "$in_int" = "1" ]; then
            echo "  attack:   normal (virt-cybics only)"
        elif [ "$in_ext" = "1" ] && [ "$in_int" = "0" ]; then
            echo "  attack:   ctf mode without host VNC bridge"
            check_attack_ssh "$attack" \
                && echo "    -> router SSH reachable ($ROUTER_EXT_IP:22)" \
                || echo "    -> router SSH not reachable ($ROUTER_EXT_IP:22)"
        else
            echo "  attack:   mixed"
        fi
    else
        echo "  attack:   not found"
    fi
    echo ""
}

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    health) do_health ;;
    status) do_status ;;
    *) echo "Usage: $0 {start|stop|status|health}"; exit 1 ;;
esac
