#!/usr/bin/env bash
# ------------------------------------------------------------------
# INSTALL (once; does NOT create a server, it only installs the Docker-ssh-cs command):
#   sudo bash docker.sh
#
# After install:
#   Docker-ssh-cs cr                      create a server (asks RAM / disk / CPU / name)
#   Docker-ssh-cs cr -y                   create a server with defaults, no questions
#   Docker-ssh-cs cr NAME                 create a server with a custom name
#   Docker-ssh-cs cr NAME PORT PUB_FILE   create with custom name, port and public key file
#   Docker-ssh-cs de NAME                 delete a server
#   Docker-ssh-cs info NAME               info of one server (sshx link, CPU, name, port ...)
#   Docker-ssh-cs all info                info of all servers
#   Docker-ssh-cs bw NAME UP DOWN         change bandwidth (off = unlimited)
#   Docker-ssh-cs bw NAME                 show current bandwidth
# ------------------------------------------------------------------
set -euo pipefail

# ================== DEFAULTS (shown as [default] in the questions) ==================
RAM="${RAM:-256m}"                 # e.g. 100m, 256m, 1g
CPU_CORES="${CPU_CORES:-1}"        # number of cores
CPU_PERCENT="${CPU_PERCENT:-20}"   # percent of those cores
DISK="${DISK:-2G}"                 # e.g. 500M, 1G (empty = unlimited)
                                   # if overlay2+xfs+pquota is available, Docker quota is used,
                                   # otherwise a loop disk (ext4) of this size is mounted on /root
PIDS="${PIDS:-100}"                # max processes per container
SUBNET="${SUBNET:-172.30.0.0/24}"  # network subnet (change if it conflicts)
PURGE="${PURGE:-1}"                # for "de": 1 = also delete volume/disk (default), 0 = keep
BW_UP="${BW_UP:-45mbit}"           # upload cap (container egress)    e.g. 512kbit, 10mbit, 1gbit ; off = unlimited
BW_DOWN="${BW_DOWN:-50mbit}"       # download cap (container ingress) e.g. 512kbit, 10mbit, 1gbit ; off = unlimited
# ====================================================================================

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
DISKDIR=/var/lib/vps-box/disks     # loop disk image files
LOOPMNT=/var/lib/vps-box/mnt       # loop disk mount points
QUOTA_OK=""
PUBIP=""
ASK_REPLY=""

die()  { echo "[ERROR] $*" >&2; exit 1; }
warn() { echo "[WARN] $*" >&2; }
ipt()  { iptables -w "$@"; }
has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

[ "$(uname -s)" = "Linux" ] || die "Linux only"

# not root -> re-run with sudo automatically
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "You must be root (run with sudo)"
  exec sudo -E bash "$(readlink -f "$0" 2>/dev/null || echo "$0")" "$@"
fi

# ---------- package manager detection ----------
if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v yum     >/dev/null; then PM=yum
else PM=none; fi

pm_install() {
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    *)   die "Unsupported package manager; install these manually: $*" ;;
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
      die "This VPS is of type '$v' and usually cannot run Docker (userns/cgroup). Use a KVM VPS." ;;
  esac
}

# ---------- size helpers ----------
# "100MB" -> "100m", "1GB" -> "1g", "512m" -> "512m", "100" -> "100m" (plain number = MB)
norm_size() {
  local s=${1,,} n u b
  s=${s// /}
  [[ "$s" =~ ^([0-9]+)([kmgt])?(i?b)?$ ]] || return 1
  n=${BASH_REMATCH[1]}
  u=${BASH_REMATCH[2]}
  b=${BASH_REMATCH[3]}
  [ -z "$u" ] && [ -n "$b" ] && return 1     # bytes ("100b") not supported
  u=${u:-m}
  n=$((10#$n))
  [ "$n" -ge 1 ] || return 1
  echo "$n$u"
}

# normalized size ("100m", "1g") -> integer MB
size_mb() {
  local v=$1 n u
  n=${v%?}
  u=${v: -1}
  case "$u" in
    k) echo $((n / 1024)) ;;
    m) echo "$n" ;;
    g) echo $((n * 1024)) ;;
    t) echo $((n * 1024 * 1024)) ;;
    *) echo 0 ;;
  esac
}

