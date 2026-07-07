#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/asn-blocker"
PREFIX_DIR="$STATE_DIR/prefixes"
ASN_LIST_FILE="$STATE_DIR/blocked_asns.txt"

NFT_TABLE_FAMILY="inet"
NFT_TABLE_NAME="asnblock"
NFT_SET_V4="blocked_v4"
NFT_SET_V6="blocked_v6"
NFT_CHAIN_OUT="output"

LOG_FILE="/var/log/asn-blocker.log"
RSYSLOG_CONF="/etc/rsyslog.d/30-asn-blocker.conf"
LOGROTATE_CONF="/etc/logrotate.d/asn-blocker"

usage() {
    cat <<'EOF'
ASN blocker for nftables

Usage:
  asn-blocker.sh init
  asn-blocker.sh block <ASN> [ASN...]
  asn-blocker.sh unblock <ASN> [ASN...]
  asn-blocker.sh refresh [ASN...]
  asn-blocker.sh list
  asn-blocker.sh status
  asn-blocker.sh check-ip <IPv4|IPv6>
  asn-blocker.sh logs [lines]
  asn-blocker.sh setup-logging
  asn-blocker.sh help

Examples:
  sudo ./asn-blocker.sh block AS28753
  sudo ./asn-blocker.sh block 28753 210644
  sudo ./asn-blocker.sh list
  sudo ./asn-blocker.sh logs 200
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run as root." >&2
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

ensure_state_dirs() {
    mkdir -p "$PREFIX_DIR"
    touch "$ASN_LIST_FILE"
}

normalize_asn() {
    local raw="${1^^}"
    raw="${raw#AS}"
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
        echo "Invalid ASN: $1" >&2
        return 1
    fi
    echo "$raw"
}

ripe_prefixes() {
    local asn="$1"
    local family="$2"
    local query
    query="$(curl -fsSL "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" || true)"
    if [[ -z "$query" ]]; then
        return 0
    fi
    if [[ "$family" == "v4" ]]; then
        jq -r '.data.prefixes[].prefix // empty' <<<"$query" | rg '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
    else
        jq -r '.data.prefixes[].prefix // empty' <<<"$query" | rg ':' || true
    fi
}

bgpview_prefixes() {
    local asn="$1"
    local family="$2"
    local query
    query="$(curl -fsSL "https://api.bgpview.io/asn/${asn}/prefixes" || true)"
    if [[ -z "$query" ]]; then
        return 0
    fi
    if [[ "$family" == "v4" ]]; then
        jq -r '.data.ipv4_prefixes[].prefix // empty' <<<"$query" || true
    else
        jq -r '.data.ipv6_prefixes[].prefix // empty' <<<"$query" || true
    fi
}

fetch_prefixes_for_asn() {
    local asn="$1"
    local out_v4="$2"
    local out_v6="$3"

    ripe_prefixes "$asn" "v4" | sort -u >"$out_v4"
    ripe_prefixes "$asn" "v6" | sort -u >"$out_v6"

    if [[ ! -s "$out_v4" ]]; then
        bgpview_prefixes "$asn" "v4" | sort -u >"$out_v4"
    fi
    if [[ ! -s "$out_v6" ]]; then
        bgpview_prefixes "$asn" "v6" | sort -u >"$out_v6"
    fi

    if [[ ! -s "$out_v4" && ! -s "$out_v6" ]]; then
        echo "No prefixes found for AS${asn}" >&2
        return 1
    fi
}

init_nft() {
    if ! nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1; then
        nft add table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME"
    fi

    if ! nft list set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V4" >/dev/null 2>&1; then
        nft add set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V4" "{ type ipv4_addr; flags interval; }"
    fi

    if ! nft list set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V6" >/dev/null 2>&1; then
        nft add set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V6" "{ type ipv6_addr; flags interval; }"
    fi

    if ! nft list chain "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_OUT" >/dev/null 2>&1; then
        nft add chain "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_OUT" "{ type filter hook output priority 0; policy accept; }"
    fi

    local chain_dump
    chain_dump="$(nft list chain "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_OUT" || true)"
    if ! rg -q "ip daddr @${NFT_SET_V4}" <<<"$chain_dump"; then
        nft add rule "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_OUT" ip daddr "@${NFT_SET_V4}" limit rate 30/second burst 100 packets log prefix '"ASN-BLOCK v4 "' level warning counter drop
    fi
    if ! rg -q "ip6 daddr @${NFT_SET_V6}" <<<"$chain_dump"; then
        nft add rule "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_OUT" ip6 daddr "@${NFT_SET_V6}" limit rate 30/second burst 100 packets log prefix '"ASN-BLOCK v6 "' level warning counter drop
    fi
}

rebuild_sets() {
    init_nft
    nft flush set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V4"
    nft flush set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V6"

    local f line
    shopt -s nullglob
    for f in "$PREFIX_DIR"/*.v4; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            nft add element "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V4" "{ $line }"
        done <"$f"
    done

    for f in "$PREFIX_DIR"/*.v6; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            nft add element "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V6" "{ $line }"
        done <"$f"
    done
    shopt -u nullglob
}

block_asn() {
    local asn normalized tmp_v4 tmp_v6
    for asn in "$@"; do
        normalized="$(normalize_asn "$asn")"
        tmp_v4="$(mktemp)"
        tmp_v6="$(mktemp)"
        fetch_prefixes_for_asn "$normalized" "$tmp_v4" "$tmp_v6"
        mv "$tmp_v4" "$PREFIX_DIR/AS${normalized}.v4"
        mv "$tmp_v6" "$PREFIX_DIR/AS${normalized}.v6"

        if ! rg -q "^${normalized}$" "$ASN_LIST_FILE"; then
            echo "$normalized" >>"$ASN_LIST_FILE"
        fi
        echo "Loaded AS${normalized} prefixes."
    done

    sort -u -o "$ASN_LIST_FILE" "$ASN_LIST_FILE"
    rebuild_sets
    echo "Blocklist updated."
}

unblock_asn() {
    local asn normalized tmp
    for asn in "$@"; do
        normalized="$(normalize_asn "$asn")"
        rm -f "$PREFIX_DIR/AS${normalized}.v4" "$PREFIX_DIR/AS${normalized}.v6"
        tmp="$(mktemp)"
        rg -v "^${normalized}$" "$ASN_LIST_FILE" >"$tmp" || true
        mv "$tmp" "$ASN_LIST_FILE"
        echo "Removed AS${normalized}."
    done

    rebuild_sets
    echo "Blocklist updated."
}

refresh_asn() {
    local targets=()
    local asn normalized

    if [[ $# -gt 0 ]]; then
        for asn in "$@"; do
            targets+=("$(normalize_asn "$asn")")
        done
    else
        mapfile -t targets < <(rg '^[0-9]+$' "$ASN_LIST_FILE" || true)
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "No ASNs configured."
        return 0
    fi

    for normalized in "${targets[@]}"; do
        fetch_prefixes_for_asn "$normalized" "$PREFIX_DIR/AS${normalized}.v4" "$PREFIX_DIR/AS${normalized}.v6"
        echo "Refreshed AS${normalized}."
    done

    rebuild_sets
    echo "Refresh complete."
}

list_asns() {
    if [[ ! -s "$ASN_LIST_FILE" ]]; then
        echo "No blocked ASNs."
        return 0
    fi

    echo "Blocked ASNs:"
    while IFS= read -r asn; do
        [[ -z "$asn" ]] && continue
        local v4_count v6_count holder
        v4_count="$(wc -l < "$PREFIX_DIR/AS${asn}.v4" 2>/dev/null || echo 0)"
        v6_count="$(wc -l < "$PREFIX_DIR/AS${asn}.v6" 2>/dev/null || echo 0)"
        holder="$(curl -fsSL "https://stat.ripe.net/data/as-overview/data.json?resource=AS${asn}" 2>/dev/null | jq -r '.data.holder // "unknown"')"
        echo "  AS${asn}  v4:${v4_count}  v6:${v6_count}  ${holder}"
    done <"$ASN_LIST_FILE"
}

status_report() {
    list_asns
    echo
    if nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1; then
        local loaded_v4 loaded_v6
        loaded_v4="$(nft list set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V4" 2>/dev/null | rg -o '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l || true)"
        loaded_v6="$(nft list set "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_SET_V6" 2>/dev/null | rg -o '([0-9a-fA-F:]+:+[0-9a-fA-F:]+)/[0-9]+' | wc -l || true)"
        echo "NFT table: ${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME}"
        echo "Loaded prefixes: v4=${loaded_v4} v6=${loaded_v6}"
    else
        echo "NFT table ${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME} not initialized."
    fi
}

check_ip() {
    local ip="$1"
    python3 - "$ip" "$ASN_LIST_FILE" "$PREFIX_DIR" <<'PY'
import ipaddress
import pathlib
import sys

ip = ipaddress.ip_address(sys.argv[1])
asn_file = pathlib.Path(sys.argv[2])
prefix_dir = pathlib.Path(sys.argv[3])

if not asn_file.exists():
    print("No blocked ASNs.")
    raise SystemExit(0)

hit = False
for line in asn_file.read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    for suffix in ("v4", "v6"):
        path = prefix_dir / f"AS{line}.{suffix}"
        if not path.exists():
            continue
        for prefix in path.read_text().splitlines():
            prefix = prefix.strip()
            if not prefix:
                continue
            net = ipaddress.ip_network(prefix, strict=False)
            if ip in net:
                print(f"HIT: {ip} in {net} (AS{line})")
                hit = True
                break
        if hit:
            break
if not hit:
    print(f"MISS: {ip} not found in blocked ASN prefixes")
PY
}

setup_logging() {
    cat >"$RSYSLOG_CONF" <<'EOF'
:msg, contains, "ASN-BLOCK" -/var/log/asn-blocker.log
& stop
EOF

    cat >"$LOGROTATE_CONF" <<'EOF'
/var/log/asn-blocker.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF

    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE"

    if systemctl is-active --quiet rsyslog; then
        systemctl restart rsyslog
        echo "Rsyslog config applied."
    else
        echo "Rsyslog is not active. Kernel logs stay in journald."
    fi
}

show_logs() {
    local lines="${1:-100}"
    echo "Recent kernel log matches:"
    journalctl -k -g "ASN-BLOCK" -n "$lines" --no-pager || true
    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo "Tail of $LOG_FILE:"
        tail -n "$lines" "$LOG_FILE" || true
    fi
}

main() {
    local cmd="${1:-help}"
    shift || true

    require_root
    require_cmd nft
    require_cmd curl
    require_cmd jq
    require_cmd rg
    require_cmd python3
    ensure_state_dirs

    case "$cmd" in
        init)
            init_nft
            echo "Initialized nftables structures."
            ;;
        block)
            [[ $# -ge 1 ]] || { echo "Provide at least one ASN."; exit 1; }
            block_asn "$@"
            ;;
        unblock)
            [[ $# -ge 1 ]] || { echo "Provide at least one ASN."; exit 1; }
            unblock_asn "$@"
            ;;
        refresh)
            refresh_asn "$@"
            ;;
        list)
            list_asns
            ;;
        status)
            status_report
            ;;
        check-ip)
            [[ $# -eq 1 ]] || { echo "Usage: check-ip <IP>"; exit 1; }
            check_ip "$1"
            ;;
        setup-logging)
            setup_logging
            ;;
        logs)
            show_logs "${1:-100}"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
