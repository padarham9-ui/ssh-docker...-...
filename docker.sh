#!/usr/bin/env bash
# sudo bash vps-box.sh setup
# sudo bash vps-box.sh add                 (نام و پورت رندوم + کلید خودکار + لینک sshx)
# sudo RAM=256m DISK=5G bash vps-box.sh add NAME PORT /path/user.pub
# sudo bash vps-box.sh del NAME            (با PURGE=1 ولوم هم حذف می‌شود)
# sudo bash vps-box.sh bw NAME UP DOWN     (تغییر پهنای باند؛ مثال: bw web 5mbit 20mbit ، off = نامحدود)
# sudo bash vps-box.sh bw NAME             (نمایش محدودیت فعلی)
set -euo pipefail

# ================== تنظیمات (اینجا عوض کن) ==================
RAM="${RAM:-256m}"                 # مثال: 64m, 256m, 1g
CPU_CORES="${CPU_CORES:-1}"        # تعداد هسته
CPU_PERCENT="${CPU_PERCENT:-20}"   # درصد از آن هسته‌ها
DISK="${DISK:-2G}"                   # مثال: 20G  (خالی = بدون محدودیت؛ نیاز به overlay2 روی xfs با pquota)
PIDS="${PIDS:-100}"                # حداکثر تعداد پروسس برای هر کانتینر
SUBNET="${SUBNET:-172.30.0.0/24}"  # ساب‌نت شبکه (اگر با شبکه دیگری تداخل داشت عوض کن)
PURGE="${PURGE:-1}"                # برای del: 1 = ولوم هم حذف شود (پیش‌فرض)، 0 = ولوم بماند
BW_UP="${BW_UP:-45mbit}"           # سقف آپلود (خروجی کانتینر)  مثال: 512kbit, 10mbit, 1gbit ; off = نامحدود
BW_DOWN="${BW_DOWN:-50mbit}"       # سقف دانلود (ورودی کانتینر) مثال: 512kbit, 10mbit, 1gbit ; off = نامحدود
# ============================================================

DIR=/opt/vps-box
IMG=vps-box
NET=vps-net
LABEL=vps-box
SELF=/usr/local/sbin/vps-box.sh
BWDIR=/etc/vps-box/bw.d
KEYDIR=$DIR/keys

die()  { echo "[خطا] $*" >&2; exit 1; }
warn() { echo "[هشدار] $*" >&2; }
ipt()  { iptables -w "$@"; }
has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ]        || die "باید root باشی (با sudo اجرا کن)"
[ "$(uname -s)" = "Linux" ] || die "فقط روی لینوکس کار می‌کند"

# ---------- تشخیص پکیج‌منیجر ----------
if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v yum     >/dev/null; then PM=yum
else PM=none; fi

pm_install() {
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    *)   die "پکیج‌منیجر پشتیبانی‌نشده؛ این‌ها را دستی نصب کن: $*" ;;
  esac
}

wait_docker() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

check_virt() {
  local v=""
  command -v systemd-detect-virt >/dev/null && v=$(systemd-detect-virt 2>/dev/null || true)
  case "$v" in
    openvz|lxc|lxc-libvirt|proot)
      die "این VPS از نوع $v است و معمولاً اجازه اجرای داکر (و userns/cgroup) را نمی‌دهد. VPS از نوع KVM بگیر." ;;
  esac
}

validate_limits() {
  [[ "$RAM" =~ ^[1-9][0-9]*[bkmgBKMG]?$ ]]            || die "مقدار RAM نامعتبر است: $RAM"
  [[ "$CPU_CORES" =~ ^[0-9]+(\.[0-9]+)?$ ]]           || die "مقدار CPU_CORES نامعتبر است: $CPU_CORES"
  [[ "$CPU_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]]         || die "مقدار CPU_PERCENT نامعتبر است: $CPU_PERCENT"
  [[ "$PIDS" =~ ^[1-9][0-9]*$ ]]                      || die "مقدار PIDS نامعتبر است: $PIDS"
  if [ -n "$DISK" ]; then
    [[ "$DISK" =~ ^[1-9][0-9]*[kKmMgGtT]?$ ]]         || die "مقدار DISK نامعتبر است: $DISK"
  fi
}

# ---------- محدودیت پهنای باند (tc روی veth سمت هاست) ----------
# بررسی مقدار: off/0 یا عدد + kbit|mbit|gbit
valid_rate() { [[ "$1" =~ ^(off|0|[1-9][0-9]*(kbit|mbit|gbit))$ ]]; }
is_off()     { [ "$1" = off ] || [ "$1" = 0 ]; }

to_kbit() {
  local v=$1 n
  n=${v%[kmg]bit}
  case "$v" in
    *kbit) echo "$n" ;;
    *mbit) echo $((n * 1000)) ;;
    *gbit) echo $((n * 1000000)) ;;
  esac
}

