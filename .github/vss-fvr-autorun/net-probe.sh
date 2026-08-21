#!/usr/bin/env bash
# Client-side network probe -- run ALONGSIDE an FVR run to capture what the
# local machine's network stack is doing when SSH to the test box fails.
#
# WHY THIS EXISTS:
#   Two FVR matrix runs lost cells to "SSH unreachable", against two different
#   hosts on two different providers (a raw-IP Brev box and a DNS-named EC2
#   box). Both failures produced *client-side* errors -- `Can't assign
#   requested address` (local socket) and `-65563` (macOS mDNSResponder
#   resolver) -- and in the second case the resolver was already failing ~36
#   minutes BEFORE the teardown that appeared to trigger it. The remote box
#   had continuous uptime through both outages.
#
#   The FVR pipeline only samples the network when it happens to run a
#   command, so an outage's start, duration, and mechanism were never
#   observed directly -- only inferred from which cell died. This probe is an
#   independent observer: it samples continuously and, critically, separates
#   the three failure modes that the pipeline's single error message conflates.
#
# WHAT IT DISTINGUISHES (this is the whole point):
#   DNS ok  + TCP-to-IP ok   -> network fine; look elsewhere
#   DNS FAIL + TCP-to-IP ok  -> resolver problem only (fix: use the IP)
#   DNS ok  + TCP-to-IP FAIL -> real path/reachability problem
#   both FAIL                -> interface/VPN/routing down locally
#
# Usage:
#   scripts/ci/net-probe.sh <host-or-ip> [interval-seconds] [out-file]
#
#   # typical: run in a second terminal or tmux pane before starting a matrix
#   scripts/ci/net-probe.sh ec2-13-59-76-99.us-east-2.compute.amazonaws.com 20
#
# Read-only: performs no writes to the remote host and changes nothing
# locally. Safe to run for the whole duration of a multi-hour matrix.

set -uo pipefail

HOST="${1:?usage: net-probe.sh <host-or-ip> [interval] [out-file]}"
INTERVAL="${2:-20}"
OUT="${3:-net-probe-$(date -u +%Y%m%dT%H%M%SZ).log}"

# Resolve once at start to get a baseline IP to test against. If HOST is
# already an IP this is a no-op. Testing BOTH the name and a fixed IP is what
# separates "resolver broke" from "path broke" -- probing only the name
# cannot tell those apart, which is precisely how the earlier investigation
# went down the wrong path.
BASE_IP="$(dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
if [[ -z "$BASE_IP" ]]; then
  # HOST may itself be an IP, or DNS may already be broken right now.
  if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    BASE_IP="$HOST"
  else
    echo "WARNING: could not resolve '$HOST' at startup -- DNS may already be" >&2
    echo "failing. IP-path checks will be skipped until it resolves once." >&2
  fi
fi

{
  echo "# net-probe started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# host=$HOST baseline_ip=${BASE_IP:-<unresolved>} interval=${INTERVAL}s"
  echo "# columns: utc_time | dns | tcp_ip | tcp_name | mdns | iface | verdict"
} | tee -a "$OUT"

while true; do
  TS="$(date -u +%H:%M:%S)"

  # --- DNS: does the name resolve right now, and how fast? ---
  T0=$(date +%s)
  RESOLVED="$(dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
  DNS_MS=$(( ($(date +%s) - T0) ))
  if [[ -n "$RESOLVED" ]]; then
    DNS="ok(${RESOLVED},${DNS_MS}s)"
  else
    DNS="FAIL(${DNS_MS}s)"
  fi

  # --- TCP to the fixed IP: bypasses the resolver entirely ---
  if [[ -n "$BASE_IP" ]]; then
    if nc -G 5 -z "$BASE_IP" 22 >/dev/null 2>&1; then TCP_IP="ok"; else TCP_IP="FAIL"; fi
  else
    TCP_IP="skip"
  fi

  # --- TCP via the name: exercises resolver + path together, i.e. exactly
  # what ssh does. Divergence from TCP_IP isolates the resolver. ---
  if nc -G 5 -z "$HOST" 22 >/dev/null 2>&1; then TCP_NAME="ok"; else TCP_NAME="FAIL"; fi

  # --- Is the resolver daemon even alive? (the -65563 error implicates it) ---
  if pgrep -x mDNSResponder >/dev/null 2>&1; then MDNS="up"; else MDNS="DOWN"; fi

  # --- Which interface currently carries the default route? A Wi-Fi/VPN
  # flip mid-run would show up here as a change. ---
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  IFACE="${IFACE:-none}"

  # --- Verdict: the whole reason for probing both paths ---
  if [[ "$DNS" == ok* && "$TCP_IP" == "ok" && "$TCP_NAME" == "ok" ]]; then
    VERDICT="healthy"
  elif [[ "$DNS" == FAIL* && "$TCP_IP" == "ok" ]]; then
    VERDICT="RESOLVER-ONLY (use the IP and this run survives)"
  elif [[ "$TCP_IP" == "FAIL" && "$DNS" == ok* ]]; then
    VERDICT="PATH-DOWN (name resolves, box unreachable)"
  elif [[ "$TCP_IP" == "FAIL" && "$DNS" == FAIL* ]]; then
    VERDICT="LOCAL-NETWORK-DOWN (both fail: iface/VPN/routing)"
  else
    VERDICT="degraded"
  fi

  LINE="$TS | dns=$DNS | tcp_ip=$TCP_IP | tcp_name=$TCP_NAME | mdns=$MDNS | iface=$IFACE | $VERDICT"
  echo "$LINE" >> "$OUT"
  # Only surface non-healthy samples on stdout so a multi-hour run stays
  # readable; the file keeps every sample for later correlation.
  [[ "$VERDICT" == "healthy" ]] || echo "$LINE"

  sleep "$INTERVAL"
done
