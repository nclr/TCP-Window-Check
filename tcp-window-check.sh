#!/usr/bin/env bash
#
# tcp-window-check.sh — diagnose what limits a single-flow TCP download:
#   (a) your receive window, (b) the server's send window/cwnd, or (c) loss/congestion.
#
# It drives ONE TCP flow, finds the real peer (after any redirects) from the downloader's
# own socket, captures ONLY that peer, samples the live socket with `ss`, and prints a
# verdict that cross-checks the server's in-flight bytes and your advertised receive
# window against the bandwidth-delay product (BDP).
#
# Usage:
#   ./tcp-window-check.sh <URL>          # downloads via aria2c -x1 and measures it
#   HOST=1.2.3.4 ./tcp-window-check.sh   # attach to a flow you start yourself to HOST
#
# Env knobs:
#   DURATION=15            seconds to sample (download is killed afterwards)
#   LINE_RATE_MBIT=1000    your link rate, for the target BDP / %-of-line figures
#   WORKDIR=/var/tmp       disk-backed scratch dir (NOT /tmp, which is often tmpfs/RAM)
#   ARIA2_OPTS="..."       override aria2c flags (default forces a single connection)
#   DEBUG=1                set -x tracing
#
# Notes:
#   * The capture is scoped to the single peer IP — it does NOT sniff other host traffic.
#     Still, prefer running on a machine you own. Run as a normal user; only tcpdump
#     self-elevates via sudo (running the whole script as root also runs the downloader
#     as root, which is unnecessary).
#   * A transient download file (~ throughput x DURATION) is written under WORKDIR and
#     removed on exit. Lower DURATION to shrink it.
#   * The verdict is a heuristic with fudge factors, not an authority — read the numbers.
#
# Linux only (needs iproute2 `ss`, GNU `grep -P`, tshark, tcpdump). Not macOS/BSD.
#
# License: MIT (see LICENSE).

set -euo pipefail
[[ "${DEBUG:-0}" -eq 1 ]] && set -x

SUDO=()   # populated below; empty array = run without sudo (we are root)

# ---------------- args / mode ----------------
URL="${1:-}"
DURATION="${DURATION:-15}"
LINE_RATE_MBIT="${LINE_RATE_MBIT:-1000}"
ARIA2_OPTS="${ARIA2_OPTS:--x1 -s1 --file-allocation=none --summary-interval=0 --console-log-level=warn --allow-overwrite=true}"

die() { echo "error: $*" >&2; exit 1; }

ATTACH=0
if [[ -z "$URL" ]]; then
  if [[ -n "${HOST:-}" ]]; then ATTACH=1; else
    echo "usage: $0 <URL>    or    HOST=<ip> $0" >&2
    exit 2
  fi
fi

# ---------------- dependency check (Debian-aware) ----------------
declare -a MISSING_BINS=() MISSING_PKGS=()
need() {  # need <binary> <debian-package>
  command -v "$1" >/dev/null 2>&1 || { MISSING_BINS+=("$1"); MISSING_PKGS+=("$2"); }
}

need ss       iproute2
need tcpdump  tcpdump
need tshark   tshark
need awk      gawk
need grep     grep
need sed      sed
need sort     coreutils
need getent   libc-bin
[[ "$ATTACH" -eq 0 ]] && need aria2c aria2

NEED_SUDO_PKG=0
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO=(sudo); else NEED_SUDO_PKG=1; fi
fi

GREP_NO_PCRE=0
if command -v grep >/dev/null 2>&1; then
  printf 'x' | grep -qP 'x' 2>/dev/null || GREP_NO_PCRE=1
fi

