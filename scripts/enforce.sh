#!/bin/bash
# ByteRoot - expiry & quota enforcement (runs via cron every 5 min)
DB=/etc/byteroot/db
SSH_DB="$DB/ssh.db"
XRAY_CONFIG=/usr/local/etc/xray/config.json
TODAY=$(date +%Y-%m-%d)
NEED_RESTART=0

# ---- SSH accounts ----
if [ -s "$SSH_DB" ]; then
  tmp=$(mktemp)
  while IFS='|' read -r user type maxconn quota expiry created status; do
    [ -z "$user" ] && continue
    if [ "$status" == "locked" ]; then
      echo "$user|$type|$maxconn|$quota|$expiry|$created|locked" >> "$tmp"
      continue
    fi
    expired=0
    if [ "$expiry" != "-" ] && [ "$expiry" \< "$TODAY" ]; then expired=1; fi
    overquota=0
    if [ "$quota" != "0" ] && [ -n "$quota" ]; then
      bytes=$(iptables -L "br_$user" -v -x -n 2>/dev/null | awk '/RETURN/{print $2; exit}')
      [ -z "$bytes" ] && bytes=0
      limitbytes=$(( quota * 1073741824 ))
      [ "$bytes" -ge "$limitbytes" ] && overquota=1
    fi
    if [ "$expired" == "1" ] || [ "$overquota" == "1" ]; then
      usermod -L "$user" 2>/dev/null
      chage -E 1 "$user" 2>/dev/null
      pkill -9 -u "$user" 2>/dev/null
      logger "ByteRoot: SSH account $user LOCKED (expired=$expired overquota=$overquota)"
      echo "$user|$type|$maxconn|$quota|$expiry|$created|locked" >> "$tmp"
    else
      echo "$user|$type|$maxconn|$quota|$expiry|$created|$status" >> "$tmp"
    fi
  done < "$SSH_DB"
  mv "$tmp" "$SSH_DB"
fi

# ---- Xray accounts (vmess / vless / trojan) ----
for proto in vmess vless trojan; do
  db="$DB/$proto.db"
  tag="$proto-ws"
  [ -s "$db" ] || continue
  tmp=$(mktemp)
  while IFS='|' read -r name cred type maxconn quota expiry created status; do
    [ -z "$name" ] && continue
    if [ "$status" == "removed" ]; then
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|removed" >> "$tmp"
      continue
    fi
    expired=0
    if [ "$expiry" != "-" ] && [ "$expiry" \< "$TODAY" ]; then expired=1; fi
    overquota=0
    if [ "$quota" != "0" ] && [ -n "$quota" ]; then
      stat=$(xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>$name>>>traffic" 2>/dev/null)
      total=$(echo "$stat" | jq '[.stat[]?.value] | add // 0' 2>/dev/null)
      [ -z "$total" ] && total=0
      limitbytes=$(( quota * 1073741824 ))
      [ "$total" -ge "$limitbytes" ] && overquota=1
    fi
    if [ "$expired" == "1" ] || [ "$overquota" == "1" ]; then
      jq --arg tag "$tag" --arg id "$cred" \
        '(.inbounds[] | select(.tag==$tag) | .settings.clients) |= map(select((.id // "") != $id and (.password // "") != $id))' \
        "$XRAY_CONFIG" > /tmp/br_xray.json && mv /tmp/br_xray.json "$XRAY_CONFIG"
      NEED_RESTART=1
      logger "ByteRoot: $proto account $name REMOVED (expired=$expired overquota=$overquota)"
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|removed" >> "$tmp"
    else
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|$status" >> "$tmp"
    fi
  done < "$db"
  mv "$tmp" "$db"
done

[ "$NEED_RESTART" == "1" ] && systemctl restart xray
