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
#   ./tcp-window-check.sh <URL>            # downloads via aria2c -x1 and measures it
#   ./tcp-window-check.sh --servers FILE   # test every URL listed in FILE, one by one,
#                                          # then print a ranked summary table
#   HOST=1.2.3.4 ./tcp-window-check.sh     # attach to a flow you start yourself to HOST
#
# Server-list file format: one URL per line; blank lines and lines starting with '#'
# are ignored. See servers.example.txt (DataPacket European speed-test files).
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

# ---------------- colors ----------------
# Colored when stdout is a terminal (or FORCE_COLOR=1, used by batch mode whose
# children write into a pipe). Honour the NO_COLOR convention.
if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ "${FORCE_COLOR:-0}" == 1 ]]; }; then
  C_RST=$'\e[0m'; C_BLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_MAG=$'\e[35m'; C_CYN=$'\e[36m'
else
  C_RST=""; C_BLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""
fi

# ---------------- batch mode (--servers FILE) ----------------
# Runs this script once per URL in FILE (sequentially — capture and socket
# sampling cannot safely overlap) and prints a ranked summary at the end.
if [[ "${URL:-}" == "--servers" || "${URL:-}" == "-l" ]]; then
  LIST="${2:-}"
  [[ -n "$LIST" ]] || die "--servers needs a file argument"
  [[ -r "$LIST" ]] || die "cannot read server list: $LIST"

  # strip inline '#' comments and surrounding whitespace, drop empty lines
  mapfile -t TARGETS < <(sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$')
  (( ${#TARGETS[@]} )) || die "no URLs found in $LIST"

  SUMMARY="$(mktemp)"
  trap 'rm -f "$SUMMARY"' EXIT
  # children write into a pipe, so tell them to keep their colors if we have a tty
  KIDCOLOR=0; [[ -t 1 && -z "${NO_COLOR:-}" ]] && KIDCOLOR=1
  n=0
  for t in "${TARGETS[@]}"; do
    n=$((n+1))
    echo
    printf '%s############################################################################%s\n' "$C_CYN" "$C_RST"
    printf '%s##  [%d/%d] %s%s\n' "$C_CYN$C_BLD" "$n" "${#TARGETS[@]}" "$t" "$C_RST"
    printf '%s############################################################################%s\n' "$C_CYN" "$C_RST"
    out="$(FORCE_COLOR=$KIDCOLOR bash "$0" "$t" 2>&1)" || true
    printf '%s\n' "$out"
    # parse on a color-stripped copy so ANSI codes never break the regexes
    plain="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
    mbit=$(grep -oP '\(\K[0-9]+(?= Mbit/s)' <<<"$plain" | head -1 || true)
    pct=$(grep -oP ', \K[0-9]+(?=% of)' <<<"$plain" | head -1 || true)
    rtt=$(grep -oP 'min RTT\s*:\s*\K[0-9.]+' <<<"$plain" | head -1 || true)
    verdict=$(grep -oP 'VERDICT: \K[A-Za-z /-]+' <<<"$plain" | head -1 | sed 's/ *$//' || true)
    # short label: first host component (ams.download... -> ams)
    host="${t#*://}"; host="${host%%/*}"; label="${host%%.*}"
    printf '%s|%s|%s|%s|%s|%s\n' "${rtt:-99999}" "${mbit:-0}" "${pct:-0}" "${verdict:-run failed}" "$label" "$t" >> "$SUMMARY"
  done

  # color for a verdict tag
  vcol() {
    case "$1" in
      OK*)               printf '%s' "$C_GRN" ;;
      RECEIVE-WINDOW*)   printf '%s' "$C_YEL" ;;
      SERVER*)           printf '%s' "$C_MAG" ;;
      LOSS*)             printf '%s' "$C_RED" ;;
      *)                 printf '%s' "$C_DIM" ;;
    esac
  }

  echo
  printf '%s=====================  SUMMARY (sorted by RTT, closest first)  ====================%s\n' "$C_BLD" "$C_RST"
  printf '  %s%8s  %8s  %6s  %-24s %-8s %s%s\n' "$C_BLD" "RTT ms" "Mbit/s" "%line" "verdict" "server" "url" "$C_RST"
  echo "------------------------------------------------------------------------------------"
  MAXMBIT=$(sort -t'|' -k2,2nr "$SUMMARY" | head -1 | cut -d'|' -f2)
  [[ "$MAXMBIT" =~ ^[0-9]+$ && "$MAXMBIT" -gt 0 ]] || MAXMBIT=1
  sort -t'|' -k1,1n "$SUMMARY" | while IFS='|' read -r rtt mbit pct verdict label t; do
    [[ "$rtt" == "99999" ]] && rtt="-"
    printf '  %8s  %8s  %5s%%  %s%-24s%s %-8s %s%s%s\n' \
      "$rtt" "$mbit" "$pct" "$(vcol "$verdict")" "$verdict" "$C_RST" "$label" "$C_DIM" "$t" "$C_RST"
  done
  echo "------------------------------------------------------------------------------------"
  printf '%s  Throughput per server (bar = single-flow Mbit/s, color = verdict):%s\n' "$C_BLD" "$C_RST"
  echo
  sort -t'|' -k1,1n "$SUMMARY" | while IFS='|' read -r rtt mbit pct verdict label t; do
    [[ "$mbit" =~ ^[0-9]+$ ]] || mbit=0
    width=$(( mbit * 50 / MAXMBIT )); (( mbit > 0 && width < 1 )) && width=1
    bar=""; for ((b=0; b<width; b++)); do bar+="█"; done
    [[ -z "$bar" ]] && bar="▏"
    [[ "$rtt" == "99999" ]] && rtt="-"
    printf '  %-8s %7s ms  %s%s%s %s\n' "$label" "$rtt" "$(vcol "$verdict")" "$bar" "$C_RST" "$mbit"
  done
  echo
  printf '  Legend: %sOK%s  %sRECEIVE-WINDOW (yours, fixable)%s  %sSERVER SEND-WINDOW%s  %sLOSS/CONGESTION%s\n' \
    "$C_GRN" "$C_RST" "$C_YEL" "$C_RST" "$C_MAG" "$C_RST" "$C_RED" "$C_RST"
  echo "  Sorted by RTT: the closest server is listed first, but the bar shows what a"
  echo "  single flow actually achieved — a nearby server with a short bar and a"
  echo "  SERVER/LOSS verdict is a worse mirror than a farther one with a long bar."
  echo "===================================================================================="
  exit 0