if (( ${#MISSING_BINS[@]} )) || (( NEED_SUDO_PKG )) || (( GREP_NO_PCRE )); then
  echo "Missing or unusable dependencies:" >&2
  for i in "${!MISSING_BINS[@]}"; do
    printf '  - %-10s (Debian package: %s)\n' "${MISSING_BINS[$i]}" "${MISSING_PKGS[$i]}" >&2
  done
  (( GREP_NO_PCRE ))  && echo "  - grep has no -P/PCRE support (need GNU grep)" >&2
  (( NEED_SUDO_PKG )) && echo "  - not root and 'sudo' not found (Debian package: sudo) — or run as root" >&2

  # de-duplicate package list in pure bash (no reliance on coreutils here)
  declare -A SEEN=(); INSTALL=""
  for p in "${MISSING_PKGS[@]}"; do
    [[ -n "${SEEN[$p]:-}" ]] || { INSTALL+="$p "; SEEN[$p]=1; }
  done
  (( NEED_SUDO_PKG )) && [[ -z "${SEEN[sudo]:-}" ]] && INSTALL+="sudo "
  if [[ -n "${INSTALL// /}" ]]; then
    echo >&2
    echo "Install on Debian/Ubuntu:" >&2
    echo "  sudo apt-get update && sudo apt-get install -y ${INSTALL% }" >&2
  fi
  exit 1
fi

# optional, only referenced in the loss/congestion follow-up text
command -v mtr >/dev/null 2>&1 || \
  echo "note: optional 'mtr' not found (used in the loss follow-up). Install: sudo apt-get install -y mtr-tiny" >&2

# ---------------- scratch dir + cleanup ----------------
BASEDIR="${WORKDIR:-/var/tmp}"
[[ -d "$BASEDIR" && -w "$BASEDIR" ]] || BASEDIR="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${BASEDIR%/}/tcpwin.XXXXXX")"
PCAP="$WORK/cap.pcap"
ARIA_LOG="$WORK/aria2.log"
SAMPLES="$WORK/ss.samples"
ARIA_PID=""; TCPDUMP_PID=""

cleanup() {
  set +e
  [[ -n "$ARIA_PID" ]]    && kill "$ARIA_PID" 2>/dev/null
  [[ -n "$TCPDUMP_PID" ]] && "${SUDO[@]}" kill "$TCPDUMP_PID" 2>/dev/null
  wait 2>/dev/null
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---------------- find the real peer ----------------
if [[ "$ATTACH" -eq 1 ]]; then
  SERVER_IP="$HOST"; SERVER_PORT="?"
  echo ">> attach mode: measuring existing flow to $SERVER_IP for ${DURATION}s"
else
  echo ">> launching: aria2c $ARIA2_OPTS \"$URL\""
  # shellcheck disable=SC2086  # ARIA2_OPTS is intentionally word-split into flags
  aria2c $ARIA2_OPTS --dir="$WORK" -o dl.bin "$URL" >"$ARIA_LOG" 2>&1 &
  ARIA_PID=$!

  # Among aria2's ESTABLISHED sockets, pick the one actually moving data (max
  # bytes_received). This survives redirects (the redirect socket transfers ~nothing)
  # and any stray connections. Falls back to a web-port socket on older kernels that
  # don't expose bytes_received.
  peer=""; bytes=0
  for ((i=1; i<=120; i++)); do            # up to ~30s
    read -r peer bytes < <(
      ss -tinp 2>/dev/null | awk -v p="pid=$ARIA_PID," '
        /ESTAB/ && $0 ~ p {
          pr=$5; br=0;
          if ((getline info) > 0) {
            n=split(info, a, " ");
            for (j=1;j<=n;j++) if (a[j] ~ /^bytes_received:/) { split(a[j],b,":"); br=b[2]+0 }
          }
          sc=br; if (pr ~ /:(443|80)$/) sc+=0.5;     # tiebreak toward web ports
          if (sc > bestsc) { bestsc=sc; bestpeer=pr; bestbr=br }
        }
        END { if (bestpeer != "") print bestpeer, bestbr+0 }') || true

    [[ -n "${peer:-}" && "${bytes:-0}" -gt 262144 ]] && break   # clear data flow
    [[ -n "${peer:-}" && $i -ge 12 ]] && break                  # fallback after ~3s
    if ! kill -0 "$ARIA_PID" 2>/dev/null; then
      echo "aria2c exited early — log:" >&2; sed -n '1,25p' "$ARIA_LOG" >&2; exit 1
    fi
    sleep 0.25
  done
  [[ -n "${peer:-}" ]] || die "could not find aria2c's data connection (no data flowing?)."
  SERVER_PORT="${peer##*:}"
  SERVER_IP="${peer%:*}"; SERVER_IP="${SERVER_IP#[}"; SERVER_IP="${SERVER_IP%]}"
  echo ">> data flow to $SERVER_IP:$SERVER_PORT — capturing + sampling for ${DURATION}s"
fi

LYR=ip; [[ "$SERVER_IP" == *:* ]] && LYR=ipv6

# ---------------- scoped capture (this peer only) ----------------
# -s 128 keeps headers only; bytes_in_flight/tcp.len derive from the IP length field,
# so truncation doesn't affect the analysis. The BPF "host" filter means no other
# traffic is written to the pcap.
"${SUDO[@]}" tcpdump -i any -s 128 -nn -w "$PCAP" "host $SERVER_IP and tcp" >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 0.4

# ---------------- sample the live socket ----------------
: > "$SAMPLES"
end=$(( $(date +%s) + DURATION ))
while [[ $(date +%s) -lt $end ]]; do
  info=$(ss -tiem dst "$SERVER_IP" 2>/dev/null | tr '\n' ' ' || true)
  if [[ -n "$info" ]]; then
    rtt=$(grep -oP 'rtt:\K[0-9.]+'           <<<"$info" | head -1 || true)
    ws=$(grep  -oP 'wscale:\K[0-9]+,[0-9]+'  <<<"$info" | head -1 || true)
    rs=$(grep  -oP 'rcv_space:\K[0-9]+'      <<<"$info" | head -1 || true)
    br=$(grep  -oP 'bytes_received:\K[0-9]+' <<<"$info" | head -1 || true)
    echo "$(date +%s) rtt=${rtt:-} wscale=${ws:-} rcv_space=${rs:-} bytes_received=${br:-}" >> "$SAMPLES"
  fi
  left=$(( end - $(date +%s) )); printf '\r   sampling... %2ss left ' "$left"
  sleep 1
done
printf '\r%*s\r' 30 ' '

# ---------------- stop capture + download ----------------
[[ -n "$TCPDUMP_PID" ]] && { "${SUDO[@]}" kill -INT "$TCPDUMP_PID" 2>/dev/null || true; }
sleep 1
[[ -n "$ARIA_PID" ]] && { kill "$ARIA_PID" 2>/dev/null || true; }
[[ ${#SUDO[@]} -gt 0 ]] && { "${SUDO[@]}" chown "$(id -un):$(id -gn)" "$PCAP" 2>/dev/null || true; }

# ---------------- parse ss samples ----------------
RTT_MS=$(awk '{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="rtt"&&kv[2]!="")print kv[2]}}' "$SAMPLES" | sort -n | head -1 || true)
WSCALE=$(awk '{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="wscale"&&kv[2]!="")w=kv[2]}} END{print w}' "$SAMPLES" || true)
RCVSPACE=$(awk '{for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="rcv_space"&&kv[2]!="")print kv[2]}}' "$SAMPLES" | sort -n | tail -1 || true)

read -r T0 B0 < <(awk '{e=$1;v="";for(i=1;i<=NF;i++){split($i,kv,"=");if(kv[1]=="bytes_received")v=kv[2]} if(v!=""){print e,v;exit}}' "$SAMPLES") || true
read -r T1 B1 < <(awk '{e=$1;v="";for(i=1;i<=NF;i++){split($i,kv,"=");if(kv[1]=="bytes_received")v=kv[2]} if(v!=""){le=e;lv=v}} END{if(lv!="")print le,lv}' "$SAMPLES") || true
THR_BPS=0
if [[ -n "${T0:-}" && -n "${T1:-}" && "${T1:-0}" -gt "${T0:-0}" && "${B1:-0}" -gt "${B0:-0}" ]]; then
  THR_BPS=$(awk -v b1="$B1" -v b0="$B0" -v t1="$T1" -v t0="$T0" 'BEGIN{printf "%.0f",(b1-b0)/(t1-t0)}')
fi

RCV_WSCALE="${WSCALE##*,}"; [[ "$RCV_WSCALE" =~ ^[0-9]+$ ]] || RCV_WSCALE=""

# ---------------- analyze the scoped pcap ----------------
tshark -r "$PCAP" -Y "${LYR}.src==${SERVER_IP} && tcp.analysis.bytes_in_flight" \
       -T fields -e tcp.analysis.bytes_in_flight 2>/dev/null | sort -n > "$WORK/inflight.txt" || true
PEAK_IF=$(tail -1 "$WORK/inflight.txt" 2>/dev/null || true)
P95_IF=$(awk '{a[NR]=$1} END{ if(NR==0){print ""; exit} k=int(NR*0.95+0.5); if(k<1)k=1; if(k>NR)k=NR; print a[k] }' "$WORK/inflight.txt" || true)

# your advertised receive window = max raw window (client->server) x 2^rcv_wscale.
# The raw 16-bit value is always readable; the scale comes from ss, so we don't need
# to have captured the handshake.
MAXRAW=$(tshark -r "$PCAP" -Y "${LYR}.dst==${SERVER_IP}" -T fields -e tcp.window_size_value 2>/dev/null | sort -n | tail -1 || true)
MAXRWND=0
if [[ "$MAXRAW" =~ ^[0-9]+$ && -n "$RCV_WSCALE" ]]; then
  MAXRWND=$(awk -v r="$MAXRAW" -v s="$RCV_WSCALE" 'BEGIN{printf "%.0f", r*(2^s)}')
fi

# throughput fallback from the pcap if ss lacked bytes_received
if [[ "${THR_BPS:-0}" -eq 0 ]]; then
  SRVBYTES=$(tshark -r "$PCAP" -Y "${LYR}.src==${SERVER_IP}" -T fields -e tcp.len 2>/dev/null | awk '{s+=$1} END{printf "%.0f",s+0}' || true)
  THR_BPS=$(awk -v s="${SRVBYTES:-0}" -v d="$DURATION" 'BEGIN{printf "%.0f",(d>0)?s/d:0}')
fi

# numeric defaults
RTT_MS="${RTT_MS:-0}"; RCVSPACE="${RCVSPACE:-0}"
[[ "$PEAK_IF" =~ ^[0-9]+$ ]] || PEAK_IF=0
[[ "$P95_IF"  =~ ^[0-9]+$ ]] || P95_IF=0
[[ "$MAXRWND" =~ ^[0-9]+$ ]] || MAXRWND=0

# ---------------- report ----------------
echo
echo "======================  TCP single-flow window check  ======================"
printf "  server                : %s:%s\n" "$SERVER_IP" "$SERVER_PORT"

awk -v rtt_ms="$RTT_MS" -v thr="$THR_BPS" -v line_mbit="$LINE_RATE_MBIT" \
    -v peak="$PEAK_IF" -v p95="$P95_IF" -v rwnd="$MAXRWND" -v rcvspace="$RCVSPACE" \
    -v ws="${WSCALE:-?}" -v maxraw="${MAXRAW:-?}" -v rcvws="${RCV_WSCALE:-?}" -v srvip="$SERVER_IP" '
function mib(b){ return b/1048576.0 }
BEGIN{
  rtt=rtt_ms/1000.0;
  line=line_mbit*1000000.0/8.0;          # bytes/s
  bdp=line*rtt;                          # bytes needed to fill the line at this RTT
  pct=(line>0)?100.0*thr/line:0;
  sustained=thr*rtt;                     # avg bytes in flight = throughput x RTT
  srv=(p95>0)?p95:peak;                  # effective server window used for the verdict

  printf "  min RTT               : %.1f ms\n", rtt_ms;
  printf "  throughput            : %.1f MiB/s  (%.0f Mbit/s, %.0f%% of %d Mbit line)\n",
         thr/1048576.0, thr*8/1e6, pct, line_mbit;
  printf "  target BDP @ line     : %.2f MiB   (= line_rate x RTT)\n", mib(bdp);
  printf "  server in-flight      : peak %.2f / p95 %.2f MiB\n", mib(peak), mib(p95);
  printf "  sustained in-flight   : %.2f MiB   (= throughput x RTT)\n", mib(sustained);
  if(rwnd>0)     printf "  your recv window (adv): %.2f MiB   (raw %s x 2^%s)\n", mib(rwnd), maxraw, rcvws;
  if(rcvspace>0) printf "  your rcv_space (ss)   : %.2f MiB\n", mib(rcvspace);
  printf "  window scale (ss)     : %s\n", ws;
  print  "----------------------------------------------------------------------------";

  eff_rwnd=(rwnd>0)?rwnd:rcvspace;       # best available estimate of your receive window

  if(srv==0 && eff_rwnd==0){
    v="could not measure windows (capture too short or no flow). Increase DURATION,\n  or inspect `ss -tiem dst <ip>` while a download runs.";
  } else if(thr >= 0.85*line){
    v="OK — a single flow is already ~line rate. Nothing to fix.";
  } else if(srv>0 && eff_rwnd>0 && srv < 0.85*eff_rwnd && srv < 0.9*bdp){
    v=sprintf("SERVER SEND-WINDOW limited.\n  Server fills only ~%.2f MiB while you advertised ~%.2f MiB, and that is\n  below the BDP (~%.2f MiB). That is the server send buffer/cwnd — not\n  fixable on your box. Use parallel connections, or BBR on the *sender*.",
            mib(srv), mib(eff_rwnd), mib(bdp));
  } else if(eff_rwnd>0 && eff_rwnd < 0.9*bdp && (srv==0 || srv >= 0.85*eff_rwnd)){
    v=sprintf("RECEIVE-WINDOW limited (YOUR side).\n  Your window (~%.2f MiB) is below the BDP (~%.2f MiB) and the server is\n  filling it. Raise net.ipv4.tcp_rmem (3rd value) past the BDP, then retest.\n  e.g.  sudo sysctl -w net.ipv4.tcp_rmem=\"4096 131072 33554432\"",
            mib(eff_rwnd), mib(bdp));
  } else {
    v=sprintf("LOSS / CONGESTION limited (single-flow ceiling).\n  Your window (~%.2f MiB) and the server in-flight (~%.2f MiB) both exceed\n  the BDP (~%.2f MiB), yet throughput is only %.0f%% of line. That gap is\n  retransmits and/or path queueing, not a buffer. Confirm with:\n    mtr --report --report-cycles 100 %s\n    ping %s    # while a download runs; RTT climbing = bufferbloat\n  Workarounds: parallel connections, or BBR on the *sender* (servers you own).",
            mib(eff_rwnd), mib(srv), mib(bdp), pct, srvip, srvip);
  }
  print "  VERDICT: " v;
  print "============================================================================";
}'