# burst (بایت) ≈ 256ms ترافیک، حداقل 70000 بایت
# (باید از بزرگ‌ترین پکت GSO/TSO یعنی ~64KB بزرگ‌تر باشد وگرنه پکت‌ها دراپ می‌شوند)
burst_for() {
  local k b
  k=$(to_kbit "$1")
  b=$((k * 32))
  [ "$b" -ge 70000 ] || b=70000
  echo "$b"
}

# نام veth سمت هاست برای یک کانتینر
veth_of() {
  local pid idx f
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 1
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  idx=$(cat "/proc/$pid/root/sys/class/net/eth0/iflink" 2>/dev/null || true)
  if [ -z "$idx" ] && command -v nsenter >/dev/null; then
    idx=$(nsenter -t "$pid" -n ip -o link show eth0 2>/dev/null \
          | sed -n 's/^[0-9]*: eth0@if\([0-9]*\):.*/\1/p' || true)
  fi
  [ -n "$idx" ] || return 1
  for f in /sys/class/net/*/ifindex; do
    if [ "$(cat "$f" 2>/dev/null)" = "$idx" ]; then
      f=${f%/ifindex}
      echo "${f##*/}"
      return 0
    fi
  done
  return 1
}

bw_conf_read() {  # NAME -> UP/DOWN را در متغیرهای سراسری cur_up/cur_down می‌گذارد
  cur_up=off; cur_down=off
  local UP="" DOWN=""
  if [ -f "$BWDIR/$1" ]; then
    # shellcheck disable=SC1090
    . "$BWDIR/$1"
  fi
  [ -z "${UP:-}" ]   || cur_up=$UP
  [ -z "${DOWN:-}" ] || cur_down=$DOWN
}

bw_conf_write() {  # NAME UP DOWN
  mkdir -p "$BWDIR"
  printf 'UP=%s\nDOWN=%s\n' "$2" "$3" > "$BWDIR/$1"
}

# اعمال محدودیت روی veth کانتینر (idempotent)
bw_apply() {
  local name=$1 v b
  command -v tc >/dev/null || { warn "tc نصب نیست؛ پهنای باند محدود نشد"; return 1; }
  bw_conf_read "$name"
  v=$(veth_of "$name") || { warn "veth کانتینر $name پیدا نشد (آیا در حال اجراست؟)"; return 1; }

  modprobe sch_tbf 2>/dev/null || true
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_police 2>/dev/null || true

  # دانلود (ترافیک به سمت کانتینر) = egress روی veth → shaping با tbf
  tc qdisc del dev "$v" root 2>/dev/null || true
  if ! is_off "$cur_down"; then
    b=$(burst_for "$cur_down")
    tc qdisc add dev "$v" root tbf rate "$cur_down" burst "$b" latency 400ms \
      || { warn "اعمال محدودیت دانلود روی $v شکست خورد"; return 1; }
  fi

  # آپلود (ترافیک از کانتینر) = ingress روی veth → policing
  # mtu 65535: بدون آن پکت‌های بزرگ‌تر از ~2KB (GSO) همیشه دراپ می‌شوند
  tc qdisc del dev "$v" ingress 2>/dev/null || true
  if ! is_off "$cur_up"; then
    b=$(burst_for "$cur_up")
    tc qdisc add dev "$v" handle ffff: ingress \
      && tc filter add dev "$v" parent ffff: protocol all prio 1 u32 match u32 0 0 \
           police rate "$cur_up" burst "$b" mtu 65535 drop flowid :1 \
      || { warn "اعمال محدودیت آپلود روی $v شکست خورد"; return 1; }
  fi
  echo "[ok] پهنای باند $name: آپلود=$cur_up دانلود=$cur_down (روی $v)"
}

bw_apply_all() {
  local n
  while read -r n; do
    [ -n "$n" ] || continue
    bw_apply "$n" || true
  done < <(docker ps --filter "label=$LABEL=1" --format '{{.Names}}')
}

