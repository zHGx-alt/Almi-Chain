#!/usr/bin/env bash
# nmap test suite against the restaurant's network, with an automatic verdict.
#
# Usage:  bash scan-network.sh lan      (from a machine on the LAN 192.168.10.0/24, e.g. the manager's PC)
#         bash scan-network.sh guests   (from a laptop on the guest Wi-Fi)
#
# Saves each test's output in results/<role>-<date>/ and a summary.txt with OK / CHECK / INFO.
# Addresses come from the addressing plan; override them with environment variables, e.g.:
#   SERVER=192.168.10.10 POS1=192.168.10.31 bash scan-network.sh lan
#
# WARNING: only scan networks you own or are allowed to scan: elsewhere it can be illegal.
set -uo pipefail
export LC_ALL=C

ROLE="${1:-}"
[[ "$ROLE" == lan || "$ROLE" == guests ]] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
command -v nmap >/dev/null || { echo "nmap is missing: sudo apt install nmap (Windows: https://nmap.org/download)" >&2; exit 1; }

LAN_NET="${LAN_NET:-192.168.10.0/24}"
ROUTER="${ROUTER:-192.168.10.1}"
ROUTER2="${ROUTER2:-192.168.10.2}"
SERVER="${SERVER:-192.168.10.10}"
MANAGER="${MANAGER:-192.168.10.20}"
POS1="${POS1:-192.168.10.31}"
POS2="${POS2:-192.168.10.32}"

DIR="$(cd "$(dirname "$0")" && pwd)/results/${ROLE}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"
SUMMARY="$DIR/summary.txt"
MY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
{
    echo "Connectivity analysis · role: $ROLE · $(date '+%Y-%m-%d %H:%M')"
    echo "Host: $(hostname) · IP: ${MY_IP:-?} · gateway: ${GW:-?} · $(nmap --version | head -1)"
    echo
} > "$SUMMARY"

n=0
# probe <name> <description> <expected> <nmap arguments...>  -> leaves open ports in $OPEN and hosts up in $HOSTS
probe() {
    local name=$1 desc=$2 expected=$3; shift 3
    n=$((n + 1))
    local base; base=$(printf '%s/%02d-%s' "$DIR" "$n" "$name")
    echo ">> [$n] $desc"
    nmap "$@" -oN "$base.txt" -oG "$base.gnmap" >/dev/null 2>"$base.err"
    OPEN=$(grep -oE '[0-9]+/open/' "$base.gnmap" | cut -d/ -f1 | sort -n | uniq | paste -sd, -)
    HOSTS=$(grep -c 'Status: Up' "$base.gnmap")
    DESC=$desc; EXPECTED=$expected
}
verdict() { # verdict OK|CHECK|INFO <detail>
    printf '[%-5s] %2d. %s\n         Expected: %s\n         Got:      %s\n\n' "$1" "$n" "$DESC" "$EXPECTED" "$2" | tee -a "$SUMMARY"
}

