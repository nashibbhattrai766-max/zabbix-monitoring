#!/bin/bash
# Adds SNMP monitoring to the UniFi gear in Zabbix. Run INSIDE the Zabbix container.
# Only devices that actually answer SNMP are changed; the rest stay on ping.
set -u
URL="http://localhost/api_jsonrpc.php"
read -s -p "Zabbix API token: " TOKEN; echo
read -p "SNMP community you set in UniFi: " COMM

apt-get install -y -qq curl jq snmp >/dev/null

call() {
  local body r
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  r=$(curl -s -X POST -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $TOKEN" --data "$body" "$URL")
  if [ -z "$r" ] || echo "$r" | jq -e '.error' >/dev/null 2>&1; then
    echo "  ! $1 failed: $(echo "$r" | jq -c '.error.data // .error // .' 2>/dev/null)" >&2; return 1
  fi
  echo "$r" | jq -c '.result'
}
call host.get '{"output":["hostid"],"limit":1}' >/dev/null || { echo "Token rejected - stopping."; exit 1; }

T_SNMP=$(call template.get '{"output":["templateid"],"filter":{"host":["Network Generic Device by SNMP"]}}' | jq -r '.[0].templateid // empty')
T_ICMP=$(call template.get '{"output":["templateid"],"filter":{"host":["ICMP Ping"]}}' | jq -r '.[0].templateid // empty')
[ -z "$T_SNMP" ] && { echo "Template 'Network Generic Device by SNMP' not found - stopping."; exit 1; }
# Does the SNMP template already include ping items? If so it replaces 'ICMP Ping' (avoids duplicate keys).
HASPING=$(call item.get "$(jq -nc --arg t "$T_SNMP" '{output:["itemid"],templateids:$t,search:{key_:"icmpping"},countOutput:true}')" | jq -r '.')

for d in "Router|10.0.0.1" "Switch-01|10.0.0.3" "Switch-02|10.0.0.4" "AccessPoint|10.0.0.5"; do
  N=${d%%|*}; IP=${d##*|}
  echo "== $N ($IP)"
  SYS=$(snmpget -v2c -c "$COMM" -t 2 -r 1 -Oqv "$IP" 1.3.6.1.2.1.1.5.0 2>/dev/null)
  if [ -z "$SYS" ]; then echo "  - no SNMP answer, staying on ping only"; continue; fi
  echo "  SNMP OK (device name: $SYS)"

  H=$(call host.get "$(jq -nc --arg n "$N" '{output:["hostid"],filter:{host:[$n]},selectInterfaces:["type"],selectParentTemplates:["templateid"]}')")
  HID=$(echo "$H" | jq -r '.[0].hostid // empty'); [ -z "$HID" ] && { echo "  ! host not found in Zabbix"; continue; }

  # 1. SNMP interface
  if echo "$H" | jq -e '.[0].interfaces[] | select(.type=="2")' >/dev/null; then echo "  = SNMP interface exists"
  else call hostinterface.create "$(jq -nc --arg h "$HID" --arg ip "$IP" '{hostid:$h,type:2,main:1,useip:1,ip:$ip,dns:"",port:"161",details:{version:2,bulk:1,community:"{$SNMP_COMMUNITY}"}}')" >/dev/null && echo "  + SNMP interface"; fi

  # 2. community macro
  M=$(call usermacro.get "$(jq -nc --arg h "$HID" '{output:["hostmacroid"],hostids:$h,filter:{macro:"{$SNMP_COMMUNITY}"}}')" | jq -r '.[0].hostmacroid // empty')
  if [ -n "$M" ]; then call usermacro.update "$(jq -nc --arg m "$M" --arg v "$COMM" '{hostmacroid:$m,value:$v,type:1}')" >/dev/null && echo "  ~ community macro updated"
  else call usermacro.create "$(jq -nc --arg h "$HID" --arg v "$COMM" '{hostid:$h,macro:"{$SNMP_COMMUNITY}",value:$v,type:1}')" >/dev/null && echo "  + community macro (hidden)"; fi

  # 3. templates
  if echo "$H" | jq -e --arg t "$T_SNMP" '.[0].parentTemplates[] | select(.templateid==$t)' >/dev/null; then echo "  = SNMP template already linked"
  elif [ "$HASPING" -gt 0 ] 2>/dev/null; then
    call host.update "$(jq -nc --arg h "$HID" --arg s "$T_SNMP" --arg i "$T_ICMP" '{hostid:$h,templates:[{templateid:$s}],templates_clear:[{templateid:$i}]}')" >/dev/null && echo "  + linked SNMP template (includes ping)"
  else
    call host.update "$(jq -nc --arg h "$HID" --arg s "$T_SNMP" --arg i "$T_ICMP" '{hostid:$h,templates:[{templateid:$s},{templateid:$i}]}')" >/dev/null && echo "  + linked SNMP template (kept ICMP Ping)"
  fi
done
echo; echo "Done. Interfaces and ports appear within ~1 hour (discovery); availability shows 'SNMP' green within a few minutes."
