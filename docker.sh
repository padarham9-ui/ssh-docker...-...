#!/usr/bin/env bash
# ------------------------------------------------------------------
# نصب (فقط یک‌بار؛ سرور نمی‌سازد، فقط دستور Docker-ssh-cs را نصب می‌کند):
#   sudo bash docker.sh
#
# بعد از نصب:
#   Docker-ssh-cs cr                      ساخت سرور (نام/پورت رندوم + کلید خودکار + لینک sshx)
#   Docker-ssh-cs cr NAME                 ساخت سرور با نام دلخواه
#   Docker-ssh-cs cr NAME PORT PUB_FILE   ساخت با نام، پورت و کلید عمومی دلخواه
#   Docker-ssh-cs de NAME                 حذف سرور
#   Docker-ssh-cs info NAME               اطلاعات یک سرور (لینک sshx، پردازنده، اسم، پورت و ...)
#   Docker-ssh-cs all info                اطلاعات همه سرورها
#   Docker-ssh-cs bw NAME UP DOWN         تغییر پهنای باند (off = نامحدود)
#   Docker-ssh-cs bw NAME                 نمایش پهنای باند فعلی
#   مثال با تنظیمات: RAM=512m DISK=5G Docker-ssh-cs cr
# ------------------------------------------------------------------
set -euo pipefail

# ================== تنظیمات (اینجا عوض کن) ==================
RAM="${RAM:-256m}"                 # مثال: 64m, 256m, 1g
CPU_CORES="${CPU_CORES:-1}"        # تعداد هسته
CPU_PERCENT="${CPU_PERCENT:-20}"   # درصد از آن هسته‌ها
DISK="${DISK:-2G}"                 # مثال: 20G (خالی = بدون محدودیت)
                                   # اگر overlay2+xfs+pquota باشد از quota داکر استفاده می‌شود،
                                   # وگرنه خودکار یک دیسک loop (ext4) با همین سایز برای /root ساخته می‌شود
PIDS="${PIDS:-100}"                # حداکثر تعداد پروسس برای هر کانتینر
SUBNET="${SUBNET:-172.30.0.0/24}"  # ساب‌نت شبکه (اگر با شبکه دیگری تداخل داشت عوض کن)
PURGE="${PURGE:-1}"                # برای de: 1 = ولوم/دیسک هم حذف شود (پیش‌فرض)، 0 = بماند
BW_UP="${BW_UP:-45mbit}"           # سقف آپلود (خروجی کانتینر)  مثال: 512kbit, 10mbit, 1gbit ; off = نامحدود
BW_DOWN="${BW_DOWN:-50mbit}"       # سقف دانلود (ورودی کانتینر) مثال: 512kbit, 10mbit, 1gbit ; off = نامحدود
# ============================================================

CMD=Docker-ssh-cs
DIR=/opt/vps-box
IMG=vps-box
NET=vps-net
LABEL=vps-box
SELF=/usr/local/bin/Docker-ssh-cs
ALIAS=/usr/local/bin/docker-ssh-cs
OLDSELF=/usr/local/sbin/vps-box.sh
BWDIR=/etc/vps-box/bw.d
META=/etc/vps-box/meta.d
KEYDIR=$DIR/keys
DISKDIR=/var/lib/vps-box/disks     # فایل‌های img دیسک loop
LOOPMNT=/var/lib/vps-box/mnt       # محل mount دیسک‌ها
QUOTA_OK=""
PUBIP=""

die()  { echo "[خطا] $*" >&2; exit 1; }
warn() { echo "[هشدار] $*" >&2; }
ipt()  { iptables -w "$@"; }
has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

[ "$(uname -s)" = "Linux" ] || die "فقط روی لینوکس کار می‌کند"

# اگر root نیست، خودکار با sudo دوباره اجرا شود
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "باید root باشی (با sudo اجرا کن)"
  exec sudo -E bash "$(readlink -f "$0" 2>/dev/null || echo "$0")" "$@"
fi

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

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }

# بررسی اینکه کانتینر وجود دارد و توسط همین ابزار ساخته شده
check_owned() {
  local NAME=$1 lbl
  valid_name "$NAME" || die "نام نامعتبر"
  command -v docker >/dev/null || die "داکر نصب نیست"
  lbl=$(docker container inspect -f "{{index .Config.Labels \"$LABEL\"}}" "$NAME" 2>/dev/null || true)
  [ "$lbl" = "1" ] || die "سروری با نام $NAME وجود ندارد یا توسط $CMD ساخته نشده"
}