# "256m" -> "256MB" (for display)
show_size() {
  if [ -z "$1" ]; then echo "unlimited"; else echo "${1^^}B"; fi
}

validate_limits() {
  [[ "$RAM" =~ ^[1-9][0-9]*[kmgKMG]$ ]]               || die "Invalid RAM value: $RAM"
  [[ "$CPU_CORES" =~ ^[0-9]+(\.[0-9]+)?$ ]]           || die "Invalid CPU_CORES value: $CPU_CORES"
  [[ "$CPU_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]]         || die "Invalid CPU_PERCENT value: $CPU_PERCENT"
  [[ "$PIDS" =~ ^[1-9][0-9]*$ ]]                      || die "Invalid PIDS value: $PIDS"
  if [ -n "$DISK" ]; then
    [[ "$DISK" =~ ^[1-9][0-9]*[kKmMgGtT]$ ]]          || die "Invalid DISK value: $DISK"
  fi
}

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }

name_taken() {
  command -v docker >/dev/null 2>&1 && docker container inspect "$1" >/dev/null 2>&1
}

# container must exist and be created by this tool
check_owned() {
  local NAME=$1 lbl
  valid_name "$NAME" || die "Invalid name"
  command -v docker >/dev/null || die "Docker is not installed"
  lbl=$(docker container inspect -f "{{index .Config.Labels \"$LABEL\"}}" "$NAME" 2>/dev/null || true)
  [ "$lbl" = "1" ] || die "Server '$NAME' does not exist or was not created by $CMD"
}

# ---------- interactive questions ----------
# ask "Question" "default"  -> answer in ASK_REPLY (Enter = default; EOF = default)
ask() {
  local a=""
  read -r -p "$1 [$2]: " a || { echo; a=""; }
  ASK_REPLY=${a:-$2}
}

ask_ram() {
  local v mb
  while true; do
    ask "RAM (e.g. 100MB, 512MB, 1GB)" "$(show_size "$RAM")"
    if v=$(norm_size "$ASK_REPLY"); then
      mb=$(size_mb "$v")
      if [ "$mb" -lt 6 ]; then echo "  RAM must be at least 6MB."; continue; fi
      if [ "$mb" -lt 64 ]; then echo "  Note: below 64MB sshd/sshx may get killed (out of memory)."; fi
      RAM=$v
      return 0
    fi
    echo "  Invalid value. Examples: 100MB, 512MB, 1GB"
  done
}

ask_disk() {
  local v mb d
  d=$(show_size "$DISK")
  while true; do
    ask "Disk (e.g. 500MB, 1GB; 0 = unlimited)" "$d"
    case "${ASK_REPLY,,}" in
      0|none|unlimited|no) DISK=""; return 0 ;;
    esac
    if v=$(norm_size "$ASK_REPLY"); then
      mb=$(size_mb "$v")
      if [ "$mb" -lt 16 ]; then echo "  Disk must be at least 16MB."; continue; fi
      DISK=${v^^}
      return 0
    fi
    echo "  Invalid value. Examples: 500MB, 1GB, 0"
  done
}

