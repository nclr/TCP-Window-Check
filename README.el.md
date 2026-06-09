# tcp-window-check

🇬🇧 [English](README.md) · 🇬🇷 Ελληνικά

Διάγνωση του γιατί μια **μεμονωμένη σύνδεση TCP** δεν μπορεί να γεμίσει τη γραμμή σας. Το
script οδηγεί μία ροή προς έναν στόχο, μετρά το ζωντανό socket μαζί με μια στοχευμένη
καταγραφή πακέτων, και σας λέει αν το όριο είναι **το δικό σας παράθυρο λήψης (receive
window)**, **το παράθυρο αποστολής/cwnd του server**, ή **απώλειες/συμφόρηση (loss/congestion)**
στη διαδρομή — διασταυρώνοντας τα bytes σε πτήση (in-flight) και το διαφημιζόμενο παράθυρό σας
με το γινόμενο εύρους ζώνης–καθυστέρησης (BDP).

Χρήσιμο όταν μια γραμμή 1 Gbit μετριέται κοντά στον ρυθμό γραμμής τοπικά, αλλά μια λήψη
μονής ροής προς απομακρυσμένο server κολλάει σε ένα κλάσμα αυτού, και θέλετε να ξέρετε αν
φταίει το μηχάνημά σας, ο server, ή η διαδρομή — πριν ρίξετε το φταίξιμο στον πάροχο.

## Απαιτήσεις (μόνο Linux)

`ss` (iproute2), `tcpdump`, `tshark`, `awk`, GNU `grep` (με `-P`), `sed`, coreutils,
`getent` (glibc), και `aria2c` για λειτουργία URL. Το `sudo` χρησιμοποιείται μόνο για την
ανύψωση δικαιωμάτων της καταγραφής όταν δεν είστε root.

```sh
sudo apt-get update
sudo apt-get install -y aria2 tcpdump tshark iproute2 gawk
# προαιρετικό, χρησιμοποιείται μόνο στον επακόλουθο έλεγχο απωλειών/συμφόρησης:
sudo apt-get install -y mtr-tiny
```

Το script επανελέγχει κάθε εξάρτηση κατά την εκκίνηση και τυπώνει την ακριβή εντολή
`apt-get install` για ό,τι λείπει, ώστε να μη χρειάζεται να μαντεύετε.

## Χρήση

```sh
chmod +x tcp-window-check.sh

# οδήγηση λήψης μονής σύνδεσης και μέτρησή της:
./tcp-window-check.sh "https://example.com/largefile.bin"

# ή σύνδεση σε μια ροή που ξεκινάτε εσείς (π.χ. το δικό σας `aria2c -x1`) προς μια IP:
HOST=203.0.113.7 ./tcp-window-check.sh

# ή δοκιμή μιας ολόκληρης λίστας server, ένας-ένας, με συγκεντρωτικό πίνακα κατάταξης:
./tcp-window-check.sh --servers servers.example.txt
```

