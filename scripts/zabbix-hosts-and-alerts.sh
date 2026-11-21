#!/bin/bash
# Builds the core homelab monitoring through the Zabbix API: host groups, ping/web/DNS checks, Proxmox and backup checks, and ntfy push alerts.
# Run INSIDE the Zabbix container (10.0.0.30) as root. Safe to re-run: it skips anything that already exists.
set -u
URL="http://localhost/api_jsonrpc.php"
read -s -p "Zabbix API token: " TOKEN; echo
read -p "ntfy topic (same as the phone app): " NTFY
read -p "Healthchecks.io ping URL for 'Collector' (Enter to skip): " HC

apt-get install -y -qq curl jq fping libcap2-bin >/dev/null
FP=$(command -v fping)
sed -i "s|^#\? *FpingLocation=.*|FpingLocation=$FP|" /etc/zabbix/zabbix_server.conf
grep -q "^FpingLocation=" /etc/zabbix/zabbix_server.conf || echo "FpingLocation=$FP" >> /etc/zabbix/zabbix_server.conf
su -s /bin/sh zabbix -c "$FP -c1 -q 10.0.0.1" 2>/dev/null || setcap cap_net_raw+ep "$FP" 2>/dev/null
su -s /bin/sh zabbix -c "$FP -c1 -q 10.0.0.1" && echo "ping from Zabbix: OK" || echo "WARNING: ping from Zabbix not working (ICMP checks will show errors)"
systemctl restart zabbix-server

