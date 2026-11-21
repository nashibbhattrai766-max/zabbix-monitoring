#!/bin/bash
# Adds "Availability 24h / 7d" calculated items (for the Services and Reliability screens)
# and quietens Wi-Fi radio error alerts on the AP. Run in the Zabbix container OR the monitoring container.
set -u
ZBX="http://10.0.0.30/api_jsonrpc.php"
read -s -p "Zabbix Admin password: " ZPW; echo
command -v jq >/dev/null || apt-get install -y -qq jq curl >/dev/null

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

# host | expression for "fraction of time OK" over a window W (W is substituted)
LIST=(
 "Immich|1-avg(//web.test.fail[Immich],W)"
 "Home Assistant|1-avg(//web.test.fail[Home Assistant],W)"
 "GymTracker|1-avg(//web.test.fail[GymTracker],W)"
 "Gym API|1-avg(//web.test.fail[Gym API],W)"
 "Grafana|1-avg(//web.test.fail[Grafana],W)"
 "Audiobookshelf|1-avg(//web.test.fail[Audiobookshelf],W)"
 "Pi-hole web|1-avg(//web.test.fail[Pi-hole web],W)"
 "Router|avg(//icmpping,W)"
 "Switch-01|avg(//icmpping,W)"
 "Switch-02|avg(//icmpping,W)"
 "AccessPoint|avg(//icmpping,W)"
 "Internet|avg(//icmpping,W)"
 "pve1|1-avg(//web.test.fail[Proxmox web UI pve1],W)"
 "pve2|1-avg(//web.test.fail[Proxmox web UI pve2],W)"
 "NAS|avg(//net.tcp.service[tcp,,445],W)"
 "Pi-hole DNS|avg(//net.dns[10.0.0.2,google.com,A,2,2],W)"
)
for e in "${LIST[@]}"; do
  H=${e%%|*}; F=${e#*|}
  HID=$(z host.get "$(jq -nc --arg h "$H" '{output:["hostid"],filter:{host:[$h]}}')" "$SID" | jq -r '.[0].hostid // empty')
  [ -z "$HID" ] && { echo "  ! host $H not found"; continue; }
  for W in 24h 7d; do
    K="availability.$W"
    EX=$(z item.get "$(jq -nc --arg h "$HID" --arg k "$K" '{output:["itemid"],hostids:$h,filter:{key_:[$k]}}')" "$SID" | jq -r '.[0].itemid // empty')
    [ -n "$EX" ] && continue
    z item.create "$(jq -nc --arg h "$HID" --arg k "$K" --arg n "Availability $W" --arg f "100*(${F//W/$W})" \
      '{hostid:$h,name:$n,key_:$k,type:15,value_type:0,units:"%",delay:"5m",params:$f,history:"31d",trends:"365d"}')" "$SID" >/dev/null \
      && echo "  + $H: Availability $W"
  done
done

# Quieten Wi-Fi radio "errors out" on the AP (normal retries), keep wired-port error alerts
AP=$(z host.get '{"output":["hostid"],"filter":{"host":["AccessPoint"]}}' "$SID" | jq -r '.[0].hostid // empty')
if [ -n "$AP" ]; then
  M='{$IF.ERRORS.WARN:regex:"^wifi"}'
  EX=$(z usermacro.get "$(jq -nc --arg h "$AP" --arg m "$M" '{output:["hostmacroid"],hostids:$h,filter:{macro:$m}}')" "$SID" | jq -r '.[0].hostmacroid // empty')
  [ -z "$EX" ] && z usermacro.create "$(jq -nc --arg h "$AP" --arg m "$M" '{hostid:$h,macro:$m,value:"1000"}')" "$SID" >/dev/null \
    && echo "  + AP: Wi-Fi radio error alerts quietened (wired ports unchanged)"
fi
z user.logout '[]' "$SID" >/dev/null
echo "Done. Availability values appear within ~5 minutes."