# با هر start کانتینر (ریبوت، ریستارت، بالا آمدن داکر) محدودیت دوباره اعمال شود
bw_watch() {
  docker info >/dev/null 2>&1 || die "داکر در حال اجرا نیست"
  local n
  # هم‌زمان با شروع شنود رویدادها، کانتینرهای در حال اجرا را هم اعمال کن (جلوگیری از race)
  ( sleep 3; bw_apply_all ) &
  while read -r n; do
    [ -n "$n" ] || continue
    sleep 1
    bw_apply "$n" || true
  done < <(docker events --filter type=container --filter event=start \
             --filter "label=$LABEL=1" --format '{{.Actor.Attributes.name}}')
  die "docker events متوقف شد"
}

bw_cmd() {
  [ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die "استفاده: $0 bw NAME [UP DOWN]"
  local NAME=$1 lbl
  valid_name "$NAME" || die "نام نامعتبر"
  command -v docker >/dev/null || die "داکر نصب نیست"
  lbl=$(docker container inspect -f "{{index .Config.Labels \"$LABEL\"}}" "$NAME" 2>/dev/null || true)
  [ "$lbl" = "1" ] || die "کانتینر $NAME وجود ندارد یا توسط vps-box ساخته نشده"

  if [ "$#" -eq 1 ]; then
    bw_conf_read "$NAME"
    echo "$NAME: آپلود=$cur_up دانلود=$cur_down"
    return 0
  fi
  valid_rate "$2" || die "مقدار UP نامعتبر (مثال: 512kbit، 10mbit، off)"
  valid_rate "$3" || die "مقدار DOWN نامعتبر (مثال: 512kbit، 10mbit، off)"
  bw_conf_write "$NAME" "$2" "$3"
  bw_apply "$NAME"
}

install_deps() {
  local pk=()
  command -v curl       >/dev/null || pk+=(curl)
  command -v awk        >/dev/null || pk+=(gawk)
  command -v iptables   >/dev/null || pk+=(iptables)
  command -v grep       >/dev/null || pk+=(grep)
  if ! command -v tc >/dev/null || ! command -v ip >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(iproute2); else pk+=(iproute iproute-tc); fi
  fi
  if ! command -v ssh-keygen >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(openssh-client); else pk+=(openssh-clients); fi
  fi
  [ -d /etc/ssl/certs ] || pk+=(ca-certificates)
  if [ "${#pk[@]}" -gt 0 ]; then
    echo "[نصب] ${pk[*]}"
    if [ "$PM" = apt ]; then apt-get update -y; fi
    pm_install "${pk[@]}"
  fi
}

install_docker() {
  if ! command -v docker >/dev/null; then
    echo "[نصب] docker (اسکریپت رسمی get.docker.com)"
    if ! curl -fsSL https://get.docker.com | sh; then
      warn "اسکریپت رسمی شکست خورد؛ تلاش با پکیج توزیع"
      if [ "$PM" = apt ]; then pm_install docker.io; else pm_install docker; fi
    fi
  fi
  if has_systemd; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
  wait_docker || die "داکر اجرا نمی‌شود: journalctl -u docker"
}

get_subnet() {
  local s=""
  s=$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
      | awk '{print $1}') || true
  echo "${s:-$SUBNET}"
}

# فایروال: فقط جلوگیری از دسترسی به شبکه‌های داخلی/اسپم SMTP.
# هیچ محدودیتی روی تعداد اتصال‌ها وجود ندارد (کنترل مصرف فقط با پهنای باند انجام می‌شود).
firewall() {
  command -v iptables >/dev/null || die "iptables نصب نیست"
  docker info >/dev/null 2>&1   || die "داکر در حال اجرا نیست"
  ipt -S DOCKER-USER >/dev/null 2>&1 \
    || die "زنجیره DOCKER-USER وجود ندارد (آیا داکر با iptables=false اجرا شده؟)"

  local SUB r p
  SUB=$(get_subnet)

  modprobe xt_conntrack 2>/dev/null || true

  ipt -N VPSNET 2>/dev/null || ipt -F VPSNET
  ipt -A VPSNET -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  ipt -A VPSNET -p udp --dport 53 -j RETURN
  ipt -A VPSNET -p tcp --dport 53 -j RETURN
  for r in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
    ipt -A VPSNET -d "$r" -j DROP
  done
  for p in 25 465 587; do ipt -A VPSNET -p tcp --dport "$p" -j DROP; done
  ipt -A VPSNET -j RETURN

  ipt -C DOCKER-USER -s "$SUB" -j VPSNET 2>/dev/null || ipt -I DOCKER-USER -s "$SUB" -j VPSNET
  ipt -C INPUT -s "$SUB" -m conntrack --ctstate NEW -j DROP 2>/dev/null || \
    ipt -I INPUT -s "$SUB" -m conntrack --ctstate NEW -j DROP
}

