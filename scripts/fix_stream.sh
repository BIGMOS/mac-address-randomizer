#!/usr/bin/env bash
#
# fix_stream.sh — find out why a live stream stopped working after a VPN was added.
#
# A stream that PUBLISHES to a remote service (YouTube, Twitch) is an egress
# problem, not an inbound one. Port forwarding and hidden services are
# irrelevant to it. The things that actually break it under a VPN are:
#
#   1. MTU. The tunnel lowers the usable packet size. RTMP sends large packets
#      with DF set, so they are dropped silently. Handshakes succeed, curl
#      succeeds, systemctl says active — and video never gets through. This is
#      the most commonly missed cause, so it is tested first.
#   2. Port 1935 (RTMP) blocked by the provider or the killswitch, while 443
#      stays open — which is why a plain https curl can look healthy.
#   3. Upload bandwidth collapsing through the tunnel below the stream bitrate.
#   4. DNS: the endpoint no longer resolves.
#   5. The stream is not a systemd service at all, so every "restart" was a
#      no-op against something that was never a unit.
#
# Default is a DRY RUN: it diagnoses and changes nothing.

set -uo pipefail

RTMP_HOST="a.rtmp.youtube.com"
RTMP_PORT=1935
APPLY=0

usage() {
    cat <<USAGE
Usage: $0 [--apply] [--host HOST] [--port PORT]

  --apply       Apply the MSS clamp fix if an MTU problem is found.
                Without it, only diagnose (default).
  --host HOST   Ingest host to test (default: $RTMP_HOST)
  --port PORT   Ingest port to test (default: $RTMP_PORT)

Run with no arguments first. Read the DIAGNOSIS section before applying.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --host)  RTMP_HOST="${2:?--host needs a value}"; shift 2 ;;
        --port)  RTMP_PORT="${2:?--port needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$RTMP_PORT" =~ ^[0-9]+$ ]] || { echo "--port must be numeric" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Needs root (reads service configs, probes MTU). Re-run with sudo." >&2; exit 1; }

say()  { printf '\n=== %s ===\n' "$1"; }
note() { printf '  %s\n' "$1"; }
FINDINGS=()
finding() { FINDINGS+=("$1"); printf '  >>> %s\n' "$1"; }

[[ $APPLY -eq 0 ]] && printf 'DRY RUN — nothing will be modified.\n'

# ------------------------------------------------------------------ 1. discover
say "What is the stream, actually?"

STREAM_UNITS=$(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
    | grep -iE 'stream|rtmp|srt|ffmpeg|mediamtx|owncast|restream|youtube|obs|broadcast' \
    | awk '{print $1}' || true)

if [[ -n "$STREAM_UNITS" ]]; then
    note "system units matching stream-ish names:"
    printf '    %s\n' $STREAM_UNITS
else
    note "no SYSTEM units match any stream-ish name."
fi

USER_UNITS=$(systemctl --user list-units --type=service --all --no-legend --no-pager 2>/dev/null \
    | grep -iE 'stream|rtmp|ffmpeg|obs|youtube' | awk '{print $1}' || true)
[[ -n "$USER_UNITS" ]] && { note "USER units (need --user to manage):"; printf '    %s\n' $USER_UNITS; }

note "live processes that look like an encoder:"
PROCS=$(ps -eo pid,etime,cmd --no-headers 2>/dev/null \
    | grep -iE 'ffmpeg|obs|gstreamer|mediamtx|rtmp' | grep -v grep || true)
if [[ -n "$PROCS" ]]; then
    printf '    %s\n' "$PROCS"
else
    note "  none running"
fi

note "configs/scripts mentioning an rtmp endpoint:"
RTMP_REFS=$(grep -rslE 'rtmp://|rtmps://' /etc /root /home /opt /srv 2>/dev/null \
    --exclude-dir=.git --exclude-dir=.claude --exclude-dir=node_modules \
    --exclude='*.jsonl' --exclude='fix_stream.sh' --exclude='vpn_proof_onion.sh' \
    | head -20 || true)
if [[ -n "$RTMP_REFS" ]]; then
    printf '    %s\n' $RTMP_REFS
else
    note "  none found"
fi

CRON_REFS=$(grep -rslE 'ffmpeg|rtmp|stream' /etc/cron* /var/spool/cron 2>/dev/null | head -10 || true)
[[ -n "$CRON_REFS" ]] && { note "cron entries referencing a stream:"; printf '    %s\n' $CRON_REFS; }

if [[ -z "$STREAM_UNITS" && -z "$USER_UNITS" && -z "$PROCS" ]]; then
    finding "No stream service exists as a unit or a running process. Any \
'systemctl restart' aimed at the stream was a no-op. Whatever publishes this \
stream is started some other way (a GUI OBS session, a tmux/screen shell, or \
by hand) and nothing is running it right now."
fi

# ------------------------------------------------------------------- 2. the MTU
say "MTU — the most likely culprit, tested first"

if command -v ip >/dev/null 2>&1; then
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    note "default route leaves via: ${DEFAULT_IFACE:-<none>}"
    note "interfaces and their MTUs:"
    ip -o link show 2>/dev/null | awk '{print "    " $2 " mtu=" $5}' | sed 's/://'
else
    DEFAULT_IFACE=""
    note "iproute2 not installed — cannot read interface MTUs here."
fi

if [[ -n "$DEFAULT_IFACE" ]]; then
    IFACE_MTU=$(cat "/sys/class/net/$DEFAULT_IFACE/mtu" 2>/dev/null || echo "?")
    note "$DEFAULT_IFACE MTU is $IFACE_MTU"
    if [[ "$IFACE_MTU" =~ ^[0-9]+$ ]] && (( IFACE_MTU < 1500 )); then
        note "That is below the 1500 Ethernet default — a tunnel is carrying your traffic."
    fi
fi

# Probe the real path MTU with DF set. Payload + 28 = total packet size.
note "probing actual path MTU to $RTMP_HOST (this takes a few seconds)..."
WORKING_MTU=0
for payload in 1472 1440 1412 1372 1272 1172 1072; do
    if ping -M do -s "$payload" -c 1 -W 3 "$RTMP_HOST" >/dev/null 2>&1; then
        WORKING_MTU=$(( payload + 28 ))
        note "  packets up to $WORKING_MTU bytes get through"
        break
    fi
done

if (( WORKING_MTU == 0 )); then
    note "  no size succeeded — either ICMP is filtered (common, not conclusive)"
    note "  or the host is unreachable. Check the connectivity section below."
elif (( WORKING_MTU < 1500 )); then
    finding "Path MTU to the ingest host is $WORKING_MTU, not 1500. RTMP sends \
large packets with DF set, so anything above $WORKING_MTU is dropped silently. \
This breaks video while leaving handshakes, curl and 'systemctl status' looking \
perfectly healthy. Fix: clamp TCP MSS to the path MTU (see below)."
fi

# --------------------------------------------------------- 3. egress: the ports
say "Can this box actually reach the ingest endpoint?"

if command -v getent >/dev/null && getent hosts "$RTMP_HOST" >/dev/null 2>&1; then
    note "DNS: $RTMP_HOST -> $(getent hosts "$RTMP_HOST" | awk '{print $1}' | tr '\n' ' ')"
else
    finding "DNS cannot resolve $RTMP_HOST. The VPN's resolver is broken, so the \
encoder has nowhere to send the stream. Nothing else here matters until DNS works."
fi

probe_port() {
    local host="$1" port="$2" label="$3"
    if timeout 8 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        note "$label ($host:$port): TCP connect OK"
        return 0
    fi
    note "$label ($host:$port): TCP connect FAILED"
    return 1
}

RTMP_OK=0; HTTPS_OK=0
probe_port "$RTMP_HOST" "$RTMP_PORT" "RTMP ingest" && RTMP_OK=1
probe_port "www.youtube.com" 443 "HTTPS control" && HTTPS_OK=1

if (( RTMP_OK == 0 && HTTPS_OK == 1 )); then
    finding "Port $RTMP_PORT is blocked while 443 works. This is why a plain \
https curl to YouTube looks healthy while the stream cannot publish. Either the \
VPN provider blocks non-standard ports or the killswitch permits only 443/53. \
Fix: switch the encoder to RTMPS on port 443 (rtmps://a.rtmps.youtube.com/live2) \
which tunnels through the same port that already works."
elif (( RTMP_OK == 0 && HTTPS_OK == 0 )); then
    finding "Neither $RTMP_PORT nor 443 connects. Outbound traffic is blocked \
wholesale — a killswitch permitting nothing, or the tunnel is down. Fix the \
box's general connectivity before looking at the stream."
fi

# --------------------------------------------------------------- 4. the pipe up
say "Upload headroom through the tunnel"
note "A tunnel commonly halves upload. If the encoder's bitrate exceeds what is"
note "available, YouTube drops the stream even though everything connects."
if [[ -n "$RTMP_REFS" ]]; then
    note "configured bitrates found (compare against your real upload speed):"
    grep -rhoE '[-]b:v[[:space:]]+[0-9]+k?|bitrate[=[:space:]]+[0-9]+' $RTMP_REFS 2>/dev/null \
        | sort -u | sed 's/^/    /' | head -10 || note "    none parsed"
fi
note "measure actual upload with: curl -o /dev/null -w '%{speed_upload}\\n' \\"
note "  -F 'f=@/dev/urandom' https://example.com   (or a speedtest CLI)"

# ------------------------------------------------------------------- 5. the fix
say "DIAGNOSIS"
if (( ${#FINDINGS[@]} == 0 )); then
    note "No egress problem found. The path, ports and DNS all look usable."
    note "If the stream is still down, the encoder itself is failing — check its"
    note "own log rather than the network."
else
    printf '  %d finding(s):\n' "${#FINDINGS[@]}"
    for i in "${!FINDINGS[@]}"; do printf '  %d. %s\n\n' "$((i+1))" "${FINDINGS[$i]}"; done
fi

MSS_NEEDED=0
(( WORKING_MTU > 0 && WORKING_MTU < 1500 )) && MSS_NEEDED=1

if (( MSS_NEEDED == 1 )); then
    MSS=$(( WORKING_MTU - 40 ))
    say "The MTU fix"
    note "Clamping TCP MSS to $MSS makes the kernel negotiate packets that fit,"
    note "instead of sending oversized ones that vanish."
    note ""
    note "  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS"
    note ""
    note "CAUTION: this adds a firewall rule. If your VPN client runs a killswitch,"
    note "its rules may be reloaded on reconnect and drop this one — reapply after."
    note "It is removed with the same command using -D instead of -A."
    if (( APPLY == 1 )); then
        if command -v iptables >/dev/null; then
            if iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null; then
                note "APPLIED: rule already present, nothing to do."
            elif iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null; then
                note "APPLIED: MSS clamped to $MSS. Restart the encoder, then test the stream."
            else
                note "FAILED to add the rule — check iptables permissions/output above."
            fi
        else
            note "iptables not available; use the nftables equivalent:"
            note "  nft add rule inet mangle output tcp flags syn tcp option maxseg size set $MSS"
        fi
    else
        note "(dry run — re-run with --apply to add it)"
    fi
fi

printf '\n'
(( APPLY == 0 )) && printf 'Dry run complete. Nothing was changed.\n'
