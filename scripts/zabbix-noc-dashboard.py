#!/usr/bin/env python3
"""Builds the Zabbix "Homelab NOC" dashboard (3 pages, slideshow) through the API.
Run anywhere that can reach Zabbix:  python3 zabbix-noc-dashboard.py
Re-running replaces the dashboard with a fresh copy."""
import json, sys, getpass, urllib.request

ZBX = "http://10.0.0.30/api_jsonrpc.php"
NAME = "Homelab NOC"
GREEN, AMBER, RED, BLUE, ORANGE = "2BB673", "F5A623", "E5484D", "2AB5FF", "FF8A3D"
TILE_BG = "1F2733"

def call(method, params, auth=None):
    req = urllib.request.Request(ZBX, json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode(),
                                 {"Content-Type": "application/json-rpc", **({"Authorization": "Bearer " + auth} if auth else {})})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error'].get('data') or r['error']}")
    return r["result"]

pw = getpass.getpass("Zabbix Admin password: ")
try:
    T = call("user.login", {"username": "Admin", "password": pw})
except Exception as e:
    sys.exit(f"Login failed: {e}")
api = lambda m, p: call(m, p, T)
missing = []

def hostid(name):
    r = api("host.get", {"output": ["hostid"], "filter": {"host": [name]}})
    if not r: missing.append(f"host {name}")
    return r[0]["hostid"] if r else None

def groupid(name):
    r = api("hostgroup.get", {"output": ["groupid"], "filter": {"name": [name]}})
    if not r: missing.append(f"group {name}")
    return r[0]["groupid"] if r else None

def item(host, key=None, name=None):
    p = {"output": ["itemid", "name"], "filter": {"state": 0}}
    if host: p["host"] = host
    if key: p["filter"]["key_"] = key
    if name: p["search"] = {"name": name}
    r = api("item.get", p)
    if not r: missing.append(f"item {key or name} on {host or 'any host'}")
    return r[0]["itemid"] if r else None

# ---------- field helpers ----------
I = lambda n, v: {"type": 0, "name": n, "value": int(v)}
S = lambda n, v: {"type": 1, "name": n, "value": str(v)}
G = lambda n, v: {"type": 2, "name": n, "value": v}
H = lambda n, v: {"type": 3, "name": n, "value": v}
IT = lambda n, v: {"type": 4, "name": n, "value": v}
def thresholds(pairs, prefix="thresholds"):
    out = []
    for k, (t, c) in enumerate(pairs):
        out += [S(f"{prefix}.{k}.color", c), S(f"{prefix}.{k}.threshold", t)]
    return out
def period(frm): return [S("time_period.from", frm), S("time_period.to", "now")]
def W(type_, name, x, y, w, h, fields, header=True):
    return {"type": type_, "name": name, "x": x, "y": y, "width": w, "height": h,
            "view_mode": 0 if header else 1, "fields": [f for f in fields if f is not None]}

UP_IS_GOOD = [(0, RED), (99, AMBER), (99.9, GREEN)]
LOW_IS_GOOD = lambda warn, bad: [(0, GREEN), (warn, AMBER), (bad, RED)]

# ---------- widgets ----------
def clock(name, tz, x, y, w, h):
    return W("clock", name, x, y, w, h, [
        I("clock_type", 1), I("show.0", 1), I("show.1", 2), I("show.2", 3),
        I("time_format", 1), I("time_sec", 0), I("time_bold", 1), I("tzone_format", 1),
        S("tzone_timezone", tz), S("bg_color", TILE_BG), S("date_color", "9AA5B1"), S("tzone_color", "9AA5B1")
    ], header=False)

def gauge(name, itemid, x, y, w, h, desc):
    if not itemid: return None
    return W("gauge", name, x, y, w, h, [
        IT("itemid.0", itemid), I("angle", 270), S("description", desc), I("desc_size", 12), I("desc_bold", 1),
        I("decimal_places", 0), I("value_bold", 1), I("value_size", 28), I("value_arc_size", 18),
        I("th_show_arc", 1), I("th_arc_size", 6), I("scale_size", 10), S("empty_color", "2C3440"),
        *thresholds([(0, GREEN), (75, AMBER), (90, RED)])
    ], header=False)