# ---------- محدودیت پهنای باند (tc روی veth سمت هاست) ----------
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
burst_for() {
  local k b
  k=$(to_kbit "$1")
  b=$((k * 32))
  [ "$b" -ge 70000 ] || b=70000
  echo "$b"
}

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

bw_conf_read() {
  cur_up=off; cur_down=off
  local UP="" DOWN=""
  if [ -f "$BWDIR/$1" ]; then
    # shellcheck disable=SC1090
    . "$BWDIR/$1"
  fi
  [ -z "${UP:-}" ]   || cur_up=$UP
  [ -z "${DOWN:-}" ] || cur_down=$DOWN
}

bw_conf_write() {
  mkdir -p "$BWDIR"
  printf 'UP=%s\nDOWN=%s\n' "$2" "$3" > "$BWDIR/$1"
}

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

bw_watch() {
  docker info >/dev/null 2>&1 || die "داکر در حال اجرا نیست"
  local n
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
  [ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die "استفاده: $CMD bw NAME [UP DOWN]"
  local NAME=$1
  check_owned "$NAME"

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
  command -v mkfs.ext4  >/dev/null || pk+=(e2fsprogs)
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

# نصب خود اسکریپت به‌عنوان دستور Docker-ssh-cs (و docker-ssh-cs با حروف کوچک)
install_self() {
  if [ -f "$0" ]; then
    if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF" 2>/dev/null || echo "$SELF")" ]; then
      install -m 755 "$0" "$SELF"
    fi
    ln -sf "$SELF" "$ALIAS"
    rm -f "$OLDSELF"
  elif [ ! -x "$SELF" ]; then
    warn "اسکریپت به‌صورت فایل اجرا نشده؛ دستور $CMD نصب نشد. اول فایل را دانلود کن و با bash اجرا کن."
  fi
}

# قوانین فایروال و پهنای باند بعد از ریبوت و بعد از بالا آمدن داکر دوباره اعمال شوند
persist_firewall() {
  if [ ! -x "$SELF" ]; then
    warn "فایروال بعد از ریبوت خودکار برنمی‌گردد (اسکریپت نصب نشده)"
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

# ---------- محدودیت دیسک ----------
# آیا quota داکر (--storage-opt size) روی این سرور کار می‌کند؟ (فقط overlay2 روی xfs با pquota)
quota_supported() {
  if [ -z "$QUOTA_OK" ]; then
    if docker run --rm --storage-opt "size=$DISK" --entrypoint true "$IMG" >/dev/null 2>&1; then
      QUOTA_OK=1
    else
      QUOTA_OK=0
    fi
  fi
  [ "$QUOTA_OK" = 1 ]
}

# ساخت دیسک loop (ext4) با سایز DISK و mount روی $LOOPMNT/NAME
make_loop_disk() {
  local name=$1 img mnt uid=0 gid=0
  img="$DISKDIR/$name.img"
  mnt="$LOOPMNT/$name"
  command -v mkfs.ext4 >/dev/null || install_deps
  command -v mkfs.ext4 >/dev/null || { warn "mkfs.ext4 نصب نیست"; return 1; }
  mkdir -p "$DISKDIR" "$mnt"
  [ ! -e "$img" ] || { warn "فایل $img از قبل وجود دارد"; return 1; }
  truncate -s "$DISK" "$img"                        || { warn "ساخت فایل دیسک شکست خورد (فضای کافی؟)"; rm -f "$img"; return 1; }
  mkfs.ext4 -q -F -m 0 "$img" >/dev/null 2>&1       || { warn "mkfs.ext4 شکست خورد"; rm -f "$img"; return 1; }
  mount -o loop "$img" "$mnt"                       || { warn "mount دیسک loop شکست خورد (ماژول loop؟)"; rm -f "$img"; return 1; }
  if userns_active; then
    uid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subuid 2>/dev/null || true)
    gid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subgid 2>/dev/null || true)
    uid=${uid:-0}; gid=${gid:-0}
  fi
  chown "$uid:$gid" "$mnt"
  chmod 700 "$mnt"
  # بعد از ریبوت خودکار mount شود
  grep -qF "$img " /etc/fstab 2>/dev/null || echo "$img $mnt ext4 loop,nofail 0 0" >> /etc/fstab
  return 0
}