ERR=0
call() {  # call <method> <json-params>  -> prints .result (compact)
  local body r
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  r=$(curl -s -X POST -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $TOKEN" --data "$body" "$URL")
  if [ -z "$r" ] || echo "$r" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ! $1 failed: $(echo "$r" | jq -c '.error.data // .error // .' 2>/dev/null)" >&2; ERR=$((ERR+1)); return 1
  fi
  echo "$r" | jq -c '.result'
}
call apiinfo.version '[]' >/dev/null || true
call host.get '{"output":["hostid"],"limit":1}' >/dev/null || { echo "Token rejected - stopping."; exit 1; }

gid() {  # host group id (create if missing)
  local id; id=$(call hostgroup.get "$(jq -nc --arg n "$1" '{output:["groupid"],filter:{name:[$n]}}')" | jq -r '.[0].groupid // empty')
  [ -z "$id" ] && id=$(call hostgroup.create "$(jq -nc --arg n "$1" '{name:$n}')" | jq -r '.groupids[0]')
  echo "$id"
}
tid() { call template.get "$(jq -nc --arg n "$1" '{output:["templateid"],filter:{host:[$n]}}')" | jq -r '.[0].templateid // empty'; }
hid() { call host.get "$(jq -nc --arg n "$1" '{output:["hostid"],filter:{host:[$n]}}')" | jq -r '.[0].hostid // empty'; }
iid() { call item.get "$(jq -nc --arg h "$1" --arg k "$2" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" | jq -r '.[0].itemid // empty'; }

newhost() {  # newhost <name> <groupid> <ip or ""> <templateid or ""> [macros-json] -> prints hostid
  local id; id=$(hid "$1")
  if [ -n "$id" ]; then echo "  = host $1 exists" >&2; echo "$id"; return; fi
  local p; p=$(jq -nc --arg n "$1" --arg g "$2" --arg ip "$3" --arg t "$4" --argjson m "${5:-[]}" '
    {host:$n, groups:[{groupid:$g}], macros:$m}
    + (if $ip!="" then {interfaces:[{type:1,main:1,useip:1,ip:$ip,dns:"",port:"10050"}]} else {} end)
    + (if $t!="" then {templates:[{templateid:$t}]} else {} end)')
  id=$(call host.create "$p" | jq -r '.hostids[0]') && echo "  + host $1" >&2
  echo "$id"
}

trig() {  # trig <description> <expression> <priority> [opdata]
  local ex; ex=$(call trigger.get "$(jq -nc --arg d "$1" '{output:["triggerid"],filter:{description:[$d]}}')" | jq -r '.[0].triggerid // empty')
  [ -n "$ex" ] && { echo "  = trigger exists: $1"; return; }
  call trigger.create "$(jq -nc --arg d "$1" --arg e "$2" --arg p "$3" --arg o "${4:-}" '{description:$d,expression:$e,priority:$p,opdata:$o}')" >/dev/null && echo "  + trigger: $1"
}
item() {  # item <hostid> <json-fields>  (skips if key exists)
  local key; key=$(echo "$2" | jq -r '.key_')
  local ex; ex=$(iid "$1" "$key"); [ -n "$ex" ] && { echo "$ex"; return; }
  call item.create "$(echo "$2" | jq -c --arg h "$1" '. + {hostid:$h}')" | jq -r '.itemids[0]'
}
web() {  # web <hostid> <hostname> <scenario> <url> <required-string or ""> [verify 0/1]
  local ex; ex=$(call httptest.get "$(jq -nc --arg h "$1" --arg n "$3" '{output:["httptestid"],hostids:$h,filter:{name:[$n]}}')" | jq -r '.[0].httptestid // empty')
  if [ -z "$ex" ]; then
    call httptest.create "$(jq -nc --arg h "$1" --arg n "$3" --arg u "$4" --arg r "$5" --arg v "${6:-0}" '
      {hostid:$h,name:$n,delay:"1m",retries:"2",verify_peer:$v,verify_host:$v,
       steps:[{no:"1",name:$n,url:$u,status_codes:"200",required:$r,follow_redirects:"1",timeout:"15s"}]}')" >/dev/null && echo "  + web check $3" >&2
  fi
  trig "$3 is down" "count(/$2/web.test.fail[$3],#2,\"gt\",0)=2" 4 "{ITEM.LASTVALUE1}"
}

echo "== Host groups"
G_NET=$(gid "Network"); G_APP=$(gid "Lab services"); G_NAS=$(gid "NAS"); G_PVE=$(gid "Proxmox nodes")
T_ICMP=$(tid "ICMP Ping"); T_PROM=$(tid "Linux by Prom")
[ -z "$T_ICMP" ] && echo "  ! template 'ICMP Ping' not found"
[ -z "$T_PROM" ] && echo "  ! template 'Linux by Prom' not found"

echo "== Network (ping)"
for d in "Router|10.0.0.1" "Switch-01|10.0.0.3" "Switch-02|10.0.0.4" "AccessPoint|10.0.0.5" "Internet|1.1.1.1"; do
  newhost "${d%%|*}" "$G_NET" "${d##*|}" "$T_ICMP" >/dev/null
done
# dependencies: if the router is down, don't also alert for switches/AP/internet
RT=$(call trigger.get '{"output":["triggerid"],"host":"Router","search":{"description":"Unavailable by ICMP ping"}}' | jq -r '.[0].triggerid // empty')
for h in "Switch-01" "Switch-02" "AccessPoint" "Internet"; do
  T=$(call trigger.get "$(jq -nc --arg h "$h" '{output:["triggerid"],host:$h,search:{description:"Unavailable by ICMP ping"}}')" | jq -r '.[0].triggerid // empty')
  [ -n "$RT" ] && [ -n "$T" ] && call trigger.adddependencies "$(jq -nc --arg t "$T" --arg r "$RT" '[{triggerid:$t,dependsOnTriggerid:$r}]')" >/dev/null 2>&1 && echo "  ~ $h depends on Router"
done

echo "== NAS"
NAS=$(newhost "NAS" "$G_NAS" "10.0.0.50" "$T_PROM" '[{"macro":"{$NODE_EXPORTER_PORT}","value":"9100"}]')
I=$(item "$NAS" "$(jq -nc --arg i "$(call hostinterface.get "$(jq -nc --arg h "$NAS" '{output:["interfaceid"],hostids:$h}')" | jq -r '.[0].interfaceid')" \
   '{name:"SMB share (445) reachable",key_:"net.tcp.service[tcp,,445]",type:3,value_type:3,delay:"1m",interfaceid:$i}')")
trig "NAS file share (SMB 445) unreachable" "max(/NAS/net.tcp.service[tcp,,445],#3)=0" 4

echo "== Apps (web checks)"
for a in "Immich|http://10.0.0.50:2283/api/server/ping|pong" \
         "Home Assistant|http://10.0.0.40:8123|" \
         "GymTracker|http://10.0.0.60:8000/dashboard|" \
         "Gym API|http://10.0.0.60:8000/analytics/streak|" \
         "Grafana|http://10.0.0.31:3000/api/health|ok" \
         "Audiobookshelf|http://10.0.0.41:13378|" \
         "Pi-hole web|http://10.0.0.2/admin/|"; do
  IFS='|' read -r n u r <<<"$a"
  H=$(newhost "$n" "$G_APP" "" "")
  web "$H" "$n" "$n" "$u" "$r" 0
done

echo "== Pi-hole DNS (asked from the Zabbix box)"
PH=$(newhost "Pi-hole DNS" "$G_APP" "127.0.0.1" ""); PI=$(call hostinterface.get "$(jq -nc --arg h "$PH" '{output:["interfaceid"],hostids:$h}')" | jq -r '.[0].interfaceid')
item "$PH" "$(jq -nc --arg i "$PI" '{name:"Pi-hole answers DNS (google.com)",key_:"net.dns[10.0.0.2,google.com,A,2,2]",type:0,value_type:3,delay:"1m",interfaceid:$i}')" >/dev/null
trig "Pi-hole is not answering DNS" "max(/Pi-hole DNS/net.dns[10.0.0.2,google.com,A,2,2],#3)=0" 5

echo "== Proxmox nodes: services, memory pressure, web UI"
JS_PSI='var m = value.match(/full avg10=\S+ avg60=(\S+)/); return m ? m[1] : 0;'
for n in pve1 pve2; do
  H=$(hid "$n"); [ -z "$H" ] && { echo "  ! host $n not found"; continue; }
  M=$(item "$H" '{"name":"PSI memory raw","key_":"vfs.file.contents[/proc/pressure/memory]","type":7,"value_type":4,"delay":"1m","history":"1h"}')
  item "$H" "$(jq -nc --arg m "$M" --arg js "$JS_PSI" '{name:"Memory stalled (full, 60s avg)",key_:"psi.memory.full60",type:18,master_itemid:$m,value_type:0,units:"%",preprocessing:[{type:"21",params:$js,error_handler:"0",error_handler_params:""}]}')" >/dev/null
  trig "$n: memory stalling (risk of OOM kills)" "min(/$n/psi.memory.full60,3m)>5" 3 "{ITEM.LASTVALUE1}"
  SVCS="corosync pve-cluster pveproxy pvestatd"; [ "$n" = pve2 ] && SVCS="$SVCS nfs-server"
  for s in $SVCS; do
    item "$H" "$(jq -nc --arg s "$s" '{name:("Service "+$s),key_:("systemd.unit.info["+$s+".service]"),type:7,value_type:1,delay:"1m"}')" >/dev/null
    trig "$n: service $s not running" "count(/$n/systemd.unit.info[$s.service],#2,\"ne\",\"active\")=2" 4 "{ITEM.LASTVALUE1}"
  done
  IP=$([ "$n" = pve1 ] && echo 10.0.0.11 || echo 10.0.0.12)
  web "$H" "$n" "Proxmox web UI $n" "https://$IP:8006" "" 0
done
H1=$(hid pve2)
item "$H1" '{"name":"Backup drive mounted","key_":"vfs.file.exists[/mnt/backup-ssd/Proxmox,dir]","type":7,"value_type":3,"delay":"1m"}' >/dev/null
trig "pve2: backup drive not mounted" "max(/pve2/vfs.file.exists[/mnt/backup-ssd/Proxmox,dir],#2)=0" 4

echo "== Backups (from pve_backups.prom on pve1)"
H0=$(hid pve1)
BM=$(item "$H0" '{"name":"Backup status raw","key_":"vfs.file.contents[/var/lib/prometheus/node-exporter/pve_backups.prom]","type":7,"value_type":4,"delay":"10m","history":"1d"}')
JS_C='var now=Date.now()/1000,b=[];value.split("\n").forEach(function(l){var m=l.match(/guest="([^"]*)".*\}\s+(\S+)$/);if(m&&now-parseFloat(m[2])>93600)b.push(m[1]);});return b.length;'
JS_N='var now=Date.now()/1000,b=[];value.split("\n").forEach(function(l){var m=l.match(/guest="([^"]*)".*\}\s+(\S+)$/);if(m&&now-parseFloat(m[2])>93600)b.push(m[1]);});return b.length?b.join(", "):"none";'
item "$H0" "$(jq -nc --arg m "$BM" --arg js "$JS_C" '{name:"Guests without backup in 26h",key_:"pve.backups.stale.count",type:18,master_itemid:$m,value_type:3,preprocessing:[{type:"21",params:$js,error_handler:"0",error_handler_params:""}]}')" >/dev/null
item "$H0" "$(jq -nc --arg m "$BM" --arg js "$JS_N" '{name:"Guests without backup in 26h (names)",key_:"pve.backups.stale.names",type:18,master_itemid:$m,value_type:4,preprocessing:[{type:"21",params:$js,error_handler:"0",error_handler_params:""}]}')" >/dev/null
trig "Backups: guests without a backup in 26h" "last(/pve1/pve.backups.stale.count)>0 and length(last(/pve1/pve.backups.stale.names))>0" 4 "{ITEM.LASTVALUE2}"
trig "Backups: backup status data stale" "nodata(/pve1/vfs.file.contents[/var/lib/prometheus/node-exporter/pve_backups.prom],2h)=1" 2

if [ -n "$HC" ]; then
  echo "== Collector heartbeat -> Healthchecks.io"
  ZS=$(hid "Zabbix server")
  item "$ZS" "$(jq -nc --arg u "$HC" '{name:"Heartbeat to Healthchecks.io",key_:"healthchecks.ping",type:19,url:$u,value_type:4,delay:"1m",history:"1h",timeout:"10s"}')" >/dev/null && echo "  ok heartbeat"
fi

echo "== Alerts to ntfy"
MT=$(call mediatype.get '{"output":["mediatypeid"],"filter":{"name":["ntfy"]}}' | jq -r '.[0].mediatypeid // empty')
if [ -z "$MT" ]; then
  SCRIPT='var p = JSON.parse(value);
var prio = {"0":"2","1":"2","2":"3","3":"4","4":"4","5":"5"}[p.severity] || "3";
var tags = "warning";
if (p.recovery === "0") { prio = "2"; tags = "white_check_mark"; }
var req = new HttpRequest();
req.addHeader("Title: " + p.subject);
req.addHeader("Priority: " + prio);
req.addHeader("Tags: " + tags);
req.post(p.url, p.message);
if (req.getStatus() != 200) { throw "ntfy returned HTTP " + req.getStatus(); }
return "OK";'
  MT=$(call mediatype.create "$(jq -nc --arg s "$SCRIPT" '{name:"ntfy",type:4,script:$s,timeout:"30s",
    parameters:[{name:"url",value:"{ALERT.SENDTO}"},{name:"subject",value:"{ALERT.SUBJECT}"},{name:"message",value:"{ALERT.MESSAGE}"},
                {name:"severity",value:"{EVENT.NSEVERITY}"},{name:"recovery",value:"{EVENT.VALUE}"}],
    message_templates:[
      {eventsource:0,recovery:0,subject:"{EVENT.SEVERITY}: {EVENT.NAME}",message:"{HOST.NAME}\n{EVENT.OPDATA}\nSince {EVENT.TIME} {EVENT.DATE}"},
      {eventsource:0,recovery:1,subject:"RESOLVED: {EVENT.NAME}",message:"{HOST.NAME}\nWas down {EVENT.DURATION}"}]}')" | jq -r '.mediatypeids[0]') && echo "  + media type ntfy"
fi
call user.update "$(jq -nc --arg m "$MT" --arg t "https://ntfy.sh/$NTFY" '{userid:"1",medias:[{mediatypeid:$m,sendto:$t,active:0,severity:60,period:"1-7,00:00-24:00"}]}')" >/dev/null && echo "  + Admin gets alerts at ntfy.sh/$NTFY (Warning and above)"
AC=$(call action.get '{"output":["actionid"],"filter":{"name":["Send to ntfy"]}}' | jq -r '.[0].actionid // empty')
[ -z "$AC" ] && call action.create "$(jq -nc --arg m "$MT" '{name:"Send to ntfy",eventsource:0,status:0,esc_period:"1h",
  filter:{evaltype:0,conditions:[{conditiontype:4,operator:5,value:"2"}]},
  operations:[{operationtype:0,opmessage:{default_msg:1,mediatypeid:$m},opmessage_usr:[{userid:"1"}]}],
  recovery_operations:[{operationtype:11,opmessage:{default_msg:1}}]}')" >/dev/null && echo "  + action: Send to ntfy"

echo
[ "$ERR" -eq 0 ] && echo "DONE - no errors." || echo "DONE with $ERR error(s) - paste the lines starting with '!'."
