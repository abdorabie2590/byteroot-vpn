#!/bin/bash
# ByteRoot - best-effort concurrent SSH connection limiter (runs via cron every minute)
DB=/etc/byteroot/db/ssh.db
[ -s "$DB" ] || exit 0
while IFS='|' read -r user type maxconn quota expiry created status; do
  [ -z "$user" ] && continue
  [ "$status" == "locked" ] && continue
  [ -z "$maxconn" ] && continue
  [ "$maxconn" == "0" ] && continue
  current=$(ps -eo user:32,pid,cmd | awk -v u="$user" '$1==u && $0 ~ /sshd:/{print $2}' | wc -l)
  if [ "$current" -gt "$maxconn" ]; then
    excess=$(( current - maxconn ))
    ps -eo user:32,pid,cmd | awk -v u="$user" '$1==u && $0 ~ /sshd:/{print $2}' | head -n "$excess" | while read -r pid; do
      kill -9 "$pid" 2>/dev/null
    done
    logger "ByteRoot: killed $excess excess SSH session(s) for $user (limit=$maxconn)"
  fi
done < "$DB"