def tile(name, itemid, x, y, w, h, th, decimals=1, units=None):
    if not itemid: return None
    return W("item", name, x, y, w, h, [
        IT("itemid.0", itemid), I("show.0", 1), I("show.1", 2), S("description", name),
        I("desc_size", 16), I("desc_bold", 1), I("desc_v_pos", 0), I("value_size", 42),
        I("decimal_places", decimals), S("bg_color", TILE_BG),
        S("units", units) if units else None, *thresholds(th)
    ], header=False)

def graph(name, x, y, w, h, sets, frm="now-24h", ymax=None, right_units=None):
    f = [*period(frm), S("lefty_min", 0)]
    if ymax is not None: f.append(S("lefty_max", ymax))
    for k, s in enumerate(sets):
        f += [S(f"ds.{k}.hosts.0", s["host"]), S(f"ds.{k}.items.0", s["item"]), S(f"ds.{k}.color", s["color"]),
              I(f"ds.{k}.width", s.get("width", 2)), I(f"ds.{k}.fill", s.get("fill", 2)),
              I(f"ds.{k}.transparency", s.get("transp", 4)), I(f"ds.{k}.type", s.get("type", 0)),
              I(f"ds.{k}.axisy", s.get("axis", 0)), I(f"ds.{k}.missingdatafunc", 1)]
        if s.get("label"): f.append(S(f"ds.{k}.data_set_label", s["label"]))
    if right_units: f += [I("righty_units", 1), S("righty_static_units", right_units), S("righty_min", 0), S("righty_max", 100)]
    else: f.append(I("righty", 0))
    return W("svggraph", name, x, y, w, h, f)

# ---------- look everything up ----------
lab = groupid("Lab services")
cpu_m, cpu_m1 = item("pve1", "system.cpu.util"), item("pve2", "system.cpu.util")
mem_m, mem_m1 = item("pve1", name="Memory utilization"), item("pve2", name="Memory utilization")
lat, loss = item("Internet", "icmppingsec"), item("Internet", "icmppingloss")
quorum = item(None, name="Quorate")
stale = item("pve1", "pve.backups.stale.count")
nas_av, dns_av = item("NAS", "availability.24h"), item("Pi-hole DNS", "availability.24h")

# ---------- page 1: NOW ----------
p1 = [
    clock("", "Etc/UTC", 0, 0, 12, 2),
    clock("Kathmandu", "Asia/Kathmandu", 12, 0, 12, 2),
    W("problemsbysv", "Problems by severity", 24, 0, 48, 2, [I("show_type", 1), I("layout", 0)], header=False),

    W("honeycomb", "Everything — availability, last 24 h", 0, 2, 36, 5, [
        S("items.0", "Availability 24h"), I("primary_label_bold", 1),
        I("secondary_label_decimal_places", 1), I("interpolation", 0), *thresholds(UP_IS_GOOD)]),
    gauge("pve1 CPU", cpu_m, 36, 2, 9, 5, "pve1 · CPU"),
    gauge("pve1 memory", mem_m, 45, 2, 9, 5, "pve1 · RAM"),
    gauge("pve2 CPU", cpu_m1, 54, 2, 9, 5, "pve2 · CPU"),
    gauge("pve2 memory", mem_m1, 63, 2, 9, 5, "pve2 · RAM"),

    tile("Internet latency", lat, 0, 7, 12, 2, LOW_IS_GOOD(0.05, 0.15), decimals=0),
    tile("Packet loss", loss, 12, 7, 12, 2, LOW_IS_GOOD(1, 10), decimals=0),
    tile("Cluster quorum", quorum, 24, 7, 12, 2, [(0, RED), (1, GREEN)], decimals=0),
    tile("Stale backups", stale, 36, 7, 12, 2, [(0, GREEN), (1, RED)], decimals=0),
    tile("NAS up (24 h)", nas_av, 48, 7, 12, 2, UP_IS_GOOD, decimals=1),
    tile("DNS up (24 h)", dns_av, 60, 7, 12, 2, UP_IS_GOOD, decimals=1),

    W("problems", "Open problems", 0, 9, 48, 5, [I("show", 3), I("show_lines", 15), I("show_timeline", 1)]),
    W("hostavail", "Host availability", 48, 9, 24, 2, [I("only_totals", 1)]),
    W("web", "Web checks", 48, 11, 24, 3, [G("groupids.0", lab)] if lab else []),
]

