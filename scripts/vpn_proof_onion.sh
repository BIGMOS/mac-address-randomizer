#!/usr/bin/env bash
#
# vpn_proof_onion.sh — make Tor hidden services survive a VPN being added.
#
# A hidden service only makes OUTBOUND connections, so it should not care
# about a VPN at all. It breaks when something ties it to an interface or
# address that the VPN changed. This script finds and fixes those ties:
#
#   1. OutboundBindAddress pinned to a LAN IP that no longer exists
#   2. HiddenServicePort targets pointing at a LAN IP instead of loopback
#   3. The backing server bound to a LAN IP, so it fails to bind after a change
#   4. Tor starting before the VPN tunnel is up, failing, and backing off
#
# Default is a DRY RUN: it reports and changes nothing. Pass --apply to write.

set -euo pipefail

TORRC=/etc/tor/torrc
APPLY=0
STREAM_PORT=""

usage() {
    cat <<USAGE
Usage: $0 [--apply] [--add-stream PORT]

  --apply            Write changes. Without it, only report (default).
  --add-stream PORT  Also expose a second hidden service for a live stream,
                     pointing at 127.0.0.1:PORT.

Run with no arguments first to see what it would do.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --add-stream) STREAM_PORT="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "$STREAM_PORT" && ! "$STREAM_PORT" =~ ^[0-9]+$ ]]; then
    echo "--add-stream needs a numeric port" >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    echo "Needs root to read /etc/tor and /var/lib/tor. Re-run with sudo." >&2
    exit 1
fi

if [[ ! -f "$TORRC" ]]; then
    echo "No $TORRC found. Is Tor installed on this machine?" >&2
    exit 1
fi

say()  { printf '\n=== %s ===\n' "$1"; }
note() { printf '  %s\n' "$1"; }
would() {
    if [[ $APPLY -eq 1 ]]; then printf '  CHANGED: %s\n' "$1"
    else printf '  WOULD CHANGE: %s\n' "$1"; fi
}

if [[ $APPLY -eq 0 ]]; then
    printf 'DRY RUN — nothing will be modified. Re-run with --apply to write.\n'
fi

# ---------------------------------------------------------------- current state
say "This machine"
note "hostname: $(hostname)"
ip -brief addr | sed 's/^/  /'

say "Default route (is a tunnel carrying it?)"
ip route show default | sed 's/^/  /' || note "no default route"

say "Tor service"
systemctl is-active tor@default >/dev/null 2>&1 \
    && note "tor@default is active" \
    || note "tor@default is NOT active  <-- the service itself is down"

if journalctl -u tor@default -n 200 --no-pager 2>/dev/null \
     | grep -q 'Bootstrapped 100%'; then
    note "bootstrapped 100% at some point in recent log"
else
    note "no 'Bootstrapped 100%' in recent log  <-- Tor cannot reach the network"
fi

# ------------------------------------------------------------------- the checks
BACKUP=""
ensure_backup() {
    [[ -n "$BACKUP" ]] && return 0
    BACKUP="${TORRC}.bak.$(date +%Y%m%d-%H%M%S)"
    if [[ $APPLY -eq 1 ]]; then
        cp -a "$TORRC" "$BACKUP"
        note "backed up torrc to $BACKUP"
    else
        note "would back up torrc to $BACKUP"
    fi
}

say "Check 1: OutboundBindAddress pinned to a stale address"
if grep -qE '^[[:space:]]*OutboundBindAddress' "$TORRC"; then
    grep -nE '^[[:space:]]*OutboundBindAddress' "$TORRC" | sed 's/^/  /'
    note "This pins Tor's outbound traffic to one address. If the VPN changed"
    note "the routing, Tor can no longer send anything. Commenting it out lets"
    note "Tor follow the default route, tunnel included."
    ensure_backup
    would "comment out OutboundBindAddress"
    [[ $APPLY -eq 1 ]] && \
        sed -i 's/^\([[:space:]]*OutboundBindAddress.*\)$/# \1  # disabled: VPN-fragile/' "$TORRC"
else
    note "OK — not set."
fi

