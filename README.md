# Zabbix Monitoring as Code

Zabbix 7.0 LTS monitoring for a homelab, built entirely through the **Zabbix JSON-RPC API** with idempotent scripts instead of clicking through the UI. Re-running a script only adds what's missing, so the whole setup can be rebuilt from scratch in minutes.

Problems are pushed to a phone through **[ntfy](https://ntfy.sh)**, with recovery messages ("✅ RESOLVED … was down 4m") and dependencies so a router outage doesn't also page for every device behind it.

## Scripts

| Script | What it builds |
|---|---|
| [`zabbix-hosts-and-alerts.sh`](scripts/zabbix-hosts-and-alerts.sh) | Host groups; ping checks for router/switches/AP/internet with **trigger dependencies**; web checks for every self-hosted app; DNS checks against Pi-hole; Proxmox node services and memory pressure; backup-age checks; optional Healthchecks.io heartbeat; **ntfy media type + action** |
| [`zabbix-snmp.sh`](scripts/zabbix-snmp.sh) | Switches UniFi devices that answer SNMP v2c to SNMP templates (interfaces, traffic, uptime); the rest stay on ping |
| [`zabbix-pbs.sh`](scripts/zabbix-pbs.sh) | Proxmox Backup Server host: one master item reads a metrics file, **dependent items with JavaScript preprocessing** split it into last-backup age, failed verifications, failed tasks, QDevice/DNS/container status — plus triggers. Also clones the DNS check for the second Pi-hole. |
| [`zabbix-availability.sh`](scripts/zabbix-availability.sh) | Calculated `availability.24h` / `availability.7d` items (`100*avg(//agent.ping,7d)`) for the reliability screens; quietens noisy Wi-Fi radio alerts |
| [`zabbix-noc-dashboard.py`](scripts/zabbix-noc-dashboard.py) | A 3-page "Homelab NOC" Zabbix dashboard (Now / Trends / Reliability) with honeycomb, gauges, top-hosts and graphs, as a slideshow |
| [`grafana-zabbix-connect.sh`](scripts/grafana-zabbix-connect.sh) | Creates a **read-only** Zabbix user + API token for Grafana and adds the Zabbix data source to Grafana |

All scripts prompt for credentials (`read -s`) — nothing is stored in the files.

## Usage

```bash
# inside the Zabbix server (or anywhere that can reach its API)
./scripts/zabbix-hosts-and-alerts.sh      # asks for API token + ntfy topic
./scripts/zabbix-snmp.sh                  # asks for API token + SNMP community
./scripts/zabbix-pbs.sh                   # asks for the Admin password
./scripts/zabbix-availability.sh
python3 scripts/zabbix-noc-dashboard.py
```

Edit the host lists near the top of each script (names and IPs) to match your network. The IPs in this repo are placeholders (`10.0.0.x`).

## Things worth knowing

- **Zabbix 7.0 API authentication**: send `Authorization: Bearer <token>` — the old `auth` field in the request body is deprecated.
- **Dashboard widget fields** are undocumented in places. A `tophosts` column needs `base_color`, `aggregate_function` and `history`, or the frontend throws `Undefined array key`. Column thresholds use `columnsthresholds.<col>.color.<n>`.
- **Find template items by name, not key.** Key names differ between template versions (e.g. memory utilisation).
- **An LXC reports the host's load average.** A container-based Zabbix server will alert "load too high" whenever the hypervisor is busy. Disable that trigger on the container and rely on the host's.
- **Don't close "restarted" problems by hand** while uptime is still under the threshold; they reopen. Acknowledge them instead.
- **Treat the ntfy topic like a password.** Anyone who knows it can read and send your alerts.

## License

MIT