# قوانین فایروال بعد از ریبوت و بعد از بالا آمدن داکر دوباره اعمال شوند
persist_firewall() {
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF" ]; then
    install -m 755 "$0" "$SELF"
  fi
  if [ ! -x "$SELF" ]; then
    warn "اسکریپت به‌صورت فایل اجرا نشده؛ فایروال بعد از ریبوت خودکار برنمی‌گردد (آن را با bash vps-box.sh اجرا کن)"
    return 0
  fi
  if ! has_systemd; then
    warn "systemd وجود ندارد؛ فایروال را بعد از ریبوت دستی اجرا کن: $SELF firewall"
    return 0
  fi
  cat > /etc/systemd/system/vps-box-fw.service <<EOF
[Unit]
Description=vps-box firewall rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF firewall

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/vps-box-bw.service <<EOF
[Unit]
Description=vps-box bandwidth limits (re-applied on every container start)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SELF watch
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vps-box-fw.service >/dev/null 2>&1 || true
  systemctl restart vps-box-fw.service >/dev/null 2>&1 || true
  systemctl enable vps-box-bw.service >/dev/null 2>&1 || true
  systemctl restart vps-box-bw.service >/dev/null 2>&1 \
    || warn "سرویس vps-box-bw بالا نیامد؛ محدودیت پهنای باند بعد از ریبوت خودکار برنمی‌گردد (journalctl -u vps-box-bw)"
}

userns_active() {
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=userns'
}

enable_userns() {
  # user namespace: روت کانتینر = یوزر بی‌اختیار روی هاست
  if userns_active; then
    echo "[ok] userns-remap فعال است"
    return 0
  fi
  if [ -n "$(docker ps -aq)" ] || [ -s /etc/docker/daemon.json ]; then
    warn "کانتینر یا daemon.json موجود است؛ userns-remap را دستی اضافه کن:"
    echo '        "userns-remap": "default"  و systemctl restart docker' >&2
    return 0
  fi
  mkdir -p /etc/docker
  echo '{ "userns-remap": "default" }' > /etc/docker/daemon.json
  if has_systemd; then systemctl restart docker; fi
  if ! wait_docker; then
    rm -f /etc/docker/daemon.json
    if has_systemd; then systemctl restart docker || true; fi
    die "داکر با userns-remap بالا نیامد؛ تنظیم برگردانده شد"
  fi
  if userns_active; then
    echo "[ok] userns-remap فعال شد"
  else
    warn "userns-remap اعمال نشد (ممکن است با image store فعلی داکر ناسازگار باشد)"
  fi
}

setup() {
  check_virt
  install_deps
  install_docker
  mkdir -p "$DIR"

  cat > "$DIR/Dockerfile" <<'EOF'
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl nano less \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
RUN curl -sSf https://sshx.io/get | sh || true
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 2222
ENTRYPOINT ["/entrypoint.sh"]
EOF

  cat > "$DIR/sshd_config" <<'EOF'
Port 2222
AllowUsers root
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
UseDNS no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 60
ClientAliveCountMax 3
Subsystem sftp internal-sftp
EOF

  cat > "$DIR/entrypoint.sh" <<'EOF'
#!/bin/sh
set -e
mkdir -p /root/.ssh /run/sshd
chmod 700 /root /root/.ssh
if [ -n "$SSH_PUBKEY" ]; then
  printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
ssh-keygen -A
export SHELL=/bin/bash
if command -v sshx >/dev/null 2>&1; then
  ( sshx >/tmp/sshx.log 2>&1 & )
else
  ( curl -sSf https://sshx.io/get | sh -s run >/tmp/sshx.log 2>&1 & )
fi
exec /usr/sbin/sshd -D -e
EOF

  enable_userns

  docker build -t "$IMG" "$DIR"

  if ! docker network inspect "$NET" >/dev/null 2>&1; then
    docker network create --driver bridge --subnet "$SUBNET" \
      -o com.docker.network.bridge.enable_icc=false "$NET" \
      || die "ساخت شبکه شکست خورد؛ احتمالاً $SUBNET با شبکه دیگری تداخل دارد (SUBNET را عوض کن)"
  fi

  firewall
  persist_firewall
  echo "[ok] setup کامل شد"
}

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }

rand_name() { echo "box-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

rand_port() {
  local p i
  for i in $(seq 1 100); do
    p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40001 ))
    if command -v ss >/dev/null 2>&1; then
      [ -z "$(ss -H -ltn "sport = :$p" 2>/dev/null)" ] || continue
    fi
    echo "$p"
    return 0
  done
  return 1
}

get_sshx_link() {
  local name=$1 i l=""
  for i in $(seq 1 25); do
    l=$(docker exec "$name" cat /tmp/sshx.log 2>/dev/null \
        | grep -Eo 'https://sshx\.io/s/[^[:space:][:cntrl:]]+' | head -n1 || true)
    if [ -n "$l" ]; then echo "$l"; return 0; fi
    sleep 1
  done
  return 1
}

public_ip() { curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo "<IP-VPS>"; }

print_info() {  # NAME PORT [PRIVATE_KEY_PATH]
  local name=$1 port=$2 key=${3:-} pubip link self
  pubip=$(public_ip)
  if [ -x "$SELF" ]; then self="sudo $SELF"; else self="sudo bash $0"; fi
  link=$(get_sshx_link "$name" || true)
  echo
  echo "=============================================="
  echo "پورت : $port"
  echo "اسم  : $name"
  echo "----------------------------------------------"
  echo "اتصال با داکر (روی همین سرور):"
  echo "  docker exec -it $name bash"
  echo "اتصال با SSH (پورت $port را در فایروال/Security Group باز کن):"
  if [ -n "$key" ]; then
    echo "  ssh -i $key -p $port root@$pubip"
  else
    echo "  ssh -p $port root@$pubip"
  fi
  echo "حذف کانتینر:"
  echo "  $self del $name"
  echo "لینک sshx:"
  if [ -n "$link" ]; then
    echo "  $link"
  else
    echo "  (هنوز آماده نشد؛ بعداً: docker exec $name cat /tmp/sshx.log)"
  fi
  echo "=============================================="
}