say "Check 2: HiddenServicePort targets must be loopback"
if grep -qE '^[[:space:]]*HiddenServicePort' "$TORRC"; then
    grep -nE '^[[:space:]]*HiddenServicePort' "$TORRC" | sed 's/^/  /'
    if grep -E '^[[:space:]]*HiddenServicePort' "$TORRC" \
         | grep -qvE '127\.0\.0\.1|localhost|unix:'; then
        note "A target is NOT on loopback. Any LAN address here breaks when the"
        note "IP changes. Rewriting the host part to 127.0.0.1 keeps the port."
        ensure_backup
        would "rewrite non-loopback HiddenServicePort targets to 127.0.0.1"
        [[ $APPLY -eq 1 ]] && \
            sed -i -E 's/^([[:space:]]*HiddenServicePort[[:space:]]+[0-9]+[[:space:]]+)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/\1127.0.0.1:/' "$TORRC"
    else
        note "OK — all targets are on loopback."
    fi
else
    note "No HiddenServicePort configured at all."
fi

say "Check 3: are the target ports actually listening?"
TARGET_PORTS=$(grep -E '^[[:space:]]*HiddenServicePort' "$TORRC" 2>/dev/null \
    | grep -oE '[0-9]+$' || true)
if [[ -z "$TARGET_PORTS" ]]; then
    note "No target ports to check."
else
    for p in $TARGET_PORTS; do
        if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
            code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
                   "http://127.0.0.1:$p" 2>/dev/null || echo "no answer")
            note "port $p: listening, local HTTP -> $code"
        else
            note "port $p: NOTHING LISTENING  <-- Tor is innocent; this server is down"
            ss -tlnp 2>/dev/null | grep -E "0\.0\.0\.0:$p|10\.0\.0\.[0-9]+:$p" \
                && note "  (bound to a non-loopback address — rebind it to 127.0.0.1)"
        fi
    done
fi

say "Check 4: does Tor wait for the network before starting?"
DROPIN=/etc/systemd/system/tor@default.service.d/wait-for-network.conf
if [[ -f "$DROPIN" ]]; then
    note "OK — drop-in already present at $DROPIN"
else
    note "Tor may start before the VPN tunnel is up, fail, and back off."
    would "create $DROPIN so Tor waits for the network and retries"
    if [[ $APPLY -eq 1 ]]; then
        mkdir -p "$(dirname "$DROPIN")"
        cat > "$DROPIN" <<'UNIT'
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=10s
UNIT
        systemctl daemon-reload
        note "created and reloaded systemd"
    fi
fi

# ------------------------------------------------------------ optional: stream
if [[ -n "$STREAM_PORT" ]]; then
    say "Adding a hidden service for the stream on 127.0.0.1:$STREAM_PORT"
    if grep -q '/var/lib/tor/stream/' "$TORRC"; then
        note "Already configured — leaving it alone."
    else
        ensure_backup
        would "append a stream hidden service to torrc"
        if [[ $APPLY -eq 1 ]]; then
            cat >> "$TORRC" <<EOF

# Live stream as its own onion service — no port forward, no LAN IP, VPN-proof.
HiddenServiceDir /var/lib/tor/stream/
HiddenServicePort 80 127.0.0.1:$STREAM_PORT
EOF
            note "appended"
        fi
    fi
    note "Note: Tor bandwidth suits audio or a modest video bitrate. A"
    note "high-bitrate stream will buffer — lower the bitrate for Tor."
fi

# ------------------------------------------------------------------ apply/close
if [[ $APPLY -eq 1 ]]; then
    say "Validating torrc"
    if tor --verify-config -f "$TORRC" >/dev/null 2>&1; then
        note "config is valid; restarting tor@default"
        systemctl restart tor@default
        sleep 3
        systemctl is-active tor@default >/dev/null 2>&1 \
            && note "tor@default restarted and is active" \
            || note "tor@default FAILED to start — check: journalctl -u tor@default -n 50"
    else
        note "CONFIG INVALID — not restarting. Details:"
        tor --verify-config -f "$TORRC" 2>&1 | sed 's/^/    /'
        [[ -n "$BACKUP" ]] && note "restore with: cp $BACKUP $TORRC"
        exit 1
    fi

    say "Onion addresses"
    for h in /var/lib/tor/*/hostname; do
        [[ -f "$h" ]] && note "$(basename "$(dirname "$h")"): $(cat "$h")"
    done
else
    printf '\nDry run complete. Re-run with --apply to make these changes.\n'
fi
