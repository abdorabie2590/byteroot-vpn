# ByteRoot VPN

سكربت تثبيت وإدارة سيرفر VPN متعدد البروتوكولات، بلوحة تحكم احترافية (Terminal Panel) لإدارة الحسابات، مراقبة الاستهلاك، والقيود.

**Dev. Eng Abdelrahman Rabie**
**Telegram:** [@PacketBreaker](https://t.me/PacketBreaker)

---

## المميزات (Features)

### البروتوكولات المدعومة
| البروتوكول | المنفذ |
|---|---|
| OpenSSH | 22 |
| SSH Websocket | 80 , 8080 |
| SSH Stunnel (SSL/TLS) | 442 (مباشر) + 443 (مشترك عبر HAProxy) |
| Badvpn UDPGW | 7100–7900 |
| Nginx | 81 |
| Vmess WS TLS | 443 (`/vmess`) |
| Vless WS TLS | 443 (`/vless`) |
| Trojan WS TLS | 443 (`/trojan`) |
| Vmess WS NoTLS | 80 (`/vmess`) |
| Vless WS NoTLS | 80 (`/vless`) |
| Trojan WS NoTLS | 80 (`/trojan`) |

### مشاركة المنفذ 443
المنفذ 443 مشترك فعليًا بين **Stunnel (SSH-SSL)** و **Nginx (Vmess/Vless/Trojan TLS)** عن طريق **HAProxy** الذي يفحص TLS SNI بدون فك تشفير:
- SNI = الدومين المُدخَل → Nginx (بروتوكولات الويب سوكت)
- بدون SNI / SNI مختلف → Stunnel (SSH-SSL)

> **مهم:** في تطبيقات SSH-SSL (HTTP Injector, KPN Tunnel, ...) اترك خانة SNI/SAN فارغة أو اكتب أي نص غير الدومين.

### لوحة التحكم (`byteroot`)
- بانر احترافي ملوّن بالوقت والتاريخ اللحظي، الدومين، النظام والمعمارية
- عداد المتصلين الآن على SSH لحظيًا
- عداد حسابات SSH / Vmess / Vless / Trojan
- إنشاء حسابات **حرة Unlimited** أو **محدودة** (عدد اتصالات، باقة GB، أيام صلاحية)
- مراقبة استهلاك كل حساب بالـ GB
- تفعيل/قفل/حذف الحسابات
- حالة كل الخدمات وإعادة تشغيلها (فردي أو جماعي)
- تنظيف الكاش وسجلات النظام
- إنفاذ تلقائي (Cron) لقفل/حذف الحسابات المنتهية أو المتجاوزة للباقة

### التوافق
- **الأنظمة:** Ubuntu 22 → 26 , Debian 10 وما بعده
- **المعماريات:** x86_64 و arm64 (يشمل **Oracle Cloud A1 Always Free / Ampere**)
- **السيرفرات المجرّبة:** DigitalOcean, Hostinger, Contabo, Oracle Cloud

---

## التثبيت (Installation)

```bash
git clone https://github.com/abdorabie2590/byteroot-vpn.git
cd byteroot-vpn
chmod +x install.sh
sudo ./install.sh
```

هيُطلب منك إدخال الدومين الخاص بيك، والسكربت هيتأكد إنه موجّه (A Record) على IP السيرفر، ويصدر شهادة SSL تلقائيًا عبر Let's Encrypt.

بعد التثبيت، لوحة التحكم بتفتح تلقائيًا، وترجعلها في أي وقت بكتابة:
```bash
byteroot
```

---

## هيكل المشروع (Project Structure)

```
byteroot-vpn/
├── install.sh              # السكربت الرئيسي (يقوم بكل التثبيت والإعداد)
├── scripts/
│   ├── byteroot-menu.sh    # نسخة مرجعية من لوحة التحكم (نفس الملف يُنشأ في /usr/local/bin/byteroot)
│   ├── enforce.sh          # نسخة مرجعية من سكربت إنفاذ الصلاحية/الباقات (Cron كل 5 دقائق)
│   └── conn_limit.sh       # نسخة مرجعية من سكربت تحديد الاتصالات المتزامنة (Cron كل دقيقة)
├── LICENSE
└── README.md
```

> **ملاحظة:** `install.sh` ملف متكامل ومستقل بذاته (self-contained) — يقوم بإنشاء كل الملفات المذكورة أعلاه مباشرة على السيرفر أثناء التثبيت. الملفات الموجودة داخل `scripts/` هي نسخ مرجعية لمراجعة/تعديل الكود قبل الرفع فقط.

---

## القيود المعروفة (Known Limitations)

1. **حساب استهلاك SSH بالـ GB** يعتمد على `iptables` ويحسب حركة **الخروج (Download) فقط** من السيرفر — تقريب عملي شائع، وليس دقيقًا 100% لحركة الرفع.
2. **حد عدد الاتصالات لحسابات Vmess/Vless/Trojan** معلوماتي فقط حاليًا وغير منفَّذ تلقائيًا (بعكس SSH الذي يُنفَّذ فعليًا عبر PAM + Cron).
3. قفل الحسابات المنتهية/المتجاوزة للباقة يتم عبر Cron كل 5 دقائق (ليس لحظيًا فوريًا).

---

## الدعم (Support)

للمساعدة أو الاستفسارات، تواصل عبر تيليجرام: [@PacketBreaker](https://t.me/PacketBreaker)

---

## الترخيص (License)

هذا المشروع مرخّص تحت [MIT License](LICENSE) — جميع الحقوق محفوظة لـ **Dev. Eng Abdelrahman Rabie**.
