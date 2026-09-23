#!/bin/bash
# =====================================================================
#  ByteRoot VPN Management Panel
#  Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker
# =====================================================================

DB=/etc/byteroot/db
SSH_DB="$DB/ssh.db"
VMESS_DB="$DB/vmess.db"
VLESS_DB="$DB/vless.db"
TROJAN_DB="$DB/trojan.db"
XRAY_CONFIG=/usr/local/etc/xray/config.json
DOMAIN=$(cat /etc/byteroot/domain 2>/dev/null)
INFO_FILE=/root/byteroot-info.txt

RED='\e[91m'; GREEN='\e[92m'; YELLOW='\e[93m'; CYAN='\e[96m'; MAGENTA='\e[95m'; BOLD='\e[1m'; NC='\e[0m'

pause(){ read -rp $'\n'"اضغط Enter للعودة..." _; }
count_db(){ [ -f "$1" ] && grep -vc '^[[:space:]]*$' "$1" 2>/dev/null || echo 0; }

online_ssh_count(){
  ss -tn state established 2>/dev/null | awk '{print $4}' | grep -E ':(22|442|8080)$' | wc -l
}

banner(){
clear
echo -e "${CYAN}${BOLD}"
cat <<"LOGO"
 ____        _       ____             _
| __ ) _   _| |_ ___|  _ \ ___   ___ | |_
|  _ \| | | | __/ _ \ |_) / _ \ / _ \| __|
| |_) | |_| | ||  __/  _ < (_) | (_) | |_
|____/ \__, |\__\___|_| \_\___/ \___/ \__|
       |___/
LOGO
echo -e "${NC}"
echo -e "${YELLOW}${BOLD}            ByteRoot VPN Management Panel${NC}"
echo -e "${MAGENTA}     Dev. Eng Abdelrahman Rabie   |   Telegram: @PacketBreaker${NC}"
echo -e "${CYAN}=====================================================================${NC}"
echo -e "${GREEN} الوقت والتاريخ : $(date '+%Y-%m-%d  %H:%M:%S')${NC}"
echo -e " الدومين        : ${DOMAIN:-غير محدد}"
if [ -f /etc/os-release ]; then . /etc/os-release; echo " النظام          : $PRETTY_NAME | $(uname -m)"; fi
echo -e "${CYAN}---------------------------------------------------------------------${NC}"
echo -e " المتصلين الآن (SSH)      : ${YELLOW}$(online_ssh_count)${NC}"
echo -e " حسابات SSH                : ${GREEN}$(count_db "$SSH_DB")${NC}"
echo -e " حسابات Vmess              : ${GREEN}$(count_db "$VMESS_DB")${NC}"
echo -e " حسابات Vless              : ${GREEN}$(count_db "$VLESS_DB")${NC}"
echo -e " حسابات Trojan             : ${GREEN}$(count_db "$TROJAN_DB")${NC}"
echo -e "${CYAN}=====================================================================${NC}"
}

ask_limits(){
  # sets global vars: TYPE MAXCONN QUOTA DAYS
  echo " 1) حساب حر Unlimited (بدون أي قيود)"
  echo " 2) حساب محدود Limited (اتصالات / GB / أيام)"
  read -rp " اختر نوع الحساب: " t
  MAXCONN=0; QUOTA=0; DAYS=0; TYPE="unlimited"
  if [ "$t" == "2" ]; then
    TYPE="limited"
    read -rp " أقصى عدد اتصالات متزامنة (0 = بدون حد): " MAXCONN
    read -rp " الباقة بالـ GB (0 = بدون حد): " QUOTA
    read -rp " عدد أيام الصلاحية (0 = بدون انتهاء): " DAYS
    [ -z "$MAXCONN" ] && MAXCONN=0
    [ -z "$QUOTA" ] && QUOTA=0
    [ -z "$DAYS" ] && DAYS=0
  fi
}

