# Real-Device Smoke Test (pre-release gate for 0.4.0)

Run before cutting any `v0.4.0-*` tag.

## Devices required
- 2× iPhone (release-Metronome-installed, testing-Metronome installed)
- 1× iPad on Logic Pro with DAWSync AUv3
- 1× macOS on same Wi-Fi

## Matrix

| # | Topology | Setup | Pass criteria |
|---|----------|-------|---------------|
| 1 | mesh ↔ v0.2.x | v0.4.0-mesh + v1.0-release Metronome | peers see each other; sync ±5ms |
| 2 | star auto | 2× v0.4.0-star | host elected in ≤3s; sync ±5ms |
| 3 | star with clientOnly | DAWSync (.clientOnly) + iPhone (.auto) | iPhone hosts; DAWSync receives |
| 4 | auto threshold | 2→5 devices join progressively | transition to star at 5th peer within settleWindow |
| 5 | sleep/resume | Lock host device, unlock after 30s | sync recovers within 10s |
| 6 | host kill | Force-quit host | new host elected in ≤5s, clients reconnect |
| 7 | split-brain | Block host Wi-Fi 20s then restore | higher-term host wins; no duplicate hosts |
| 8 | thermal/power | Drain battery on leading candidate | HostScore demotes; weaker device takes over |

## Packet capture (for failures)

```bash
sudo tcpdump -i en0 -w peerclock.pcap 'port 53317 or udp port 5353'
```

Open in Wireshark with `websocket` filter for star handshake inspection.

## Sign-off

All 8 rows green → tag eligible. Any red → fix before cutting.