ask_cores() {
  local max
  max=$(nproc 2>/dev/null || echo 1)
  while true; do
    ask "CPU cores (this server has $max)" "$CPU_CORES"
    if [[ "$ASK_REPLY" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       && awk -v c="$ASK_REPLY" -v n="$max" 'BEGIN{exit !(c>0 && c<=n)}'; then
      CPU_CORES=$ASK_REPLY
      return 0
    fi
    echo "  Invalid value. Enter a number between 0.01 and $max (e.g. 1)"
  done
}

ask_percent() {
  while true; do
    ask "How many percent of the CPU cores (1-100, e.g. 25)" "$CPU_PERCENT"
    ASK_REPLY=${ASK_REPLY%\%}
    if [[ "$ASK_REPLY" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       && awk -v p="$ASK_REPLY" 'BEGIN{exit !(p>=1 && p<=100)}'; then
      CPU_PERCENT=$ASK_REPLY
      return 0
    fi
    echo "  Invalid value. Enter a number between 1 and 100 (e.g. 25)"
  done
}

ask_name() {   # sets NAME_ANSWER ("" = random)
  NAME_ANSWER=""
  local a
  while true; do
    ask "Random name? (Y/N)" "Y"
    a=${ASK_REPLY,,}
    case "$a" in
      y|yes) return 0 ;;
      n|no)  break ;;
      *)     echo "  Answer Y or N" ;;
    esac
  done
  while true; do
    ask "Server name (a-z 0-9 _ - ; must start with a letter)" "myserver"
    if ! valid_name "$ASK_REPLY"; then
      echo "  Invalid name."
    elif name_taken "$ASK_REPLY"; then
      echo "  A server named '$ASK_REPLY' already exists."
    else
      NAME_ANSWER=$ASK_REPLY
      return 0
    fi
  done
}

# ---------- bandwidth limit (tc on the host-side veth) ----------
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

# burst (bytes) ~ 256ms of traffic, minimum 70000 bytes
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
  command -v tc >/dev/null || { warn "tc is not installed; bandwidth not limited"; return 1; }
  bw_conf_read "$name"
  v=$(veth_of "$name") || { warn "veth of container $name not found (is it running?)"; return 1; }

  modprobe sch_tbf 2>/dev/null || true
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_police 2>/dev/null || true

  # download (traffic to the container) = egress on veth -> shaping with tbf
  tc qdisc del dev "$v" root 2>/dev/null || true
  if ! is_off "$cur_down"; then
    b=$(burst_for "$cur_down")
    tc qdisc add dev "$v" root tbf rate "$cur_down" burst "$b" latency 400ms \
      || { warn "failed to apply download limit on $v"; return 1; }
  fi

  # upload (traffic from the container) = ingress on veth -> policing
  tc qdisc del dev "$v" ingress 2>/dev/null || true
  if ! is_off "$cur_up"; then
    b=$(burst_for "$cur_up")
    tc qdisc add dev "$v" handle ffff: ingress \
      && tc filter add dev "$v" parent ffff: protocol all prio 1 u32 match u32 0 0 \
           police rate "$cur_up" burst "$b" mtu 65535 drop flowid :1 \
      || { warn "failed to apply upload limit on $v"; return 1; }
  fi
  echo "[ok] bandwidth $name: upload=$cur_up download=$cur_down (on $v)"
}

bw_apply_all() {
  local n
  while read -r n; do
    [ -n "$n" ] || continue
    bw_apply "$n" || true
  done < <(docker ps --filter "label=$LABEL=1" --format '{{.Names}}')
}

bw_watch() {
  docker info >/dev/null 2>&1 || die "Docker is not running"
  local n
  ( sleep 3; bw_apply_all ) &
  while read -r n; do
    [ -n "$n" ] || continue
    sleep 1
    bw_apply "$n" || true
  done < <(docker events --filter type=container --filter event=start \
             --filter "label=$LABEL=1" --format '{{.Actor.Attributes.name}}')
  die "docker events stopped"
}

