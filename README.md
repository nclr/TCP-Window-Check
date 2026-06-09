# tcp-window-check

🇬🇧 English · 🇬🇷 [Ελληνικά](README.el.md)

Diagnose why a **single TCP connection** can't fill your link. The script drives one flow
to a target, measures the live socket plus a scoped packet capture, and tells you whether
the ceiling is **your receive window**, the **server's send window/cwnd**, or
**loss/congestion** on the path — by cross-checking in-flight bytes and your advertised
window against the bandwidth-delay product (BDP).

Useful when a 1 Gbit line tests near line-rate locally but a single-stream download to a
distant server stalls at a fraction of that, and you want to know whether it's your box,
the server, or the path — before blaming the ISP.

## Terminology

- **RTT (round-trip time)** — how long a packet takes to reach the server and the
  acknowledgement to come back. Every TCP window mechanism scales with it.
  *Example: Amsterdam from Athens might be ~45 ms; a server in the same city ~2 ms.*
- **BDP (bandwidth-delay product)** — `line_rate × RTT`: how many bytes must be "in the
  air" (sent but not yet acknowledged) at any instant to keep the line full.
  *Example: 1 Gbit/s × 45 ms = 125 MB/s × 0.045 s ≈ 5.6 MB. Below ~5.6 MB of in-flight
  data, that link physically cannot run at 1 Gbit/s with a single flow.*
- **Receive window (rwnd)** — how much data *you* tell the server it may send before it
  must stop and wait for your ACKs. Advertised in every packet you send back; capped by
  your kernel's `net.ipv4.tcp_rmem`.
  *Example: with a 2 MiB window on a 45 ms path, a flow tops out at 2 MiB / 0.045 s ≈
  355 Mbit/s — no matter how fast the line is.*
- **Send window / cwnd (congestion window)** — the server-side equivalent: how much
  un-ACKed data the *sender* is willing to keep in flight, limited by its send buffer
  (`tcp_wmem`) and its congestion-control algorithm.
  *Example: a server capped at 0.6 MiB in flight delivers at most 0.6 MiB / 0.045 s ≈
  107 Mbit/s to you, even if both your window and your line are huge.*
- **In-flight bytes** — data already sent but not yet acknowledged, measured from the
  capture. Peak shows the most the server ever risked; p95 is a steadier estimate.
- **Sustained in-flight** — `throughput × RTT`, the in-flight level actually *maintained*
  on average. A big gap between peak and sustained means bursts followed by back-off —
  a loss/queueing signal.
- **Window scale** — TCP's window field is only 16 bits (max 64 KiB), so both ends agree
  on a multiplier at handshake. *Example: raw 49152 with scale 7 → 49152 × 2⁷ = 6 MiB.*
- **rcv_space** — the kernel's running estimate of the receive buffer this socket needs;
  a lower-bound hint for your window when the capture misses it.
- **Bufferbloat** — oversized queues in routers fill up under load, inflating the RTT
  (and therefore the BDP) instead of dropping packets early.
  *Example: idle ping 15 ms that climbs to 200 ms during a download is bufferbloat.*
- **CUBIC / BBR** — congestion-control algorithms on the *sender*. CUBIC (the default)
  halves its rate on loss and recovers slowly on long paths; BBR models the path's
  bandwidth and RTT instead, and tolerates light loss far better.

## Requirements (Linux only)

`ss` (iproute2), `tcpdump`, `tshark`, `awk`, GNU `grep` (with `-P`), `sed`, coreutils,
`getent` (glibc), and `aria2c` for URL mode. `sudo` is used only to elevate the capture
when you are not root.

```sh
sudo apt-get update
sudo apt-get install -y aria2 tcpdump tshark iproute2 gawk
# optional, used only in the loss/congestion follow-up:
sudo apt-get install -y mtr-tiny
```

The script re-checks every dependency at startup and prints the exact `apt-get install`
line for anything missing, so you don't have to guess.

## Usage