remove_loop_disk() {
  local name=$1 img mnt
  img="$DISKDIR/$name.img"
  mnt="$LOOPMNT/$name"
  if mountpoint -q "$mnt" 2>/dev/null; then
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  fi
  if [ -f /etc/fstab ]; then
    grep -vF "$img " /etc/fstab > /etc/fstab.vpsbox.tmp || true
    cat /etc/fstab.vpsbox.tmp > /etc/fstab
    rm -f /etc/fstab.vpsbox.tmp
  fi
  rm -f "$img"
  rmdir "$mnt" 2>/dev/null || true
}

# آماده‌سازی داکر/ایمیج/شبکه/فایروال (سرور نمی‌سازد)
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

  install_self
  firewall
  persist_firewall
  echo "[ok] setup کامل شد"
}

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

get_sshx_link() {  # NAME [TRIES]
  local name=$1 tries=${2:-25} i l=""
  for i in $(seq 1 "$tries"); do
    l=$(docker exec "$name" cat /tmp/sshx.log 2>/dev/null \
        | grep -Eo 'https://sshx\.io/s/[^[:space:][:cntrl:]]+' | head -n1 || true)
    if [ -n "$l" ]; then echo "$l"; return 0; fi
    sleep 1
  done
  return 1
}

get_pubip() {
  if [ -z "$PUBIP" ]; then
    PUBIP=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo "<IP-VPS>")
  fi
  echo "$PUBIP"
}

host_cpu_model() {
  local m=""
  m=$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)
  if [ -z "$m" ]; then
    m=$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  fi
  echo "${m:-نامشخص}"
}

# ---------- نمایش اطلاعات یک سرور ----------
info_one() {  # NAME [SSHX_TRIES]
  local name=$1 tries=${2:-3}
  local status port nano mem cpus ramv link key pubip cpumodel disk_txt used size
  local M_DISK="" M_MODE=""

  status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "؟")
  port=$(docker inspect -f '{{with index .HostConfig.PortBindings "2222/tcp"}}{{(index . 0).HostPort}}{{end}}' "$name" 2>/dev/null || true)
  nano=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
  cpus=$(awk -v n="${nano:-0}" 'BEGIN{printf "%.2f", n/1000000000}')
  ramv=$(awk -v m="${mem:-0}" 'BEGIN{printf "%d", m/1048576}')
  cpumodel=$(host_cpu_model)
  pubip=$(get_pubip)

  # shellcheck disable=SC1090
  [ -f "$META/$name" ] && . "$META/$name"
  case "${M_MODE:-}" in
    loop)
      disk_txt="${M_DISK:-?} (دیسک loop روی /root)"
      if mountpoint -q "$LOOPMNT/$name" 2>/dev/null; then
        read -r used size < <(df -h --output=used,size "$LOOPMNT/$name" 2>/dev/null | tail -n1) || true
        [ -z "${used:-}" ] || disk_txt="$disk_txt — مصرف: $used از $size"
      fi ;;
    quota)  disk_txt="${M_DISK:-?} (quota داکر)" ;;
    *)      disk_txt="نامحدود" ;;
  esac

  bw_conf_read "$name"

  key=""
  [ -f "$KEYDIR/$name" ] && key="$KEYDIR/$name"

  link=""
  if [ "$status" = "running" ]; then
    link=$(get_sshx_link "$name" "$tries" || true)
  fi

  echo
  echo "=============================================="
  echo "اسم         : $name"
  echo "وضعیت       : $status"
  echo "پورت SSH    : ${port:-؟}"
  echo "پردازنده    : $cpus هسته ($(awk -v c="$cpus" 'BEGIN{printf "%d", c*100}')% از یک هسته) | CPU سرور: $cpumodel"
  echo "رم          : ${ramv}MB"
  echo "دیسک        : $disk_txt"
  echo "پهنای باند  : آپلود=$cur_up دانلود=$cur_down"
  echo "----------------------------------------------"
  echo "اتصال با داکر (روی همین سرور):"
  echo "  docker exec -it $name bash"
  echo "اتصال با SSH (پورت ${port:-؟} را در فایروال/Security Group باز کن):"
  if [ -n "$key" ]; then
    echo "  ssh -i $key -p ${port:-PORT} root@$pubip"
  else
    echo "  ssh -p ${port:-PORT} root@$pubip"
  fi
  echo "لینک sshx:"
  if [ -n "$link" ]; then
    echo "  $link"
  else
    echo "  (آماده نیست؛ بعداً: $CMD info $name)"
  fi
  echo "حذف سرور:"
  echo "  $CMD de $name"
  echo "=============================================="
}

list_names() {
  docker ps -a --filter "label=$LABEL=1" --format '{{.Names}}' | sort
}