bw_cmd() {
  [ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die "Usage: $CMD bw NAME [UP DOWN]"
  local NAME=$1
  check_owned "$NAME"

  if [ "$#" -eq 1 ]; then
    bw_conf_read "$NAME"
    echo "$NAME: upload=$cur_up download=$cur_down"
    return 0
  fi
  valid_rate "$2" || die "Invalid UP value (examples: 512kbit, 10mbit, off)"
  valid_rate "$3" || die "Invalid DOWN value (examples: 512kbit, 10mbit, off)"
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
    echo "[install] ${pk[*]}"
    if [ "$PM" = apt ]; then apt-get update -y; fi
    pm_install "${pk[@]}"
  fi
}

install_docker() {
  if ! command -v docker >/dev/null; then
    echo "[install] docker (official get.docker.com script)"
    if ! curl -fsSL https://get.docker.com | sh; then
      warn "Official script failed; trying the distro package"
      if [ "$PM" = apt ]; then pm_install docker.io; else pm_install docker; fi
    fi
  fi
  if has_systemd; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
  wait_docker || die "Docker is not running: journalctl -u docker"
}

get_subnet() {
  local s=""
  s=$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
      | awk '{print $1}') || true
  echo "${s:-$SUBNET}"
}

# Firewall: only blocks access to internal networks and SMTP spam.
firewall() {
  command -v iptables >/dev/null || die "iptables is not installed"
  docker info >/dev/null 2>&1   || die "Docker is not running"
  ipt -S DOCKER-USER >/dev/null 2>&1 \
    || die "DOCKER-USER chain not found (is Docker running with iptables=false?)"

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

# install this script as the Docker-ssh-cs command (and docker-ssh-cs in lowercase)
install_self() {
  if [ -f "$0" ]; then
    if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF" 2>/dev/null || echo "$SELF")" ]; then
      install -m 755 "$0" "$SELF"
    fi
    ln -sf "$SELF" "$ALIAS"
    rm -f "$OLDSELF"
  elif [ ! -x "$SELF" ]; then
    warn "Script was not run as a file; $CMD was not installed. Download the file first and run it with bash."
  fi
}

# firewall and bandwidth rules are re-applied after reboot and after Docker starts
persist_firewall() {
  if [ ! -x "$SELF" ]; then
    warn "Firewall will not be restored after reboot (script not installed)"
    return 0
  fi
  if ! has_systemd; then
    warn "No systemd; run this manually after reboot: $SELF firewall"
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
    || warn "vps-box-bw service did not start; bandwidth limits will not be restored after reboot (journalctl -u vps-box-bw)"
}

userns_active() {
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=userns'
}

enable_userns() {
  if userns_active; then
    echo "[ok] userns-remap is active"
    return 0
  fi
  if [ -n "$(docker ps -aq)" ] || [ -s /etc/docker/daemon.json ]; then
    warn "Containers or daemon.json already exist; add userns-remap manually:"
    echo '        "userns-remap": "default"  and  systemctl restart docker' >&2
    return 0
  fi
  mkdir -p /etc/docker
  echo '{ "userns-remap": "default" }' > /etc/docker/daemon.json
  if has_systemd; then systemctl restart docker; fi
  if ! wait_docker; then
    rm -f /etc/docker/daemon.json
    if has_systemd; then systemctl restart docker || true; fi
    die "Docker did not start with userns-remap; the setting was reverted"
  fi
  if userns_active; then
    echo "[ok] userns-remap enabled"
  else
    warn "userns-remap was not applied (may be incompatible with the current Docker image store)"
  fi
}

# ---------- disk limit ----------
# Does Docker quota (--storage-opt size) work here? (only overlay2 on xfs with pquota)
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

# create a loop disk (ext4) of size DISK and mount it on $LOOPMNT/NAME
make_loop_disk() {
  local name=$1 img mnt uid=0 gid=0
  img="$DISKDIR/$name.img"
  mnt="$LOOPMNT/$name"
  command -v mkfs.ext4 >/dev/null || install_deps
  command -v mkfs.ext4 >/dev/null || { warn "mkfs.ext4 is not installed"; return 1; }
  mkdir -p "$DISKDIR" "$mnt"
  [ ! -e "$img" ] || { warn "$img already exists"; return 1; }
  truncate -s "$DISK" "$img"                        || { warn "failed to create disk file (enough free space?)"; rm -f "$img"; return 1; }
  mkfs.ext4 -q -F -m 0 "$img" >/dev/null 2>&1       || { warn "mkfs.ext4 failed"; rm -f "$img"; return 1; }
  mount -o loop "$img" "$mnt"                       || { warn "loop mount failed (loop module?)"; rm -f "$img"; return 1; }
  if userns_active; then
    uid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subuid 2>/dev/null || true)
    gid=$(awk -F: '$1=="dockremap"{print $2; exit}' /etc/subgid 2>/dev/null || true)
    uid=${uid:-0}; gid=${gid:-0}
  fi
  chown "$uid:$gid" "$mnt"
  chmod 700 "$mnt"
  # mount again automatically after reboot
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

