# tcp-window-check

Diagnose why a **single TCP connection** can't fill your link. The script drives one flow
to a target, measures the live socket plus a scoped packet capture, and tells you whether
the ceiling is **your receive window**, the **server's send window/cwnd**, or
**loss/congestion** on the path — by cross-checking in-flight bytes and your advertised
window against the bandwidth-delay product (BDP).

Useful when a 1 Gbit line tests near line-rate locally but a single-stream download to a
distant server stalls at a fraction of that, and you want to know whether it's your box,
the server, or the path — before blaming the ISP.

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
```

Run it as a **normal user** — only `tcpdump` self-elevates via `sudo`. Running the whole
thing under `sudo` would needlessly run the downloader as root.

### Env knobs

| Variable         | Default                  | Meaning                                                        |
|------------------|--------------------------|----------------------------------------------------------------|
| `DURATION`       | `15`                     | Seconds to sample; also bounds the transient download size.    |
| `LINE_RATE_MBIT` | `1000`                   | Your link rate, for the BDP and %-of-line figures.             |
| `WORKDIR`        | `/var/tmp`               | Disk-backed scratch dir (avoid `/tmp`, often tmpfs/RAM).        |
| `ARIA2_OPTS`     | single-connection flags  | Override the downloader flags.                                 |
| `DEBUG`          | `0`                      | `set -x` tracing.                                              |

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
