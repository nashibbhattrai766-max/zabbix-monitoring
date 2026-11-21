#!/bin/bash
# Adds PBS + second Pi-hole monitoring to Zabbix. Run on pve1 (needs curl + jq). Safe to re-run.
set -u
ZBX="http://10.0.0.30/api_jsonrpc.php"
command -v jq >/dev/null || apt-get install -y -qq jq curl >/dev/null
read -s -p "Zabbix Admin password: " ZPW; echo

z() {
  local body r auth=()
  [ -n "${3:-}" ] && auth=(-H "Authorization: Bearer $3")
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  r=$(curl -s -X POST -H 'Content-Type: application/json-rpc' "${auth[@]}" --data "$body" "$ZBX")
  if [ -z "$r" ] || echo "$r" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ! $1: $(echo "$r" | jq -c '.error.data // .error // .' 2>/dev/null)" >&2; return 1; fi
  echo "$r" | jq -c '.result'
}
SID=$(z user.login "$(jq -nc --arg p "$ZPW" '{username:"Admin",password:$p}')" | jq -r '.') || { echo "Login failed."; exit 1; }
first() { jq -r ".[0].$1 // empty"; }

# ---------- PBS host ----------
GID=$(z hostgroup.get '{"output":["groupid"],"filter":{"name":["Backup"]}}' "$SID" | first groupid)
[ -z "$GID" ] && GID=$(z hostgroup.create '{"name":"Backup"}' "$SID" | jq -r '.groupids[0]') && echo "+ group Backup"
TID=$(z template.get '{"output":["templateid"],"filter":{"host":["Linux by Zabbix agent active"]}}' "$SID" | first templateid)
HID=$(z host.get '{"output":["hostid"],"filter":{"host":["pbs"]}}' "$SID" | first hostid)
if [ -z "$HID" ]; then
  HID=$(z host.create "$(jq -nc --arg g "$GID" --arg t "$TID" '{host:"pbs",name:"PBS",groups:[{groupid:$g}],templates:[{templateid:$t}],
        interfaces:[{type:1,main:1,useip:1,ip:"10.0.0.20",dns:"",port:"10050"}]}')" "$SID" | jq -r '.hostids[0]') && echo "+ host PBS"
else echo "= host PBS exists"; fi

MKEY='vfs.file.contents[/var/lib/prometheus/node-exporter/pbs.prom]'
MID=$(z item.get "$(jq -nc --arg h "$HID" --arg k "$MKEY" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" "$SID" | first itemid)
[ -z "$MID" ] && MID=$(z item.create "$(jq -nc --arg h "$HID" --arg k "$MKEY" '{hostid:$h,name:"PBS status file",key_:$k,type:7,value_type:4,delay:"5m",history:"1d",trends:"0"}')" "$SID" | jq -r '.itemids[0]') && echo "+ item PBS status file"

# dependent items: name | key | units | JS body (value = file text)
GET='function g(re){var m=value.match(re);return m?parseFloat(m[1]):-1;}'
NOW='var now=Math.floor(Date.now()/1000);'
ITEMS=(
 "PBS status age|pbs.status.age|s|$GET $NOW var t=g(/^pbs_status_timestamp_seconds (\\S+)/m); return t<0?99999:now-t;"
 "Photos backup age|pbs.photos.age|s|$GET $NOW var t=g(/^pbs_group_last_backup_seconds\\{type=\"host\",id=\"photo-library\"\\} (\\S+)/m); return t<0?999999:now-t;"
 "Backups failed verification|pbs.verify.failed||$GET return g(/^pbs_verify_failed (\\S+)/m);"
 "Backups verified OK|pbs.verify.ok||$GET return g(/^pbs_verify_ok (\\S+)/m);"
 "PBS tasks failed in 24h|pbs.tasks.failed24h||$GET return g(/^pbs_tasks_failed_24h (\\S+)/m);"
 "QDevice (qnetd) running|pbs.qnetd||$GET return g(/^pbs_service_up\\{service=\"corosync-qnetd\"\\} (\\S+)/m);"
 "Unbound running|pbs.unbound||$GET return g(/^pbs_service_up\\{service=\"unbound\"\\} (\\S+)/m);"
 "Pi-hole 2 container running|pbs.pihole2||$GET return g(/^pbs_container_up\\{container=\"pihole2\"\\} (\\S+)/m);"
 "Pi-hole sync container running|pbs.nebula||$GET return g(/^pbs_container_up\\{container=\"nebula-sync\"\\} (\\S+)/m);"
 "Pi-hole last sync age|pbs.nebula.age|s|$GET $NOW var t=g(/^pbs_nebula_last_sync_seconds (\\S+)/m); return t<=0?999999:now-t;"
)
for e in "${ITEMS[@]}"; do
  IFS='|' read -r N K U JS <<< "$e"
  EX=$(z item.get "$(jq -nc --arg h "$HID" --arg k "$K" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" "$SID" | first itemid)
  P=$(jq -nc --arg h "$HID" --arg n "$N" --arg k "$K" --arg u "$U" --arg m "$MID" --arg js "$JS" \
      '{name:$n,key_:$k,type:18,master_itemid:$m,value_type:0,units:$u,history:"31d",trends:"365d",
        preprocessing:[{type:21,params:$js,error_handler:0,error_handler_params:""}]} + {hostid:$h}')
  if [ -z "$EX" ]; then z item.create "$P" "$SID" >/dev/null && echo "+ item $N"
  else z item.update "$(echo "$P" | jq -c --arg i "$EX" 'del(.hostid,.type,.master_itemid,.key_) + {itemid:$i}')" "$SID" >/dev/null && echo "~ item $N"; fi