# prepare Docker / image / network / firewall (does not create a server)
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
      || die "Network creation failed; $SUBNET probably conflicts with another network (change SUBNET)"
  fi

  install_self
  firewall
  persist_firewall
  echo "[ok] setup complete"
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
    PUBIP=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo "<VPS-IP>")
  fi
  echo "$PUBIP"
}

host_cpu_model() {
  local m=""
  m=$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)
  if [ -z "$m" ]; then
    m=$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  fi
  echo "${m:-unknown}"
}

# ---------- show info of one server ----------
info_one() {  # NAME [SSHX_TRIES]
  local name=$1 tries=${2:-3}
  local status port nano mem cpus ramv link key pubip cpumodel disk_txt used size
  local M_DISK="" M_MODE=""

  status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "?")
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
      disk_txt="${M_DISK:-?}B (loop disk on /root)"
      if mountpoint -q "$LOOPMNT/$name" 2>/dev/null; then
        read -r used size < <(df -h --output=used,size "$LOOPMNT/$name" 2>/dev/null | tail -n1) || true
        [ -z "${used:-}" ] || disk_txt="$disk_txt - used: $used of $size"
      fi ;;
    quota)  disk_txt="${M_DISK:-?}B (docker quota)" ;;
    *)      disk_txt="unlimited" ;;
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
  echo "Name      : $name"
  echo "Status    : $status"
  echo "SSH port  : ${port:-?}"
  echo "CPU       : $cpus core ($(awk -v c="$cpus" 'BEGIN{printf "%d", c*100}')% of one core) | host CPU: $cpumodel"
  echo "RAM       : ${ramv}MB"
  echo "Disk      : $disk_txt"
  echo "Bandwidth : upload=$cur_up download=$cur_down"
  echo "----------------------------------------------"
  echo "Connect with Docker (on this server):"
  echo "  docker exec -it $name bash"
  echo "Connect with SSH (open port ${port:-?} in the firewall / Security Group):"
  if [ -n "$key" ]; then
    echo "  ssh -i $key -p ${port:-PORT} root@$pubip"
  else
    echo "  ssh -p ${port:-PORT} root@$pubip"
  fi
  echo "sshx link:"
  if [ -n "$link" ]; then
    echo "  $link"
  else
    echo "  (not ready; try later: $CMD info $name)"
  fi
  echo "Delete this server:"
  echo "  $CMD de $name"
  echo "=============================================="
}

list_names() {
  docker ps -a --filter "label=$LABEL=1" --format '{{.Names}}' | sort
}

info_all() {
  command -v docker >/dev/null || die "Docker is not installed"
  docker info >/dev/null 2>&1 || die "Docker is not running"
  local n count=0
  while read -r n; do
    [ -n "$n" ] || continue
    count=$((count + 1))
    info_one "$n" 3
  done < <(list_names)
  if [ "$count" -eq 0 ]; then
    echo "No servers yet. Create one with: $CMD cr"
  else
    echo "Total servers: $count"
  fi
}

info_cmd() {
  if [ "$#" -eq 0 ]; then
    info_all
  elif [ "$#" -eq 1 ]; then
    check_owned "$1"
    info_one "$1" 5
  else
    die "Usage: $CMD info NAME"
  fi
}