Το αρχείο λίστας περιέχει ένα URL ανά γραμμή (σχόλια με `#` και κενές γραμμές αγνοούνται).
Το `servers.example.txt` έρχεται έτοιμο με τα [ευρωπαϊκά αρχεία speed-test της DataPacket](https://www.datapacket.com/speed-test-files/europe)
— χρήσιμο για επιλογή του καλύτερου mirror ή σύγκριση διαδρομών.

Τρέξτε το ως **κανονικός χρήστης** — μόνο το `tcpdump` ανυψώνει δικαιώματα μόνο του μέσω
`sudo`. Το να τρέξετε ολόκληρο το script υπό `sudo` θα έτρεχε άσκοπα τον downloader ως root.

Η έξοδος έχει χρώματα όταν το stdout είναι τερματικό (τα πορίσματα κωδικοποιούνται
χρωματικά: πράσινο OK, κίτρινο receive-window, ματζέντα server send-window, κόκκινο
loss/congestion). Τα χρώματα απενεργοποιούνται αυτόματα όταν η έξοδος πηγαίνει σε αρχείο,
και η σύμβαση [`NO_COLOR`](https://no-color.org/) γίνεται σεβαστή.

### Μεταβλητές περιβάλλοντος

| Μεταβλητή        | Προεπιλογή               | Σημασία                                                         |
|------------------|--------------------------|----------------------------------------------------------------|
| `DURATION`       | `15`                     | Δευτερόλεπτα δειγματοληψίας· οριοθετεί και το μέγεθος της λήψης.|
| `LINE_RATE_MBIT` | `1000`                   | Ο ρυθμός γραμμής σας, για το BDP και τα ποσοστά γραμμής.        |
| `WORKDIR`        | `/var/tmp`               | Προσωρινός φάκελος σε δίσκο (αποφύγετε το `/tmp`, συχνά σε RAM).|
| `ARIA2_OPTS`     | flags μονής σύνδεσης     | Αντικατάσταση των flags του downloader.                        |
| `DEBUG`          | `0`                      | Ιχνηλάτηση με `set -x`.                                         |

## Παράδειγμα εξόδου

Μια απλή εκτέλεση τυπώνει κάθε μετρική με επεξήγηση σε απλή γλώσσα, ένα ραβδόγραμμα που
συγκρίνει τα παράθυρα με το BDP, και ένα πόρισμα που εξηγεί τι συνέβη, γιατί, και τι να κάνετε:

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

Μια εκτέλεση με `--servers` καταλήγει επιπλέον σε σύνοψη ταξινομημένη κατά RTT (ο
κοντινότερος πρώτος) και σε ραβδόγραμμα ταχύτητας ανά server, χρωματισμένο κατά πόρισμα:

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
====================================================================================
```

## Ανάγνωση του πορίσματος

- **RECEIVE-WINDOW limited** (όριο το παράθυρο λήψης) — ο buffer σας περιορίζει το παράθυρο
  κάτω από το BDP και ο server το γεμίζει. Αυξήστε το `net.ipv4.tcp_rmem` (3η τιμή) πάνω από
  το BDP, π.χ. `sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432"`, και κάντε το μόνιμο
  στο `/etc/sysctl.d/`. Πρακτικός κανόνας: ορίστε το μέγιστο σε ~2× το BDP που θέλετε να
  υποστηρίξετε (ο πυρήνας κρατά μέρος του buffer για overhead).
- **SERVER SEND-WINDOW limited** (όριο το παράθυρο αποστολής του server) — ο server βάζει
  λιγότερο από ένα BDP σε πτήση. Δεν διορθώνεται από την πλευρά σας· χρησιμοποιήστε
  παράλληλες συνδέσεις, ή BBR στον αποστολέα (ένα μηχάνημα που ελέγχετε).
- **LOSS / CONGESTION limited** (όριο απώλειες/συμφόρηση) — τα παράθυρα είναι αρκετά μεγάλα
  αλλά η ταχύτητα υστερεί. Ελέγξτε απώλειες (`mtr`) και καθυστέρηση υπό φόρτο (`ping` κατά τη
  διάρκεια λήψης — αυξανόμενο RTT σημαίνει bufferbloat). Λύσεις: παράλληλες συνδέσεις, ή BBR
  στον αποστολέα.
- **OK** — μια μεμονωμένη ροή τρέχει ήδη κοντά στον ρυθμό γραμμής.

Οι αριθμοί που τυπώνονται πάνω από το πόρισμα είναι τα στοιχεία· η γραμμή πορίσματος είναι μια
ευρετική σύνοψη, όχι ευαγγέλιο. Συγκεκριμένα, το "server in-flight: peak / p95" είναι το πολύ
που είχε ποτέ ο server μη αναγνωρισμένο (unacknowledged)· το κενό ανάμεσα σε αυτό και στο
"sustained in-flight" (ταχύτητα × RTT) είναι το ίδιο το σήμα απωλειών/ουρών (queueing).

## Πώς λειτουργεί

1. Εκκινεί μια λήψη μονής σύνδεσης και βρίσκει την **πραγματική** IP του peer από το ίδιο το
   socket του downloader (ώστε να ακολουθεί ανακατευθύνσεις σε κόμβο CDN αντί να μετρά τη λάθος
   σύνδεση).
2. Ξεκινά καταγραφή `tcpdump` **στοχευμένη σε αυτόν τον έναν peer** (φίλτρο BPF `host` — δεν
   γράφεται καμία άλλη κίνηση).
3. Δειγματοληπτεί το `ss -tiem` μία φορά το δευτερόλεπτο για RTT, window scale, `rcv_space`,
   και bytes που ελήφθησαν.
4. Διαβάζει peak/p95 bytes σε πτήση από την καταγραφή, και ανακατασκευάζει το διαφημιζόμενο
   παράθυρο λήψης ως `raw_window × 2^rcv_wscale` (το scale από το `ss`, ώστε να μη χρειάζεται να
   καταγραφεί το handshake).
5. Συγκρίνει τα πάντα με το BDP και τυπώνει το πόρισμα.

## Επιφυλάξεις

- Η καταγραφή είναι στοχευμένη στη μοναδική IP του peer (δεν "ακούει" άλλη κίνηση), αλλά
  προτιμήστε ένα μηχάνημα που σας ανήκει ούτως ή άλλως.
- Μια προσωρινή λήψη (~ `ταχύτητα × DURATION`) γράφεται στο `WORKDIR` και αφαιρείται κατά την
  έξοδο. Μειώστε το `DURATION` για να τη συρρικνώσετε.
- Ορισμένα πεδία του `ss` (`bytes_received`) εξαρτώνται από την έκδοση πυρήνα / iproute2· το
  script πέφτει πίσω στην καταγραφή για την ταχύτητα όταν αυτά απουσιάζουν.
- Το πόρισμα χρησιμοποιεί συντελεστές προσαρμογής (0.85 / 0.9) και προορίζεται ως γρήγορη
  διαλογή (triage), όχι ως πιστοποιημένη μέτρηση.

## Άδεια χρήσης

MIT — δείτε το [LICENSE](LICENSE). Αντικαταστήστε τη γραμμή του κατόχου πνευματικών δικαιωμάτων
πριν τη δημοσίευση.