info_all() {
  command -v docker >/dev/null || die "داکر نصب نیست"
  docker info >/dev/null 2>&1 || die "داکر در حال اجرا نیست"
  local n count=0
  while read -r n; do
    [ -n "$n" ] || continue
    count=$((count + 1))
    info_one "$n" 3
  done < <(list_names)
  if [ "$count" -eq 0 ]; then
    echo "هیچ سروری وجود ندارد. با «$CMD cr» بساز."
  else
    echo "تعداد کل سرورها: $count"
  fi
}

info_cmd() {
  if [ "$#" -eq 0 ]; then
    info_all
  elif [ "$#" -eq 1 ]; then
    check_owned "$1"
    info_one "$1" 5
  else
    die "استفاده: $CMD info NAME"
  fi
}

# ---------- ساخت سرور ----------
cr() {
  local NAME PORT KEY="" PRIV="" GENKEY=0
  case "$#" in
    0) NAME=$(rand_name); PORT=$(rand_port) || die "پورت آزاد پیدا نشد"; GENKEY=1 ;;
    1) NAME=$1; PORT=$(rand_port) || die "پورت آزاد پیدا نشد"; GENKEY=1 ;;
    3) NAME=$1; PORT=$2; KEY=$3 ;;
    *) die "استفاده: $CMD cr   یا   $CMD cr NAME   یا   $CMD cr NAME PORT PUBKEY_FILE" ;;
  esac

  valid_name "$NAME" || die "نام نامعتبر (فقط a-z 0-9 _ - ، شروع با حرف)"
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "پورت نامعتبر"
  PORT=$((10#$PORT))
  { [ "$PORT" -gt 1024 ] && [ "$PORT" -le 65535 ]; } || die "پورت باید بین 1025 و 65535 باشد"
  validate_limits
  valid_rate "$BW_UP"   || die "مقدار BW_UP نامعتبر است: $BW_UP (مثال: 512kbit، 10mbit، off)"
  valid_rate "$BW_DOWN" || die "مقدار BW_DOWN نامعتبر است: $BW_DOWN (مثال: 512kbit، 10mbit، off)"

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

  # ---- کلید ----
  if [ "$GENKEY" -eq 1 ]; then
    install_deps
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    PRIV="$KEYDIR/$NAME"
    [ ! -e "$PRIV" ] || die "کلیدی با نام $PRIV از قبل وجود دارد"
    ssh-keygen -q -t ed25519 -N "" -C "$NAME" -f "$PRIV"
    KEY="$PRIV.pub"
  fi

  [ -f "$KEY" ] || die "فایل کلید پیدا نشد: $KEY"
  local n PUBKEY tmp
  n=$(grep -cv '^[[:space:]]*$' "$KEY" || true)
  if [ "$n" -ne 1 ]; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "فایل کلید باید دقیقاً یک خط (یک کلید) داشته باشد"
  fi
  PUBKEY=$(grep -v '^[[:space:]]*$' "$KEY" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  local keyre='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]'
  if ! [[ "$PUBKEY" =~ $keyre ]]; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "کلید عمومی معتبر نیست (باید با ssh-ed25519، ssh-rsa و... شروع شود)"
  fi
  tmp=$(mktemp)
  printf '%s\n' "$PUBKEY" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "کلید عمومی نامعتبر"
  fi
  rm -f "$tmp"

  local CPUS
  CPUS=$(awk -v c="$CPU_CORES" -v p="$CPU_PERCENT" 'BEGIN{printf "%.2f", c*p/100}')
  if ! awk -v x="$CPUS" 'BEGIN{exit !(x>=0.01)}'; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "سهم CPU خیلی کم است ($CPUS)"
  fi

  # ---- انتخاب روش محدودیت دیسک ----
  local DISKMODE=volume
  if [ -n "$DISK" ]; then
    if quota_supported; then DISKMODE=quota; else DISKMODE=loop; fi
  fi
  case "$DISKMODE" in
    quota)  echo "[info] RAM=$RAM CPU=$CPUS هسته ($CPU_PERCENT% از $CPU_CORES) DISK=$DISK (quota داکر)" ;;
    loop)   echo "[info] RAM=$RAM CPU=$CPUS هسته ($CPU_PERCENT% از $CPU_CORES) DISK=$DISK (دیسک loop برای /root)" ;;
    volume) echo "[info] RAM=$RAM CPU=$CPUS هسته ($CPU_PERCENT% از $CPU_CORES) DISK=نامحدود" ;;
  esac

  local created_vol=0 created_loop=0
  local args=(-d --name "$NAME" --hostname "$NAME" --label "$LABEL=1"
              --init --restart unless-stopped
              --network "$NET"
              -p "0.0.0.0:${PORT}:2222"
              -e "SSH_PUBKEY=$PUBKEY")

  case "$DISKMODE" in
    quota)
      args+=(--storage-opt "size=$DISK")
      ;;
    loop)
      if ! make_loop_disk "$NAME"; then
        [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
        die "ساخت دیسک loop شکست خورد"
      fi
      created_loop=1
      args+=(-v "$LOOPMNT/$NAME:/root")
      ;;
    volume)
      if ! docker volume inspect "${NAME}_root" >/dev/null 2>&1; then
        docker volume create --label "$LABEL=1" "${NAME}_root" >/dev/null
        created_vol=1
      fi
      args+=(-v "${NAME}_root:/root")
      ;;
  esac

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
    if [ "$created_loop" -eq 1 ]; then remove_loop_disk "$NAME"; fi
    if [ "$GENKEY" -eq 1 ]; then rm -f "$PRIV" "$PRIV.pub"; fi
    die "ساخت کانتینر شکست خورد"
  fi

  mkdir -p "$META"
  printf 'M_DISK=%s\nM_MODE=%s\n' "${DISK:-}" "$DISKMODE" > "$META/$NAME"

  bw_conf_write "$NAME" "$BW_UP" "$BW_DOWN"
  sleep 1
  if ! bw_apply "$NAME"; then
    warn "محدودیت پهنای باند اعمال نشد؛ بعداً دوباره امتحان کن: $CMD bw $NAME $BW_UP $BW_DOWN"
  fi

  info_one "$NAME" 25
}