add() {
  local NAME PORT KEY PRIV="" GENKEY=0
  if [ "$#" -eq 0 ]; then
    NAME=$(rand_name)
    PORT=$(rand_port) || die "پورت آزاد پیدا نشد"
    GENKEY=1
  elif [ "$#" -eq 3 ]; then
    NAME=$1; PORT=$2; KEY=$3
  else
    die "استفاده: $0 add   یا   $0 add NAME PORT PUBKEY_FILE"
  fi
  if [ "$GENKEY" -eq 1 ]; then
    install_deps
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    PRIV="$KEYDIR/$NAME"
    ssh-keygen -q -t ed25519 -N "" -C "$NAME" -f "$PRIV"
    KEY="$PRIV.pub"
  fi

  valid_name "$NAME" || die "نام نامعتبر (فقط a-z 0-9 _ - ، شروع با حرف)"
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "پورت نامعتبر"
  PORT=$((10#$PORT))
  { [ "$PORT" -gt 1024 ] && [ "$PORT" -le 65535 ]; } || die "پورت باید بین 1025 و 65535 باشد"
  validate_limits
  valid_rate "$BW_UP"   || die "مقدار BW_UP نامعتبر است: $BW_UP (مثال: 512kbit، 10mbit، off)"
  valid_rate "$BW_DOWN" || die "مقدار BW_DOWN نامعتبر است: $BW_DOWN (مثال: 512kbit، 10mbit، off)"

  # ---- بررسی کلید ----
  [ -f "$KEY" ] || die "فایل کلید پیدا نشد: $KEY"
  local n PUBKEY tmp
  n=$(grep -cv '^[[:space:]]*$' "$KEY" || true)
  [ "$n" -eq 1 ] || die "فایل کلید باید دقیقاً یک خط (یک کلید) داشته باشد"
  PUBKEY=$(grep -v '^[[:space:]]*$' "$KEY" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  local keyre='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]'
  [[ "$PUBKEY" =~ $keyre ]] || die "کلید عمومی معتبر نیست (باید با ssh-ed25519، ssh-rsa و... شروع شود)"
  tmp=$(mktemp)
  printf '%s\n' "$PUBKEY" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "کلید عمومی نامعتبر"
  fi
  rm -f "$tmp"

  # اگر هنوز setup نشده، خودکار انجام بده
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1 \
     || ! docker image inspect "$IMG" >/dev/null 2>&1 \
     || ! docker network inspect "$NET" >/dev/null 2>&1; then
    echo "[info] setup هنوز انجام نشده؛ در حال انجام..."
    setup
  fi

  if docker container inspect "$NAME" >/dev/null 2>&1; then
    die "کانتینری با نام $NAME از قبل وجود دارد"
  fi
  if command -v ss >/dev/null 2>&1 && [ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]; then
    die "پورت $PORT روی سرور در حال استفاده است"
  fi

  local CPUS
  CPUS=$(awk -v c="$CPU_CORES" -v p="$CPU_PERCENT" 'BEGIN{printf "%.2f", c*p/100}')
  awk -v x="$CPUS" 'BEGIN{exit !(x>=0.01)}' || die "سهم CPU خیلی کم است ($CPUS)"
  echo "[info] RAM=$RAM CPU=$CPUS هسته ($CPU_PERCENT% از $CPU_CORES) DISK=${DISK:-نامحدود}"

  local created_vol=0
  local args=(-d --name "$NAME" --hostname "$NAME" --label "$LABEL=1"
              --init --restart unless-stopped
              --network "$NET"
              -p "0.0.0.0:${PORT}:2222"
              -e "SSH_PUBKEY=$PUBKEY")

  if [ -z "$DISK" ]; then
    if ! docker volume inspect "${NAME}_root" >/dev/null 2>&1; then
      docker volume create --label "$LABEL=1" "${NAME}_root" >/dev/null
      created_vol=1
    fi
    args+=(-v "${NAME}_root:/root")
  else
    args+=(--storage-opt "size=$DISK")
  fi

  # بدون --ulimit nproc: با userns-remap این مقدار بین همه کانتینرها مشترک می‌شود؛ --pids-limit کافی است
  args+=(--cap-drop=ALL
         --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=FSETID
         --cap-add=SETUID --cap-add=SETGID --cap-add=KILL --cap-add=SYS_CHROOT
         --security-opt no-new-privileges:true
         --pids-limit="$PIDS"
         --memory="$RAM" --memory-swap="$RAM"
         --cpus="$CPUS"
         --ulimit nofile=65536:65536
         --log-opt max-size=10m --log-opt max-file=3)

  if ! docker run "${args[@]}" "$IMG" >/dev/null; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    if [ "$created_vol" -eq 1 ]; then docker volume rm "${NAME}_root" >/dev/null 2>&1 || true; fi
    [ -z "$DISK" ] || warn "محدودیت DISK فقط روی overlay2 با xfs و pquota کار می‌کند"
    if [ "$GENKEY" -eq 1 ]; then rm -f "$PRIV" "$PRIV.pub"; fi
    die "ساخت کانتینر شکست خورد"
  fi

  bw_conf_write "$NAME" "$BW_UP" "$BW_DOWN"
  sleep 1
  if ! bw_apply "$NAME"; then
    warn "محدودیت پهنای باند اعمال نشد؛ بعداً دوباره امتحان کن: $0 bw $NAME $BW_UP $BW_DOWN"
  fi

  print_info "$NAME" "$PORT" "$PRIV"
}

del() {
  [ "$#" -eq 1 ] || die "استفاده: $0 del NAME"
  local NAME=$1
  valid_name "$NAME" || die "نام نامعتبر"
  command -v docker >/dev/null || die "داکر نصب نیست"

  local lbl
  lbl=$(docker container inspect -f "{{index .Config.Labels \"$LABEL\"}}" "$NAME" 2>/dev/null || true)
  [ "$lbl" = "1" ] || die "کانتینر $NAME وجود ندارد یا توسط vps-box ساخته نشده"

  docker rm -f "$NAME" >/dev/null
  rm -f "$BWDIR/$NAME" "$KEYDIR/$NAME" "$KEYDIR/$NAME.pub"
  echo "[ok] کانتینر $NAME حذف شد"

  if docker volume inspect "${NAME}_root" >/dev/null 2>&1; then
    if [ "$PURGE" = "1" ]; then
      docker volume rm "${NAME}_root" >/dev/null
      echo "[ok] volume هم حذف شد"
    else
      echo "volume باقی ماند. حذف کامل: docker volume rm ${NAME}_root  (یا PURGE=1)"
    fi
  fi
}

case "${1:-}" in
  setup)    setup ;;
  add)      shift; add "$@" ;;
  del)      shift; del "$@" ;;
  firewall) firewall ;;
  bw)       shift; bw_cmd "$@" ;;
  watch)    bw_watch ;;
  *) echo "استفاده: $0 {setup | add [NAME PORT PUBKEY] | del NAME | bw NAME [UP DOWN]}" >&2; exit 1 ;;
esac