done

# triggers: description | expression | priority (2 warn, 3 avg, 4 high)
TRIG=(
 "PBS: status collector not updating|last(/pbs/pbs.status.age)>1200|2"
 "PBS: photo library not backed up in 26 h|last(/pbs/pbs.photos.age)>93600|4"
 "PBS: a backup failed verification|last(/pbs/pbs.verify.failed)>0|4"
 "PBS: a task failed in the last 24 h|last(/pbs/pbs.tasks.failed24h)>0|2"
 "QDevice down - cluster has no tie-breaker vote|last(/pbs/pbs.qnetd)<>1|4"
 "Pi-hole 2: Unbound not running|last(/pbs/pbs.unbound)<>1|3"
 "Pi-hole 2: container not running|last(/pbs/pbs.pihole2)<>1|3"
 "Pi-hole sync: container not running|last(/pbs/pbs.nebula)<>1|2"
 "Pi-hole sync: no successful sync in 3 h|last(/pbs/pbs.nebula.age)>10800|2"
)
for t in "${TRIG[@]}"; do
  IFS='|' read -r D X P <<< "$t"
  EX=$(z trigger.get "$(jq -nc --arg h "$HID" --arg d "$D" '{output:["triggerid"],hostids:$h,filter:{description:[$d]}}')" "$SID" | first triggerid)
  [ -z "$EX" ] && z trigger.create "$(jq -nc --arg d "$D" --arg x "$X" --argjson p "$P" '{description:$d,expression:$x,priority:$p}')" "$SID" >/dev/null && echo "+ trigger $D"
done

# ---------- second Pi-hole DNS check (copied from the existing "Pi-hole DNS" host) ----------
SRC=$(z host.get '{"output":["hostid"],"filter":{"host":["Pi-hole DNS"]},"selectGroups":["groupid"],"selectInterfaces":["type","main","useip","ip","dns","port"]}' "$SID")
SITEM=$(z item.get "$(jq -nc --arg h "$(echo "$SRC" | first hostid)" '{output:["type","delay","value_type","name"],hostids:$h,search:{key_:"net.dns"}}')" "$SID")
H2=$(z host.get '{"output":["hostid"],"filter":{"host":["Pi-hole DNS 2"]}}' "$SID" | first hostid)
if [ -z "$H2" ]; then
  H2=$(z host.create "$(echo "$SRC" | jq -c '.[0] | {host:"Pi-hole DNS 2",name:"Pi-hole DNS 2",groups:.groups,interfaces:.interfaces}')" "$SID" | jq -r '.hostids[0]') && echo "+ host Pi-hole DNS 2"
fi
K2='net.dns[10.0.0.20,google.com,A,2,2]'
EX=$(z item.get "$(jq -nc --arg h "$H2" --arg k "$K2" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" "$SID" | first itemid)
if [ -z "$EX" ]; then
  IF2=$(z hostinterface.get "$(jq -nc --arg h "$H2" '{output:["interfaceid"],hostids:$h}')" "$SID" | first interfaceid)
  z item.create "$(echo "$SITEM" | jq -c --arg h "$H2" --arg k "$K2" --arg i "$IF2" '.[0] | {hostid:$h,key_:$k,name:.name,type:(.type|tonumber),delay:.delay,value_type:(.value_type|tonumber)}
        + (if $i != "" then {interfaceid:$i} else {} end)')" "$SID" >/dev/null && echo "+ item Pi-hole 2 DNS check"
fi
D2="Pi-hole 2 is not answering DNS"
EX=$(z trigger.get "$(jq -nc --arg h "$H2" --arg d "$D2" '{output:["triggerid"],hostids:$h,filter:{description:[$d]}}')" "$SID" | first triggerid)
[ -z "$EX" ] && z trigger.create "$(jq -nc --arg d "$D2" --arg x "max(/Pi-hole DNS 2/$K2,3m)=0" '{description:$d,expression:$x,priority:4}')" "$SID" >/dev/null && echo "+ trigger $D2"

# ---------- availability items (Reliability screen + NOC honeycomb) ----------
for pair in "PBS|pbs|100*avg(//agent.ping,W)" "Pi-hole DNS 2|Pi-hole DNS 2|100*avg(//$K2,W)"; do
  IFS='|' read -r LBL H F <<< "$pair"
  HX=$(z host.get "$(jq -nc --arg h "$H" '{output:["hostid"],filter:{host:[$h]}}')" "$SID" | first hostid)
  for W in 24h 7d; do
    K="availability.$W"
    EX=$(z item.get "$(jq -nc --arg h "$HX" --arg k "$K" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" "$SID" | first itemid)
    [ -z "$EX" ] && z item.create "$(jq -nc --arg h "$HX" --arg k "$K" --arg n "Availability $W" --arg f "${F//W/$W}" \
      '{hostid:$h,name:$n,key_:$k,type:15,value_type:0,units:"%",delay:"5m",params:$f,history:"31d",trends:"365d"}')" "$SID" >/dev/null && echo "+ $LBL: Availability $W"
  done
done

z user.logout '[]' "$SID" >/dev/null
echo "Done. PBS data appears within ~5 minutes (Monitoring > Latest data > host PBS)."