fi

ATTACH=0
if [[ -z "$URL" ]]; then
  if [[ -n "${HOST:-}" ]]; then ATTACH=1; else
    echo "usage: $0 <URL>    or    $0 --servers <file>    or    HOST=<ip> $0" >&2
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
printf '%s======================  TCP single-flow window check  ======================%s\n' "$C_BLD$C_CYN" "$C_RST"
printf "  %sserver                :%s %s:%s\n" "$C_BLD" "$C_RST" "$SERVER_IP" "$SERVER_PORT"

awk -v rtt_ms="$RTT_MS" -v thr="$THR_BPS" -v line_mbit="$LINE_RATE_MBIT" \
    -v peak="$PEAK_IF" -v p95="$P95_IF" -v rwnd="$MAXRWND" -v rcvspace="$RCVSPACE" \
    -v ws="${WSCALE:-?}" -v maxraw="${MAXRAW:-?}" -v rcvws="${RCV_WSCALE:-?}" -v srvip="$SERVER_IP" \
    -v cR="$C_RST" -v cB="$C_BLD" -v cD="$C_DIM" -v cG="$C_GRN" -v cY="$C_YEL" \
    -v cM="$C_MAG" -v cRD="$C_RED" -v cC="$C_CYN" '
function mib(b){ return b/1048576.0 }
function bar(v, max, w,   n, s, i){
  n=int(v/max*w+0.5); if(v>0 && n<1) n=1; if(n>w) n=w;
  s=""; for(i=0;i<n;i++) s=s "█";
  if(s=="") { s="▏"; n=1 }
  for(i=n;i<w;i++) s=s " ";   # pad here: %-Ns miscounts multibyte block chars
  return s;
}
BEGIN{
  rtt=rtt_ms/1000.0;
  line=line_mbit*1000000.0/8.0;          # bytes/s
  bdp=line*rtt;                          # bytes needed to fill the line at this RTT
  pct=(line>0)?100.0*thr/line:0;
  sustained=thr*rtt;                     # avg bytes in flight = throughput x RTT
  srv=(p95>0)?p95:peak;                  # effective server window used for the verdict

  # color for the %-of-line figure: green >=85, yellow >=40, red below
  pcol=(pct>=85)?cG:((pct>=40)?cY:cRD);

  printf "  %smin RTT               :%s %.1f ms\n", cB, cR, rtt_ms;
  printf "  %s    round-trip time to the server; every TCP window mechanism below scales with it%s\n", cD, cR;
  printf "  %sthroughput            :%s %.1f MiB/s  (%.0f Mbit/s, %s%.0f%%%s of %d Mbit line)\n",
         cB, cR, thr/1048576.0, thr*8/1e6, pcol, pct, cR, line_mbit;
  printf "  %s    what this single connection actually achieved during the sample%s\n", cD, cR;
  printf "  %starget BDP @ line     :%s %.2f MiB   (= line_rate x RTT)\n", cB, cR, mib(bdp);
  printf "  %s    bandwidth-delay product: how many bytes must be \"in the air\" at once%s\n", cD, cR;
  printf "  %s    to keep your full line busy at this RTT. The yardstick for everything below.%s\n", cD, cR;
  printf "  %sserver in-flight      :%s peak %.2f / p95 %.2f MiB\n", cB, cR, mib(peak), mib(p95);
  printf "  %s    unacknowledged bytes the server kept on the wire (its send window / cwnd)%s\n", cD, cR;
  printf "  %ssustained in-flight   :%s %.2f MiB   (= throughput x RTT)\n", cB, cR, mib(sustained);
  printf "  %s    the average actually sustained — if far below peak, the flow was bursty%s\n", cD, cR;
  if(rwnd>0) {
    printf "  %syour recv window (adv):%s %.2f MiB   (raw %s x 2^%s)\n", cB, cR, mib(rwnd), maxraw, rcvws;
    printf "  %s    the most data YOU told the server it may send before waiting for ACKs%s\n", cD, cR;
  }
  if(rcvspace>0) printf "  %syour rcv_space (ss)   :%s %.2f MiB   (kernel buffer estimate for this socket)\n", cB, cR, mib(rcvspace);
  printf "  %swindow scale (ss)     :%s %s   (snd,rcv shift; raw 16-bit window x 2^scale)\n", cB, cR, ws;
  print  "----------------------------------------------------------------------------";

  # ---- mini bar chart: everything scaled against the largest of the four ----
  eff_rwnd=(rwnd>0)?rwnd:rcvspace;
  srv=(p95>0)?p95:peak;
  bmax=bdp; if(srv>bmax)bmax=srv; if(eff_rwnd>bmax)bmax=eff_rwnd; if(sustained>bmax)bmax=sustained;
  if(bmax>0){
    printf "  %sWindows vs the BDP (longer bar = more bytes):%s\n", cB, cR;
    printf "    BDP target       %s%s%s  %.2f MiB\n", cC,  bar(bdp,bmax,40),       cR, mib(bdp);
    printf "    server in-flight %s%s%s  %.2f MiB\n", cM,  bar(srv,bmax,40),       cR, mib(srv);
    printf "    your window      %s%s%s  %.2f MiB\n", cY,  bar(eff_rwnd,bmax,40),  cR, mib(eff_rwnd);
    printf "    sustained        %s%s%s  %.2f MiB\n", cG,  bar(sustained,bmax,40), cR, mib(sustained);
    printf "  %s  Whichever bar stops short of the BDP bar is the likely bottleneck;%s\n", cD, cR;
    printf "  %s  if all bars reach it but throughput is still low, suspect loss/queueing.%s\n", cD, cR;
    print  "----------------------------------------------------------------------------";
  }
  printf "  %sHow to read this: a single TCP flow can never move more than%s\n", cD, cR;
  printf "  %smin(your receive window, server send window) / RTT. If both windows%s\n", cD, cR;
  printf "  %scomfortably exceed the BDP yet throughput is low, packet loss or%s\n", cD, cR;
  printf "  %squeueing on the path is the limiter instead.%s\n", cD, cR;
  print  "----------------------------------------------------------------------------";

  eff_rwnd=(rwnd>0)?rwnd:rcvspace;       # best available estimate of your receive window

  vc=cD;
  if(srv==0 && eff_rwnd==0){
    v="COULD NOT MEASURE.\n  Neither the server in-flight bytes nor your receive window could be read\n  (capture too short, flow ended early, or no data moved). What to do:\n    - increase DURATION (e.g. DURATION=30) so there is more steady-state to sample\n    - pick a larger test file so the download outlives the sample window\n    - inspect the live socket yourself: ss -tiem dst <ip>   while downloading";
  } else if(thr >= 0.85*line){
    v=sprintf("OK — not limited by TCP windows.\n  This single flow reached %.0f%% of your %d Mbit line, which is effectively\n  line rate (the last ~10-15%% is protocol overhead and pacing). Neither your\n  receive window nor the server send window is holding you back. If overall\n  speed still feels low, the bottleneck is the line rate itself — check\n  LINE_RATE_MBIT matches your actual subscription.", pct, line_mbit); vc=cG;
  } else if(srv>0 && eff_rwnd>0 && srv < 0.85*eff_rwnd && srv < 0.9*bdp){
    v=sprintf("SERVER SEND-WINDOW limited (the remote end is the bottleneck).\n  What happened: you offered the server room for ~%.2f MiB of un-ACKed data,\n  but it never kept more than ~%.2f MiB in flight — below the ~%.2f MiB (BDP)\n  needed to fill your line at this RTT. The remote send buffer or congestion\n  window is the cap, so a flow can do at most send_window/RTT regardless of\n  how fast your line is.\n  Why it happens: small net.ipv4.tcp_wmem on the server, conservative cwnd\n  growth (CUBIC after light loss), or a deliberate per-connection rate cap.\n  What you can do (nothing on your box will fix this):\n    - use parallel connections (aria2c -x8, or a download manager) — each flow\n      gets its own send window, so N flows ~ N x the single-flow ceiling\n    - if you control the server: raise tcp_wmem and consider BBR there\n    - or simply pick a closer/better mirror (lower RTT shrinks the BDP)",
            mib(eff_rwnd), mib(srv), mib(bdp)); vc=cM;
  } else if(eff_rwnd>0 && eff_rwnd < 0.9*bdp && (srv==0 || srv >= 0.85*eff_rwnd)){
    v=sprintf("RECEIVE-WINDOW limited (YOUR side is the bottleneck — good news: fixable).\n  What happened: you only advertised ~%.2f MiB of receive window, below the\n  ~%.2f MiB (BDP) needed at this RTT, and the server was filling what you\n  offered. The server must stop and wait for your ACKs, capping the flow at\n  receive_window/RTT no matter how fast the path is.\n  Why it happens: the kernel autotuning ceiling net.ipv4.tcp_rmem (3rd value)\n  is smaller than the BDP of this path — common defaults assume short RTTs.\n  Fix: raise the ceiling above the BDP and retest, e.g.\n    sudo sysctl -w net.ipv4.tcp_rmem=\"4096 131072 33554432\"\n  (33554432 = 32 MiB; persist in /etc/sysctl.d/ once confirmed. This only\n  raises a limit — memory is used per-socket only when actually needed.)",
            mib(eff_rwnd), mib(bdp)); vc=cY;
  } else {
    v=sprintf("LOSS / CONGESTION limited (the path, not a buffer, is the bottleneck).\n  What happened: your window (~%.2f MiB) and the server in-flight (~%.2f MiB)\n  are both big enough for the ~%.2f MiB BDP, yet you got only %.0f%% of line.\n  When both windows are ample but throughput is low, TCP is repeatedly backing\n  off — i.e. packets are being lost or delayed somewhere on the path, and\n  congestion control keeps cutting the sending rate.\n  Why it happens: a congested peering link, an overloaded server, Wi-Fi/last-\n  mile loss, or bufferbloat (queues inflating the RTT under load).\n  Confirm it:\n    mtr --report --report-cycles 100 %s   # loss appearing at a hop AND all\n                                          # hops after it = real path loss\n    ping %s   # while a download runs; steadily climbing RTT = bufferbloat\n  Workarounds: parallel connections average over the losses (aria2c -x8);\n  if you own the sender, BBR handles lossy paths far better than CUBIC.",
            mib(eff_rwnd), mib(srv), mib(bdp), pct, srvip, srvip); vc=cRD;
  }
  print "  " cB "VERDICT: " cR vc v cR;
  print "============================================================================";
}'