# ---------- حذف سرور ----------
de() {
  [ "$#" -eq 1 ] || die "استفاده: $CMD de NAME"
  local NAME=$1
  check_owned "$NAME"

  docker rm -f "$NAME" >/dev/null
  rm -f "$BWDIR/$NAME" "$META/$NAME" "$KEYDIR/$NAME" "$KEYDIR/$NAME.pub"
  echo "[ok] سرور $NAME حذف شد"

  if docker volume inspect "${NAME}_root" >/dev/null 2>&1; then
    if [ "$PURGE" = "1" ]; then
      docker volume rm "${NAME}_root" >/dev/null
      echo "[ok] volume هم حذف شد"
    else
      echo "volume باقی ماند. حذف کامل: docker volume rm ${NAME}_root  (یا PURGE=1)"
    fi
  fi

  if [ -f "$DISKDIR/$NAME.img" ]; then
    if [ "$PURGE" = "1" ]; then
      remove_loop_disk "$NAME"
      echo "[ok] دیسک loop هم حذف شد"
    else
      echo "دیسک $DISKDIR/$NAME.img باقی ماند (PURGE=1 برای حذف)"
    fi
  fi
}

usage() {
  cat <<EOF
استفاده:
  $CMD cr                      ساخت سرور (نام و پورت رندوم + کلید خودکار + لینک sshx)
  $CMD cr NAME                 ساخت سرور با نام دلخواه
  $CMD cr NAME PORT PUB_FILE   ساخت با نام، پورت و کلید عمومی دلخواه
  $CMD de NAME                 حذف سرور
  $CMD info NAME               اطلاعات یک سرور (لینک sshx، پردازنده، اسم، پورت و ...)
  $CMD all info                اطلاعات همه سرورها
  $CMD bw NAME [UP DOWN]       نمایش/تغییر پهنای باند (off = نامحدود)
مثال با تنظیمات:  RAM=512m DISK=5G $CMD cr
EOF
}

case "${1:-}" in
  ""|setup|install)
    setup
    echo
    echo "دستور $CMD نصب شد (سروری ساخته نشد). اگر در همین ترمینال پیدا نشد: hash -r"
    echo
    usage
    ;;
  cr|add|create)   shift; cr "$@" ;;
  de|del|rm|delete) shift; de "$@" ;;
  info)            shift; info_cmd "$@" ;;
  all)             shift
                   case "${1:-info}" in
                     info) info_all ;;
                     *)    die "استفاده: $CMD all info" ;;
                   esac ;;
  ls|list)         info_all ;;
  bw)              shift; bw_cmd "$@" ;;
  firewall)        firewall ;;
  watch)           bw_watch ;;
  help|-h|--help)  usage ;;
  *)               usage >&2; exit 1 ;;
esac