# ---------- create a server ----------
cr() {
  local NAME="" PORT="" KEY="" PRIV="" GENKEY=0 INTERACTIVE=0
  if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; fi
  case "${1:-}" in
    -y|--yes) INTERACTIVE=0; shift ;;
  esac

  case "$#" in
    0) GENKEY=1 ;;
    1) NAME=$1; GENKEY=1 ;;
    3) NAME=$1; PORT=$2; KEY=$3 ;;
    *) die "Usage: $CMD cr [-y]   or   $CMD cr NAME   or   $CMD cr NAME PORT PUBKEY_FILE" ;;
  esac

  # normalize values coming from environment variables / defaults
  RAM=$(norm_size "$RAM") || die "Invalid RAM value: $RAM"
  if [ -n "$DISK" ]; then DISK=$(norm_size "$DISK") || die "Invalid DISK value: $DISK"; DISK=${DISK^^}; fi

  # ---- questions ----
  if [ "$INTERACTIVE" -eq 1 ]; then
    echo "Create a new server (press Enter to accept the value in [brackets])"
    ask_ram
    ask_disk
    ask_cores
    ask_percent
    if [ -z "$NAME" ]; then
      ask_name
      NAME=$NAME_ANSWER
    fi
    echo
  fi

  [ -n "$NAME" ] || NAME=$(rand_name)
  [ -n "$PORT" ] || PORT=$(rand_port) || die "No free port found"

  valid_name "$NAME" || die "Invalid name (only a-z 0-9 _ - ; must start with a letter)"
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "Invalid port"
  PORT=$((10#$PORT))
  { [ "$PORT" -gt 1024 ] && [ "$PORT" -le 65535 ]; } || die "Port must be between 1025 and 65535"
  validate_limits
  valid_rate "$BW_UP"   || die "Invalid BW_UP value: $BW_UP (examples: 512kbit, 10mbit, off)"
  valid_rate "$BW_DOWN" || die "Invalid BW_DOWN value: $BW_DOWN (examples: 512kbit, 10mbit, off)"

  # run setup automatically if it has not been done yet
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1 \
     || ! docker image inspect "$IMG" >/dev/null 2>&1 \
     || ! docker network inspect "$NET" >/dev/null 2>&1; then
    echo "[info] setup has not been done yet; running it now..."
    setup
  fi

  if docker container inspect "$NAME" >/dev/null 2>&1; then
    die "A container named $NAME already exists"
  fi
  if command -v ss >/dev/null 2>&1 && [ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]; then
    die "Port $PORT is already in use on this server"
  fi

  # ---- key ----
  if [ "$GENKEY" -eq 1 ]; then
    install_deps
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    PRIV="$KEYDIR/$NAME"
    [ ! -e "$PRIV" ] || die "Key $PRIV already exists"
    ssh-keygen -q -t ed25519 -N "" -C "$NAME" -f "$PRIV"
    KEY="$PRIV.pub"
  fi

  [ -f "$KEY" ] || die "Key file not found: $KEY"
  local n PUBKEY tmp
  n=$(grep -cv '^[[:space:]]*$' "$KEY" || true)
  if [ "$n" -ne 1 ]; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "The key file must contain exactly one line (one key)"
  fi
  PUBKEY=$(grep -v '^[[:space:]]*$' "$KEY" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  local keyre='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]'
  if ! [[ "$PUBKEY" =~ $keyre ]]; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "Not a valid public key (must start with ssh-ed25519, ssh-rsa, ...)"
  fi
  tmp=$(mktemp)
  printf '%s\n' "$PUBKEY" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "Invalid public key"
  fi
  rm -f "$tmp"

  local CPUS
  CPUS=$(awk -v c="$CPU_CORES" -v p="$CPU_PERCENT" 'BEGIN{printf "%.2f", c*p/100}')
  if ! awk -v x="$CPUS" 'BEGIN{exit !(x>=0.01)}'; then
    [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"
    die "CPU share is too small ($CPUS)"
  fi

  # ---- choose the disk limit method ----
  local DISKMODE=volume
  if [ -n "$DISK" ]; then
    if quota_supported; then DISKMODE=quota; else DISKMODE=loop; fi
  fi
  case "$DISKMODE" in
    quota)  echo "[info] RAM=$(show_size "$RAM") CPU=$CPUS core ($CPU_PERCENT% of $CPU_CORES) DISK=$(show_size "$DISK") (docker quota)" ;;
    loop)   echo "[info] RAM=$(show_size "$RAM") CPU=$CPUS core ($CPU_PERCENT% of $CPU_CORES) DISK=$(show_size "$DISK") (loop disk on /root)" ;;
    volume) echo "[info] RAM=$(show_size "$RAM") CPU=$CPUS core ($CPU_PERCENT% of $CPU_CORES) DISK=unlimited" ;;
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
        die "Loop disk creation failed"
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
    die "Container creation failed"
  fi

  mkdir -p "$META"
  printf 'M_DISK=%s\nM_MODE=%s\n' "${DISK:-}" "$DISKMODE" > "$META/$NAME"

  bw_conf_write "$NAME" "$BW_UP" "$BW_DOWN"
  sleep 1
  if ! bw_apply "$NAME"; then
    warn "Bandwidth limit was not applied; try again later: $CMD bw $NAME $BW_UP $BW_DOWN"
  fi

  info_one "$NAME" 25
}