# ---------------- SSH ----------------
create_ssh_account(){
  banner; echo -e "${BOLD}--- 1) إنشاء حساب SSH جديد ---${NC}"
  read -rp " اسم المستخدم: " uname
  if [ -z "$uname" ] || id "$uname" &>/dev/null; then echo -e "${RED}اسم غير صالح أو مستخدم بالفعل${NC}"; pause; return; fi
  read -rp " الباسورد (فارغ = توليد تلقائي): " pass
  [ -z "$pass" ] && pass=$(openssl rand -base64 9)
  ask_limits

  useradd -M -s /usr/sbin/nologin "$uname"
  echo "$uname:$pass" | chpasswd

  expiry="-"
  if [ "$DAYS" != "0" ]; then
    expiry=$(date -d "+$DAYS days" +%Y-%m-%d)
    chage -E "$expiry" "$uname"
  fi

  if [ "$MAXCONN" != "0" ]; then
    mkdir -p /etc/security/limits.d
    sed -i "/^$uname /d" /etc/security/limits.d/byteroot.conf 2>/dev/null
    echo "$uname hard maxlogins $MAXCONN" >> /etc/security/limits.d/byteroot.conf
  fi

  if [ "$QUOTA" != "0" ]; then
    uid=$(id -u "$uname")
    iptables -N "br_$uname" 2>/dev/null
    iptables -I OUTPUT -m owner --uid-owner "$uid" -j "br_$uname" 2>/dev/null
    iptables -A "br_$uname" -j RETURN 2>/dev/null
  fi

  echo "$uname|$TYPE|$MAXCONN|$QUOTA|$expiry|$(date +%Y-%m-%d)|active" >> "$SSH_DB"

  banner
  echo -e "${GREEN}تم إنشاء حساب SSH بنجاح ✅${NC}"
  echo "-----------------------------------"
  echo " Username : $uname"
  echo " Password : $pass"
  echo " Domain   : $DOMAIN"
  echo " Ports    : 22 (SSH) | 442/443 (SSL) | 80/8080 (WS)"
  echo " Type     : $TYPE"
  [ "$TYPE" == "limited" ] && echo " Limits   : Conn=$MAXCONN | Quota=${QUOTA}GB | Expiry=$expiry"
  pause
}

list_ssh_accounts(){
  banner; echo -e "${BOLD}--- قائمة حسابات SSH ---${NC}"
  printf "%-15s %-10s %-6s %-6s %-12s %-10s\n" "Username" "Type" "Conn" "GB" "Expiry" "Status"
  echo "----------------------------------------------------------------------"
  [ -s "$SSH_DB" ] && while IFS='|' read -r u t m q e c s; do
    [ -z "$u" ] && continue
    used=$(iptables -L "br_$u" -v -x -n 2>/dev/null | awk '/RETURN/{printf "%.2f", $2/1073741824; exit}')
    [ -z "$used" ] && used="0.00"
    printf "%-15s %-10s %-6s %-6s %-12s %-10s (Used: %sGB)\n" "$u" "$t" "$m" "$q" "$e" "$s" "$used"
  done < "$SSH_DB"
  pause
}

delete_ssh_account(){
  banner; echo -e "${BOLD}--- حذف حساب SSH ---${NC}"
  read -rp " اسم المستخدم للحذف: " uname
  if ! id "$uname" &>/dev/null; then echo -e "${RED}غير موجود${NC}"; pause; return; fi
  userdel -rf "$uname" 2>/dev/null
  iptables -F "br_$uname" 2>/dev/null; iptables -D OUTPUT -m owner --uid-owner "$(id -u "$uname" 2>/dev/null)" -j "br_$uname" 2>/dev/null; iptables -X "br_$uname" 2>/dev/null
  sed -i "/^$uname /d" /etc/security/limits.d/byteroot.conf 2>/dev/null
  sed -i "/^$uname|/d" "$SSH_DB"
  echo -e "${GREEN}تم حذف الحساب${NC}"; pause
}

lock_unlock_ssh(){
  banner; echo -e "${BOLD}--- قفل / فتح حساب SSH ---${NC}"
  read -rp " اسم المستخدم: " uname
  if ! id "$uname" &>/dev/null; then echo -e "${RED}غير موجود${NC}"; pause; return; fi
  echo " 1) قفل الحساب"; echo " 2) فتح الحساب"
  read -rp " اختر: " a
  if [ "$a" == "1" ]; then
    usermod -L "$uname"; sed -i "s/^\($uname|.*|\)[^|]*$/\1locked/" "$SSH_DB"
    echo -e "${YELLOW}تم قفل الحساب${NC}"
  else
    usermod -U "$uname"; sed -i "s/^\($uname|.*|\)[^|]*$/\1active/" "$SSH_DB"
    echo -e "${GREEN}تم فتح الحساب${NC}"
  fi
  pause
}

ssh_menu(){
while true; do
banner
echo -e "${BOLD} إدارة حسابات SSH${NC}"
echo " 1) إنشاء حساب جديد"
echo " 2) عرض كل الحسابات"
echo " 3) حذف حساب"
echo " 4) قفل / فتح حساب"
echo " 0) رجوع"
read -rp " اختر: " c
case $c in
  1) create_ssh_account ;;
  2) list_ssh_accounts ;;
  3) delete_ssh_account ;;
  4) lock_unlock_ssh ;;
  0) return ;;
esac
done
}

