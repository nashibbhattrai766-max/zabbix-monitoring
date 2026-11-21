#!/bin/bash
# Connects Grafana to Zabbix with a read-only Zabbix user. Run INSIDE the monitoring container (502).
set -u
ZBX="http://10.0.0.30/api_jsonrpc.php"
GRAF="http://localhost:3000"
read -s -p "Zabbix Admin password: " ZPW; echo
read -s -p "Grafana admin password: " GPW; echo
apt-get install -y -qq curl jq >/dev/null 2>&1

z() {  # z <method> <params-json> [auth]
  local body r auth=()
  [ -n "${3:-}" ] && auth=(-H "Authorization: Bearer $3")
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  r=$(curl -s -X POST -H 'Content-Type: application/json-rpc' "${auth[@]}" --data "$body" "$ZBX")
  if [ -z "$r" ] || echo "$r" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ! Zabbix $1: $(echo "$r" | jq -c '.error.data // .error // .' 2>/dev/null)" >&2; return 1; fi
  echo "$r" | jq -c '.result'
}

echo "== Step 2: read-only Zabbix user for Grafana"
SID=$(z user.login "$(jq -nc --arg p "$ZPW" '{username:"Admin",password:$p}')" | jq -r '.') || { echo "Zabbix login failed - check the Admin password."; exit 1; }

HGS=$(z hostgroup.get '{"output":["groupid"]}' "$SID" | jq -c '[.[] | {id:.groupid, permission:2}]')
UG=$(z usergroup.get '{"output":["usrgrpid"],"filter":{"name":["Grafana readers"]}}' "$SID" | jq -r '.[0].usrgrpid // empty')
if [ -z "$UG" ]; then
  UG=$(z usergroup.create "$(jq -nc --argjson g "$HGS" '{name:"Grafana readers",hostgroup_rights:$g}')" "$SID" | jq -r '.usrgrpids[0]') && echo "  + user group 'Grafana readers' (read on all host groups)"
else
  z usergroup.update "$(jq -nc --arg u "$UG" --argjson g "$HGS" '{usrgrpid:$u,hostgroup_rights:$g}')" "$SID" >/dev/null && echo "  = user group exists (read rights refreshed)"
fi

UID_=$(z user.get '{"output":["userid"],"filter":{"username":["grafana"]}}' "$SID" | jq -r '.[0].userid // empty')
if [ -z "$UID_" ]; then
  UPW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
  UID_=$(z user.create "$(jq -nc --arg p "$UPW" --arg g "$UG" '{username:"grafana",passwd:$p,roleid:"1",usrgrps:[{usrgrpid:$g}]}')" "$SID" | jq -r '.userids[0]') \
    && echo "  + user 'grafana' (User role)" && echo "$UPW" > /root/zabbix-grafana-user-password && chmod 600 /root/zabbix-grafana-user-password
else echo "  = user 'grafana' exists"; fi

OLD=$(z token.get "$(jq -nc --arg u "$UID_" '{output:["tokenid"],userids:[$u],filter:{name:["grafana-datasource"]}}')" "$SID" | jq -c '[.[].tokenid]')
[ "$OLD" != "[]" ] && z token.delete "$OLD" "$SID" >/dev/null && echo "  ~ replaced old grafana-datasource token"
TID=$(z token.create "$(jq -nc --arg u "$UID_" '{name:"grafana-datasource",userid:$u}')" "$SID" | jq -r '.tokenids[0]')
TOKEN=$(z token.generate "$(jq -nc --arg t "$TID" '[$t]')" "$SID" | jq -r '.[0].token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && echo "  + API token created for 'grafana'" || { echo "Token creation failed."; exit 1; }
z user.logout '[]' "$SID" >/dev/null

echo "== Step 3: Grafana"
g() { curl -s -u "admin:$GPW" -H 'Content-Type: application/json' "$@"; }
g -X POST "$GRAF/api/plugins/alexanderzobnin-zabbix-app/settings" -d '{"enabled":true,"pinned":true}' >/dev/null && echo "  + Zabbix plugin enabled"

EX=$(g "$GRAF/api/datasources/name/Zabbix" | jq -r '.uid // empty')
DS=$(jq -nc --arg u "$ZBX" --arg t "$TOKEN" '{name:"Zabbix",type:"alexanderzobnin-zabbix-datasource",access:"proxy",url:$u,
      jsonData:{authType:"token",trends:true,trendsFrom:"7d",trendsRange:"4d",cacheTTL:"1m"},secureJsonData:{apiToken:$t}}')
if [ -n "$EX" ]; then
  R=$(g -X PUT "$GRAF/api/datasources/uid/$EX" -d "$DS"); DSUID=$EX; echo "  ~ data source 'Zabbix' updated"
else
  R=$(g -X POST "$GRAF/api/datasources" -d "$DS"); DSUID=$(echo "$R" | jq -r '.datasource.uid // empty')
  [ -n "$DSUID" ] && echo "  + data source 'Zabbix' added" || { echo "  ! Grafana said: $R"; exit 1; }
fi

sleep 2
H=$(g "$GRAF/api/datasources/uid/$DSUID/health")
echo "== Save & test result: $(echo "$H" | jq -r '.status // "?"') - $(echo "$H" | jq -r '.message // .')"
echo "== Data source UID: $DSUID"