if [[ "$ROLE" == lan ]]; then
    probe discover-lan "Hosts up on the LAN" "The ones in the addressing plan (.1, .2, .3, .10, .20, .31, .32)" -sn "$LAN_NET"
    verdict INFO "$HOSTS hosts: $(grep 'Status: Up' "$DIR/01-discover-lan.gnmap" | awk '{print $2}' | paste -sd' ' -)"

    probe server-all "Server $SERVER: every TCP port" "Only 22, 80 and 443" -Pn -T4 -p- "$SERVER"
    if [[ "$OPEN" == "22,80,443" ]]; then verdict OK "$OPEN"; else verdict CHECK "${OPEN:-none}"; fi

    probe server-odoo-db "Server: direct Odoo (8069) and PostgreSQL (5432)" "Closed: the only way in is nginx over HTTPS" -Pn -p 8069,5432 "$SERVER"
    if [[ -z "$OPEN" ]]; then verdict OK "closed or filtered"; else verdict CHECK "open: $OPEN"; fi

    probe server-versions "Server: services and versions" "OpenSSH and nginx" -Pn -sV -p 22,80,443 "$SERVER"
    verdict INFO "$(grep -E '^[0-9]+/tcp' "$DIR/04-server-versions.txt" | awk '{$2=$2; print}' | paste -sd';' - | sed 's/;/; /g')"

    probe server-tls "Server: TLS versions on 443" "Only TLS 1.2 and 1.3" -Pn --script ssl-enum-ciphers -p 443 "$SERVER"
    TLS=$(grep -oE 'TLSv1\.[0-3]' "$DIR/05-server-tls.txt" | sort -u | paste -sd' ' -)
    if [[ -n "$TLS" && "$TLS" != *TLSv1.0* && "$TLS" != *TLSv1.1* ]]; then verdict OK "$TLS"; else verdict CHECK "${TLS:-no TLS data}"; fi

    for pair in "pos1:$POS1" "pos2:$POS2" "manager:$MANAGER"; do
        name=${pair%%:*}; ip=${pair#*:}
        probe "$name" "$name ($ip): 1000 most common ports" "None open (host firewall)" -Pn -T4 "$ip"
        if [[ -z "$OPEN" ]]; then verdict OK "none open"; else verdict CHECK "open: $OPEN"; fi
    done

    probe router "Router 1 ($ROUTER): management services" "DNS (53) and the web panel; no Telnet (23) or FTP (21)" -Pn -p 21,22,23,53,80,443,1900,8080 "$ROUTER"
    if [[ ",$OPEN," == *",23,"* || ",$OPEN," == *",21,"* ]]; then verdict CHECK "open: $OPEN"; else verdict OK "open: ${OPEN:-none}"; fi
else
    probe discover-lan "From the guest network: are LAN hosts visible?" "None" -sn "$LAN_NET"
    if [[ "$HOSTS" -eq 0 ]]; then verdict OK "0 hosts"; else verdict CHECK "$HOSTS hosts visible"; fi

    probe lan-ports "From the guest network: ports 22, 80, 443 and 8069 across the LAN" "None open (all filtered)" -Pn -T4 -p 22,80,443,8069 "$LAN_NET"
    if [[ -z "$OPEN" ]]; then verdict OK "none open"; else verdict CHECK "open: $OPEN"; fi

    probe router-panels "From the guest network: router panels ($ROUTER and $ROUTER2)" "Closed" -Pn -p 80,443 "$ROUTER" "$ROUTER2"
    if [[ -z "$OPEN" ]]; then verdict OK "closed or filtered"; else verdict CHECK "open: $OPEN"; fi

    if [[ -n "$MY_IP" ]]; then
        GUEST_NET="${GUEST_NET:-${MY_IP%.*}.0/24}"
        probe discover-guests "Other clients on the guest network ($GUEST_NET)" "Only this machine and the gateway (client isolation)" -sn "$GUEST_NET"
        verdict INFO "$HOSTS hosts: $(grep 'Status: Up' "$DIR/04-discover-guests.gnmap" | awk '{print $2}' | paste -sd' ' -)"
    fi
    if [[ -n "$GW" ]]; then
        probe gateway-panel "Guest gateway panel ($GW)" "Closed, or reachable from the LAN only" -Pn -p 80,443 "$GW"
        if [[ -z "$OPEN" ]]; then verdict OK "closed or filtered"; else verdict CHECK "open: $OPEN (can the panel be reached from the guest network?)"; fi
    fi
fi

rm -f "$DIR"/*.gnmap
find "$DIR" -name '*.err' -empty -delete
echo "Results in $DIR"
echo "$(grep -c '^\[OK' "$SUMMARY") OK · $(grep -c '^\[CHECK' "$SUMMARY") CHECK · $(grep -c '^\[INFO' "$SUMMARY") INFO" | tee -a "$SUMMARY"