# ---------------- Xray (vmess/vless/trojan) ----------------
create_xray_account(){
  proto=$1
  case $proto in
    vmess) tag="vmess-ws"; db="$VMESS_DB" ;;
    vless) tag="vless-ws"; db="$VLESS_DB" ;;
    trojan) tag="trojan-ws"; db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- إنشاء حساب $proto جديد ---${NC}"
  read -rp " اسم الحساب (Email/Label): " name
  [ -z "$name" ] && { echo -e "${RED}اسم غير صالح${NC}"; pause; return; }
  ask_limits

  if [ "$proto" == "trojan" ]; then
    cred=$(openssl rand -hex 8)
    client=$(jq -n --arg pass "$cred" --arg email "$name" '{password:$pass, email:$email, level:0}')
  else
    cred=$(cat /proc/sys/kernel/random/uuid)
    if [ "$proto" == "vmess" ]; then
      client=$(jq -n --arg id "$cred" --arg email "$name" '{id:$id, alterId:0, email:$email, level:0}')
    else
      client=$(jq -n --arg id "$cred" --arg email "$name" '{id:$id, email:$email, level:0}')
    fi
  fi

  tmp=$(mktemp)
  jq --arg tag "$tag" --argjson c "$client" \
    '(.inbounds[] | select(.tag==$tag) | .settings.clients) += [$c]' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
  systemctl restart xray

  expiry="-"
  [ "$DAYS" != "0" ] && expiry=$(date -d "+$DAYS days" +%Y-%m-%d)
  echo "$name|$cred|$TYPE|$MAXCONN|$QUOTA|$expiry|$(date +%Y-%m-%d)|active" >> "$db"

  banner
  echo -e "${GREEN}تم إنشاء حساب $proto بنجاح ✅${NC}"
  echo "-----------------------------------"
  echo " Name     : $name"
  if [ "$proto" == "trojan" ]; then echo " Password : $cred"; else echo " UUID     : $cred"; fi
  echo " Domain   : $DOMAIN"
  echo " Path     : /$proto"
  echo " Network  : ws"
  echo " Ports    : 443 (TLS, SNI=$DOMAIN) | 80 (No TLS)"
  echo " Type     : $TYPE"
  [ "$TYPE" == "limited" ] && echo " Limits   : Conn(info)=$MAXCONN | Quota=${QUOTA}GB | Expiry=$expiry"
  pause
}

list_xray_accounts(){
  proto=$1
  case $proto in
    vmess) db="$VMESS_DB" ;; vless) db="$VLESS_DB" ;; trojan) db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- قائمة حسابات $proto ---${NC}"
  printf "%-18s %-10s %-6s %-12s %-10s\n" "Name" "Type" "GB" "Expiry" "Status"
  echo "----------------------------------------------------------------------"
  [ -s "$db" ] && while IFS='|' read -r n cr t m q e c s; do
    [ -z "$n" ] && continue
    printf "%-18s %-10s %-6s %-12s %-10s\n" "$n" "$t" "$q" "$e" "$s"
  done < "$db"
  pause
}

delete_xray_account(){
  proto=$1
  case $proto in
    vmess) tag="vmess-ws"; db="$VMESS_DB" ;;
    vless) tag="vless-ws"; db="$VLESS_DB" ;;
    trojan) tag="trojan-ws"; db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- حذف حساب $proto ---${NC}"
  read -rp " اسم الحساب: " name
  cred=$(awk -F'|' -v n="$name" '$1==n{print $2; exit}' "$db")
  if [ -z "$cred" ]; then echo -e "${RED}غير موجود${NC}"; pause; return; fi
  tmp=$(mktemp)
  jq --arg tag "$tag" --arg id "$cred" \
    '(.inbounds[] | select(.tag==$tag) | .settings.clients) |= map(select((.id // "") != $id and (.password // "") != $id))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
  systemctl restart xray
  sed -i "/^$name|/d" "$db"
  echo -e "${GREEN}تم حذف الحساب${NC}"; pause
}

xray_menu(){
proto=$1
while true; do
banner
echo -e "${BOLD} إدارة حسابات $proto${NC}"
echo " 1) إنشاء حساب جديد"
echo " 2) عرض كل الحسابات"
echo " 3) حذف حساب"
echo " 0) رجوع"
read -rp " اختر: " c
case $c in
  1) create_xray_account "$proto" ;;
  2) list_xray_accounts "$proto" ;;
  3) delete_xray_account "$proto" ;;
  0) return ;;
esac
done
}

# ---------------- Live monitor ----------------
live_online(){
  echo -e "${YELLOW}اضغط q ثم Enter للخروج من الوضع اللحظي${NC}"; sleep 1
  while true; do
    banner
    echo -e "${BOLD} المتصلين الآن (تحديث كل 2 ثانية)${NC}"
    echo " إجمالي اتصالات SSH النشطة : $(online_ssh_count)"
    echo ""
    ss -tn state established 2>/dev/null | awk '{print $4}' | grep -E ':(22|442|8080)$' | sort | uniq -c | sort -rn | head -n 15
    read -t 2 -n 1 key
    [ "$key" == "q" ] && break
  done
}