# ---------- page 2: TRENDS ----------
p2 = [
    graph("CPU utilization (24 h)", 0, 0, 36, 5, [
        {"host": "pve1", "item": "CPU utilization", "color": BLUE},
        {"host": "pve2", "item": "CPU utilization", "color": ORANGE}], ymax=100),
    graph("Memory utilization (24 h)", 36, 0, 36, 5, [
        {"host": "pve1", "item": "Memory utilization", "color": BLUE},
        {"host": "pve2", "item": "Memory utilization", "color": ORANGE},
        {"host": "NAS", "item": "Memory utilization", "color": "A78BFA"}], ymax=100),
    graph("Internet — latency & loss (24 h)", 0, 5, 36, 5, [
        {"host": "Internet", "item": "ICMP response time", "color": "45CFDB", "label": "Latency"},
        {"host": "Internet", "item": "ICMP loss", "color": RED, "type": 3, "axis": 1, "fill": 8, "transp": 6, "label": "Loss"}],
        right_units="%"),
    graph("Service response times (24 h)", 36, 5, 36, 5, [
        {"host": "*", "item": "Response time for step*", "color": "22C55E", "fill": 0, "width": 2}]),
    W("tophosts", "Servers", 0, 10, 72, 4, [
        *[G(f"groupids.{k}", g) for k, g in enumerate(x for x in [groupid("proxmox nodes"), groupid("NAS")] if x)],
        S("columns.0.name", "Server"), I("columns.0.data", 2), S("columns.0.base_color", ""),
        *[f for k, (label, it, bar) in enumerate([
            ("CPU %", "CPU utilization", True), ("Memory %", "Memory utilization", True),
            ("Root disk %", "FS [/]: Space: Used, in %", True), ("Load (1 m)", "Load average (1m avg)", False),
            ("Uptime", "System uptime", False)], start=1)
          for f in ([S(f"columns.{k}.name", label), I(f"columns.{k}.data", 1), S(f"columns.{k}.item", it), S(f"columns.{k}.base_color", ""),
                     I(f"columns.{k}.aggregate_function", 0), I(f"columns.{k}.history", 1),
                     I(f"columns.{k}.decimal_places", 1 if bar else 2)]
                    + ([I(f"columns.{k}.display", 2), S(f"columns.{k}.min", 0), S(f"columns.{k}.max", 100)]
                       + thresholds([(0, GREEN), (75, AMBER), (90, RED)], prefix=f"columnsthresholds.{k}") if bar else []))],
        I("column", 1), I("show_lines", 10)]),
]
# column thresholds use the format  columnsthresholds.<col>.color.<n>
for w in p2:
    if w["type"] == "tophosts":
        fixed = []
        for f in w["fields"]:
            if f["name"].startswith("columnsthresholds."):
                _, col, n, attr = f["name"].split(".")
                f = {**f, "name": f"columnsthresholds.{col}.{attr}.{n}"}
            fixed.append(f)
        w["fields"] = fixed

# ---------- page 3: RELIABILITY ----------
p3 = [
    W("honeycomb", "Availability, last 7 days", 0, 0, 44, 6, [
        S("items.0", "Availability 7d"), I("primary_label_bold", 1),
        I("secondary_label_decimal_places", 2), *thresholds(UP_IS_GOOD)]),
    W("toptriggers", "Noisiest alerts (7 days)", 44, 0, 28, 6, [*period("now-7d"), I("show_lines", 10)]),
    W("actionlog", "Alerts sent to your phone (7 days)", 0, 6, 72, 8, [*period("now-7d"), I("show_lines", 25)]),
]

dash = {"name": NAME, "display_period": 30, "auto_start": 1, "pages": [
    {"name": "Now", "widgets": [w for w in p1 if w]},
    {"name": "Trends", "widgets": [w for w in p2 if w]},
    {"name": "Reliability", "widgets": [w for w in p3 if w]}]}

old = api("dashboard.get", {"output": ["dashboardid"], "filter": {"name": [NAME]}})
if old:
    api("dashboard.delete", [d["dashboardid"] for d in old]); print(f"Replaced the old '{NAME}'.")
did = api("dashboard.create", dash)["dashboardids"][0]
print(f"Created '{NAME}': http://10.0.0.30/zabbix.php?action=dashboard.view&dashboardid={did}")
if missing: print("Skipped (not found):", ", ".join(missing))

if input("Switch your Zabbix login to the dark theme? [y/N] ").strip().lower() == "y":
    uid = api("user.get", {"output": ["userid"], "filter": {"username": "Admin"}})[0]["userid"]
    api("user.update", {"userid": uid, "theme": "dark-theme"}); print("Dark theme on.")
call("user.logout", [], T)
