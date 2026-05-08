#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CYBICS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CYBICS_COMPOSE="$CYBICS_DIR/.devcontainer/virtual/docker-compose.yml"
CTF_OVERRIDE="$CYBICS_DIR/.devcontainer/virtual/docker-compose.ctf.yml"

ROUTER_CONTAINER="${ROUTER_CONTAINER:-open-wrt-openwrt-1}"
# Hier den Standardnamen deines internen Netzes eintragen, falls detect fehlschlägt
INT_NET="${INT_NET:-virtual_virt-cybics}" 
EXT_NET="${EXT_NET:-ext_ctf}"
EXT_SUBNET="172.22.0.0/24"
EXT_GATEWAY="172.22.0.1"
ROUTER_INT_IP="172.18.0.50"
ROUTER_EXT_IP="172.22.0.2"
ATTACK_EXT_IP="172.22.0.100"
ATTACK_CONTAINER="${ATTACK_CONTAINER:-attack-machine}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-attack}"

# --- HILFSFUNKTIONEN (Müssen da sein!) ---

container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

container_in_network() {
    docker inspect "$1" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        2>/dev/null | grep -qw "$2"
}

find_container() {
    docker ps --format '{{.Names}}' | grep -i "$1" | head -1
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

# --- HAUPTFUNKTIONEN ---

do_start() {
    echo "Starting CTF router challenge..."

    # Check ob das interne Netzwerk existiert
    if ! docker network ls --format '{{.Name}}' | grep -q "^${INT_NET}$"; then
        echo "ERROR: Network '$INT_NET' not found. Start CybICS first."
        exit 1
    fi

    # Alten Zustand aufräumen
    local attack
    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        docker network disconnect "$EXT_NET" "$attack" 2>/dev/null || true
    fi
    
    (cd "$SCRIPT_DIR" && docker compose down --remove-orphans --timeout 5 2>/dev/null) || true
    docker rm -f "$ROUTER_CONTAINER" 2>/dev/null || true
    docker network rm "$EXT_NET" 2>/dev/null || true

    # ICS-Container neu hochfahren
    echo "Restarting ICS stack in CTF mode..."
    docker compose \
        -f "$CYBICS_COMPOSE" \
        -f "$CTF_OVERRIDE" \
        --profile "$COMPOSE_PROFILES" \
        up -d --remove-orphans --force-recreate \
        openplc fuxa hwio opcua s7com stm32 firmware-updater update-server landing

    # ext_ctf Netz anlegen
    docker network create \
        --driver bridge \
        --subnet "$EXT_SUBNET" \
        --gateway "$EXT_GATEWAY" \
        "$EXT_NET"

    # Router hochfahren
    (cd "$SCRIPT_DIR" && docker compose up -d --build --remove-orphans)
    
    # WICHTIG: Verbindungen herstellen
    docker network connect --ip "$ROUTER_INT_IP" "$INT_NET" "$ROUTER_CONTAINER" 2>/dev/null || true
    # (Hinweis: Falls die IP im Compose fest ist, reicht das Up oben, aber sicher ist sicher)

    # Attack-Machine verbinden
    attack=$(find_container "$ATTACK_CONTAINER")
    if [ -n "$attack" ]; then
        container_in_network "$attack" "$EXT_NET" \
            || docker network connect --ip "$ATTACK_EXT_IP" "$EXT_NET" "$attack"
    fi

    wait_for_ssh || echo "Warning: SSH not confirmed."
}

# ... (do_stop, do_status, do_health wie gehabt, nur sicherstellen dass die Helfer oben stehen)

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    health) do_health ;;
    status) do_status ;;
    *) echo "Usage: $0 {start|stop|status|health}"; exit 1 ;;
esac