# ---------------- Usage monitor ----------------
usage_menu(){
  banner; echo -e "${BOLD}--- مراقبة استهلاك الباقات ---${NC}"
  echo -e "${CYAN}[SSH]${NC}"
  printf "%-15s %-10s\n" "Username" "Used(GB)"
  [ -s "$SSH_DB" ] && while IFS='|' read -r u t m q e c s; do
    [ -z "$u" ] && continue
    used=$(iptables -L "br_$u" -v -x -n 2>/dev/null | awk '/RETURN/{printf "%.2f", $2/1073741824; exit}')
    [ -z "$used" ] && used="0.00"
    printf "%-15s %-10s\n" "$u" "$used"
  done < "$SSH_DB"
  echo ""
  echo -e "${CYAN}[Vmess/Vless/Trojan]${NC}"
  printf "%-18s %-10s\n" "Name" "Used(GB)"
  for proto in vmess vless trojan; do
    db="$DB/$proto.db"
    [ -s "$db" ] && while IFS='|' read -r n cr t m q e c s; do
      [ -z "$n" ] && continue
      stat=$(xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>$n>>>traffic" 2>/dev/null)
      total=$(echo "$stat" | jq '([.stat[]?.value] | add // 0) / 1073741824' 2>/dev/null)
      [ -z "$total" ] && total="0"
      printf "%-18s %-10s\n" "$n" "$total"
    done < "$db"
  done
  pause
}

# ---------------- Services ----------------
SERVICES="ssh nginx haproxy stunnel4 xray cron"
services_menu(){
while true; do
banner
echo -e "${BOLD} حالة الخدمات${NC}"
i=1
declare -A idx_map
for s in $SERVICES; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  if [ "$st" == "active" ]; then col="${GREEN}"; else col="${RED}"; fi
  printf " %d) %-12s : ${col}%s${NC}\n" "$i" "$s" "$st"
  idx_map[$i]=$s
  i=$((i+1))
done
badcount=$(systemctl list-units --type=service --all 2>/dev/null | grep -c 'badvpn-udpgw@.*active')
echo " ${i}) badvpn-udpgw (نشط على: $badcount منفذ)"
echo ""
echo " r) إعادة تشغيل كل الخدمات"
echo " 0) رجوع"
read -rp " اختر رقم الخدمة لإعادة تشغيلها أو r أو 0: " c
if [ "$c" == "0" ]; then return; fi
if [ "$c" == "r" ]; then
  for s in $SERVICES; do systemctl restart "$s"; done
  for p in 7100 7200 7300 7400 7500 7600 7700 7800 7900; do systemctl restart "badvpn-udpgw@$p" 2>/dev/null; done
  echo -e "${GREEN}تم إعادة تشغيل جميع الخدمات${NC}"; pause
elif [ -n "${idx_map[$c]}" ]; then
  systemctl restart "${idx_map[$c]}"
  echo -e "${GREEN}تم إعادة تشغيل ${idx_map[$c]}${NC}"; pause
fi
done
}

clear_cache(){
  banner; echo -e "${BOLD}--- تنظيف الكاش ---${NC}"
  apt-get clean -y >/dev/null 2>&1
  apt-get autoremove -y >/dev/null 2>&1
  journalctl --vacuum-time=3d >/dev/null 2>&1
  : > /var/log/xray/access.log 2>/dev/null
  echo -e "${GREEN}تم تنظيف الكاش وسجلات النظام${NC}"
  pause
}

main_menu(){
while true; do
banner
echo -e "${BOLD} القائمة الرئيسية${NC}"
echo " 1) إدارة حسابات SSH"
echo " 2) إدارة حسابات Vmess"
echo " 3) إدارة حسابات Vless"
echo " 4) إدارة حسابات Trojan"
echo " 5) المتصلين الآن (لحظي)"
echo " 6) مراقبة استهلاك الباقات (GB)"
echo " 7) حالة الخدمات / إعادة التشغيل"
echo " 8) تنظيف الكاش"
echo " 9) عرض تقرير السيرفر الكامل"
echo " 0) خروج"
echo -e "${CYAN}=====================================================================${NC}"
read -rp " اختر رقم: " c
case $c in
  1) ssh_menu ;;
  2) xray_menu vmess ;;
  3) xray_menu vless ;;
  4) xray_menu trojan ;;
  5) live_online ;;
  6) usage_menu ;;
  7) services_menu ;;
  8) clear_cache ;;
  9) banner; cat "$INFO_FILE" 2>/dev/null; pause ;;
  0) exit 0 ;;
  *) ;;
esac
done
}

main_menu