```sh
chmod +x tcp-window-check.sh

# drive a single-connection download and measure it:
./tcp-window-check.sh "https://example.com/largefile.bin"

# or attach to a flow you start yourself (e.g. your own `aria2c -x1`) to an IP:
HOST=203.0.113.7 ./tcp-window-check.sh

# or test a whole list of servers one by one and get a ranked summary table:
./tcp-window-check.sh --servers servers.example.txt
```

The server-list file holds one URL per line (`#` comments and blank lines are ignored).
`servers.example.txt` ships with [DataPacket's European speed-test files](https://www.datapacket.com/speed-test-files/europe)
as a ready-made example — useful for picking the best mirror or comparing routes.

Run it as a **normal user** — only `tcpdump` self-elevates via `sudo`. Running the whole
thing under `sudo` would needlessly run the downloader as root.

Output is colorized when stdout is a terminal (verdicts are color-coded: green OK,
yellow receive-window, magenta server send-window, red loss/congestion). Colors are
disabled automatically when piping to a file, and the [`NO_COLOR`](https://no-color.org/)
convention is honoured.

### Env knobs

| Variable         | Default                  | Meaning                                                        |
|------------------|--------------------------|----------------------------------------------------------------|
| `DURATION`       | `15`                     | Seconds to sample; also bounds the transient download size.    |
| `LINE_RATE_MBIT` | `1000`                   | Your link rate, for the BDP and %-of-line figures.             |
| `WORKDIR`        | `/var/tmp`               | Disk-backed scratch dir (avoid `/tmp`, often tmpfs/RAM).        |
| `ARIA2_OPTS`     | single-connection flags  | Override the downloader flags.                                 |
| `DEBUG`          | `0`                      | `set -x` tracing.                                              |

## Example output

A single run prints every metric with a plain-English explanation, a bar chart comparing
the windows against the BDP, and a verdict that explains what happened, why, and what to do:

```
======================  TCP single-flow window check  ======================
  server                : 138.199.14.66:443
  min RTT               : 14.1 ms
      round-trip time to the server; every TCP window mechanism below scales with it
  throughput            : 38.1 MiB/s  (320 Mbit/s, 32% of 1000 Mbit line)
      what this single connection actually achieved during the sample
  target BDP @ line     : 1.68 MiB   (= line_rate x RTT)
      bandwidth-delay product: how many bytes must be "in the air" at once
      to keep your full line busy at this RTT. The yardstick for everything below.
  server in-flight      : peak 0.61 / p95 0.58 MiB
      unacknowledged bytes the server kept on the wire (its send window / cwnd)
  sustained in-flight   : 0.54 MiB   (= throughput x RTT)
      the average actually sustained — if far below peak, the flow was bursty
  your recv window (adv): 6.00 MiB   (raw 49152 x 2^7)
      the most data YOU told the server it may send before waiting for ACKs
  window scale (ss)     : 7,7   (snd,rcv shift; raw 16-bit window x 2^scale)
----------------------------------------------------------------------------
  Windows vs the BDP (longer bar = more bytes):
    BDP target       ███████████                              1.68 MiB
    server in-flight ████                                     0.58 MiB
    your window      ████████████████████████████████████████ 6.00 MiB
    sustained        ████                                     0.54 MiB
    Whichever bar stops short of the BDP bar is the likely bottleneck;
    if all bars reach it but throughput is still low, suspect loss/queueing.
----------------------------------------------------------------------------
  VERDICT: SERVER SEND-WINDOW limited (the remote end is the bottleneck).
  What happened: you offered the server room for ~6.00 MiB of un-ACKed data,
  but it never kept more than ~0.58 MiB in flight — below the ~1.68 MiB (BDP)
  needed to fill your line at this RTT. [...]
  What you can do (nothing on your box will fix this):
    - use parallel connections (aria2c -x8, or a download manager)
    - if you control the server: raise tcp_wmem and consider BBR there
    - or simply pick a closer/better mirror (lower RTT shrinks the BDP)
============================================================================
```

A `--servers` run additionally ends with a summary sorted by RTT (closest first) and a
throughput bar graph per server, colored by verdict:

```
=====================  SUMMARY (sorted by RTT, closest first)  ====================
    RTT ms    Mbit/s   %line  verdict                  server   url
------------------------------------------------------------------------------------
       8.2       940     94%  OK                       ams      https://ams.download.datapacket.com/1000mb.bin
      14.1       320     32%  SERVER SEND-WINDOW limited fra    https://fra.download.datapacket.com/1000mb.bin
      22.5       610     61%  RECEIVE-WINDOW limited   lon      https://lon.download.datapacket.com/1000mb.bin
      48.9        85      8%  LOSS / CONGESTION limited ath     https://ath.download.datapacket.com/1000mb.bin
------------------------------------------------------------------------------------
  Throughput per server (bar = single-flow Mbit/s, color = verdict):

  ams          8.2 ms  ██████████████████████████████████████████████████ 940
  fra         14.1 ms  █████████████████ 320
  lon         22.5 ms  ████████████████████████████████ 610
  ath         48.9 ms  ████ 85

  Legend: OK  RECEIVE-WINDOW (yours, fixable)  SERVER SEND-WINDOW  LOSS/CONGESTION
  Sorted by RTT: the closest server is listed first, but the bar shows what a
  single flow actually achieved — a nearby server with a short bar and a
  SERVER/LOSS verdict is a worse mirror than a farther one with a long bar.
====================================================================================
```

## Reading the verdict

- **RECEIVE-WINDOW limited** — your buffer caps the window below the BDP and the server is
  filling it. Raise `net.ipv4.tcp_rmem` (3rd value) past the BDP, e.g.
  `sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432"`, and persist it under
  `/etc/sysctl.d/`. Rule of thumb: set the max to ~2× the BDP you want to support (the
  kernel reserves part of the buffer for overhead).
- **SERVER SEND-WINDOW limited** — the server puts less than a BDP in flight. Not fixable
  on your side; use parallel connections, or BBR on the sender (a box you control).
- **LOSS / CONGESTION limited** — windows are large enough but throughput lags. Check loss
  (`mtr`) and loaded latency (`ping` during a download — climbing RTT means bufferbloat).
  Workarounds: parallel connections, or BBR on the sender.
- **OK** — a single flow already runs near line rate.

The numbers printed above the verdict are the evidence; the verdict line is a heuristic
summary, not gospel. In particular, "server in-flight: peak / p95" is the most the server
ever had unacknowledged; the gap between that and "sustained in-flight" (throughput × RTT)
is itself the loss/queueing signal.

## How it works

1. Launches a single-connection download and finds the **real** peer IP from the
   downloader's own socket (so it follows redirects to a CDN node instead of measuring the
   wrong connection).
2. Starts a `tcpdump` capture **scoped to that one peer** (BPF `host` filter — no other
   traffic is written).
3. Samples `ss -tiem` once a second for RTT, window scale, `rcv_space`, and bytes received.
4. Reads peak/p95 in-flight bytes from the capture, and reconstructs your advertised
   receive window as `raw_window × 2^rcv_wscale` (scale from `ss`, so the handshake doesn't
   need to be captured).
5. Compares everything to the BDP and prints the verdict.

## Caveats

- The capture is scoped to the single peer IP (it does **not** sniff other traffic), but
  prefer a machine you own regardless.
- A transient download (~ `throughput × DURATION`) is written under `WORKDIR` and removed
  on exit. Lower `DURATION` to shrink it.
- Some `ss` fields (`bytes_received`) depend on kernel / iproute2 version; the script falls
  back to the capture for throughput when they're absent.
- The verdict uses fudge factors (0.85 / 0.9) and is meant as a fast triage, not a
  certified measurement.

## License

MIT — see [LICENSE](LICENSE). Replace the copyright holder line before publishing.