# ---------- delete a server ----------
de() {
  [ "$#" -eq 1 ] || die "Usage: $CMD de NAME"
  local NAME=$1
  check_owned "$NAME"

  docker rm -f "$NAME" >/dev/null
  rm -f "$BWDIR/$NAME" "$META/$NAME" "$KEYDIR/$NAME" "$KEYDIR/$NAME.pub"
  echo "[ok] server $NAME deleted"

  if docker volume inspect "${NAME}_root" >/dev/null 2>&1; then
    if [ "$PURGE" = "1" ]; then
      docker volume rm "${NAME}_root" >/dev/null
      echo "[ok] volume deleted too"
    else
      echo "Volume kept. To remove it: docker volume rm ${NAME}_root  (or use PURGE=1)"
    fi
  fi

  if [ -f "$DISKDIR/$NAME.img" ]; then
    if [ "$PURGE" = "1" ]; then
      remove_loop_disk "$NAME"
      echo "[ok] loop disk deleted too"
    else
      echo "Disk $DISKDIR/$NAME.img kept (use PURGE=1 to delete it)"
    fi
  fi
}

usage() {
  cat <<EOF
Usage:
  $CMD cr                      create a server (asks RAM / disk / CPU / name)
  $CMD cr -y                   create a server with defaults, no questions
  $CMD cr NAME                 create a server with a custom name
  $CMD cr NAME PORT PUB_FILE   create with custom name, port and public key file
  $CMD de NAME                 delete a server
  $CMD info NAME               info of one server (sshx link, CPU, name, port ...)
  $CMD all info                info of all servers
  $CMD bw NAME [UP DOWN]       show / change bandwidth (off = unlimited)
Defaults can be changed with env vars, e.g.:  RAM=512m DISK=5G $CMD cr -y
EOF
}

case "${1:-}" in
  ""|setup|install)
    setup
    echo
    echo "The $CMD command is installed (no server was created). If it is not found in this terminal run: hash -r"
    echo
    usage
    ;;
  cr|add|create)    shift; cr "$@" ;;
  de|del|rm|delete) shift; de "$@" ;;
  info)             shift; info_cmd "$@" ;;
  all)              shift
                    case "${1:-info}" in
                      info) info_all ;;
                      *)    die "Usage: $CMD all info" ;;
                    esac ;;
  ls|list)          info_all ;;
  bw)               shift; bw_cmd "$@" ;;
  firewall)         firewall ;;
  watch)            bw_watch ;;
  help|-h|--help)   usage ;;
  *)                usage >&2; exit 1 ;;
esac
