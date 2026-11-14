#!/usr/bin/env bash
# ------------------------------------------------------------------
# docker-cssh (VM edition): every server is a FULL, separate virtual machine (KVM + QEMU).
# Own kernel, own virtual disk, own virtual network card. Nothing is shared with the host
# except the CPU (through hardware virtualization).
#
# INSTALL (once; does NOT create a server, it only installs the docker-cssh command):
#   sudo bash vm.sh
# v4
# After install:
#   docker-cssh cr                      create a server (asks RAM / disk / CPU / bandwidth / name)
#   docker-cssh cr -y                   create a server with defaults, no questions
#   docker-cssh cr NAME                 create a server with a custom name
#   docker-cssh cr NAME PORT PUB_FILE   create with custom name, SSH port and public key file
#   docker-cssh de NAME                 delete a server
#   docker-cssh re NAME                 reinstall a server: fresh disk, ALL data wiped (-y = no confirmation)
#   docker-cssh start NAME / stop NAME  start / stop a server
#   docker-cssh info NAME               info of one server (sshx link, CPU, name, port ...)
#   docker-cssh all info                info of all servers
#   docker-cssh sec [NAME]              security report (which protections are active)
#   docker-cssh bw NAME UP DOWN         change bandwidth (off = unlimited)
#   docker-cssh bw NAME                 show current bandwidth
# ------------------------------------------------------------------
set -euo pipefail

# ================== DEFAULTS (shown as [default] in the questions) ==================
RAM="${RAM:-512m}"                 # e.g. 512m, 1g (this is the REAL memory of the VM, a hard cap)
CPU_CORES="${CPU_CORES:-1}"        # number of virtual cores of the VM
CPU_PERCENT="${CPU_PERCENT:-20}"   # percent of those cores the VM may really use (host cgroup quota)
DISK="${DISK:-10G}"                # virtual disk size (a hard cap; the file on the host grows only as used)
DISK_IOPS="${DISK_IOPS:-3000}"     # disk operations per second cap (0 = unlimited)
DISK_MBPS="${DISK_MBPS:-100}"      # disk throughput cap in MB/s (0 = unlimited)
SUBNET="${SUBNET:-172.30.0.0/24}"  # private network of the VMs; must be a /24 (change if it conflicts)
BW_UP="${BW_UP:-45mbit}"           # upload cap (VM -> internet)   e.g. 512kbit, 10mbit, 1gbit ; off = unlimited
BW_DOWN="${BW_DOWN:-50mbit}"       # download cap (internet -> VM) e.g. 512kbit, 10mbit, 1gbit ; off = unlimited

# ---- security policy (edit the lists, then run "sudo bash vm.sh" again to apply to the firewall) ----
# Outbound TCP ports that servers may NOT connect to (space separated; ranges like 6660:6669 work):
#   25/465/587 = SMTP spam, 23 = telnet, 135/139/445 = SMB, 3389 = RDP,
#   6660-6669 = IRC (botnets), 3333/4444/5555/7777/14444/45700 = common crypto-mining pool ports
BLOCK_TCP_PORTS="${BLOCK_TCP_PORTS:-25 465 587 23 135 139 445 3389 6660:6669 3333 4444 5555 7777 14444 45700}"
# Packages that "apt install" refuses inside NEW servers. NOTE: root inside a VM can undo this;
# it is only a speed bump. The real protection is the network firewall above.
BLOCKED_PKGS="${BLOCKED_PKGS:-nmap zmap masscan hping3 hydra hydra-gtk medusa ncrack patator john john-data hashcat aircrack-ng reaver mdk4 kismet sqlmap nikto metasploit-framework wireshark tshark tcpdump ettercap-text-only ettercap-graphical dsniff bettercap netdiscover arp-scan nbtscan onesixtyone slowhttptest thc-ssl-dos tor torsocks obfs4proxy transmission-cli transmission-daemon transmission-common qbittorrent qbittorrent-nox deluge deluged deluge-console rtorrent ktorrent amule-daemon mldonkey-server xmrig cpuminer cgminer bfgminer ethminer}"
# Which Ubuntu the VMs run (official Ubuntu cloud image, checksum verified). noble = 24.04 LTS.
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
# Host kernel hardening applied by setup. Format: key=value:max|min  (max = higher is stricter, min = lower is stricter).
# Values are only ever made STRICTER than what the host already has, never looser.
HOST_SYSCTLS="${HOST_SYSCTLS:-kernel.dmesg_restrict=1:max kernel.kptr_restrict=2:max kernel.unprivileged_bpf_disabled=1:max net.core.bpf_jit_harden=2:max kernel.yama.ptrace_scope=1:max kernel.perf_event_paranoid=3:max fs.suid_dumpable=0:min fs.protected_symlinks=1:max fs.protected_hardlinks=1:max kernel.randomize_va_space=2:max}"
# ====================================================================================

CMD=docker-cssh
SELF=/usr/local/bin/docker-cssh
ALIAS=/usr/local/bin/docker-cash   # same command, alternate spelling
OLDSELF=/usr/local/sbin/vps-box.sh
OLDCMDS="/usr/local/bin/Docker-ssh-cs /usr/local/bin/docker-ssh-cs"   # names used by earlier versions
STATE=/var/lib/vps-box
BASEDIR=$STATE/base                # shared read-only Ubuntu images
VMROOT=$STATE/vms                  # one private directory per VM (disk + seed)
CONFDIR=/etc/vps-box
CONF=$CONFDIR/host.conf            # detected QEMU settings
META=$CONFDIR/meta.d               # one settings file per VM
PUBDIR=$CONFDIR/pub.d              # the owner's public key per VM
BWDIR=$CONFDIR/bw.d                # bandwidth per VM
KEYDIR=$CONFDIR/keys               # generated private keys (root only)
LOCKFILE=/run/vps-box.lock
ASK_REPLY=""
PUBIP=""
QEMU_BIN=""
QEMU_SANDBOX=on
QEMU_CPU="host,-vmx,-svm"
KVM_GID=""
SANDBOX_OPTS="on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"
M_IDX=""; M_IP=""; M_PORT=""; M_MAC=""; M_RAM_MB=""; M_DISK=""; M_SMP=""; M_QUOTA=""; M_BASE=""; M_IOPS=""; M_MBPS=""
cur_up=off; cur_down=off

die()  { echo "[ERROR] $*" >&2; exit 1; }
warn() { echo "[WARN] $*" >&2; }
ipt()  { iptables -w "$@"; }
ip6t() { ip6tables -w "$@"; }
has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

[ "$(uname -s)" = "Linux" ] || die "Linux only"

# not root -> re-run with sudo automatically
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "You must be root (run with sudo)"
  exec sudo -E bash "$(readlink -f "$0" 2>/dev/null || echo "$0")" "$@"
fi

# only one mutating command at a time
take_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCKFILE"
  flock -w 300 9 || die "Another $CMD command is still running"
}

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

# ---------- checks ----------
check_virt() {
  local v=""
  command -v systemd-detect-virt >/dev/null && v=$(systemd-detect-virt 2>/dev/null || true)
  case "$v" in
    openvz|lxc|lxc-libvirt|proot|docker|podman)
      die "This machine is of type '$v' (a container) and cannot run KVM virtual machines. Use a KVM VPS or a bare-metal server." ;;
  esac
}

check_arch() {
  [ "$(uname -m)" = "x86_64" ] || die "This version supports x86_64 only (this machine is $(uname -m))"
}

check_kvm() {
  if [ ! -c /dev/kvm ]; then
    modprobe kvm 2>/dev/null || true
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
  fi
  [ -c /dev/kvm ] || die "/dev/kvm does not exist. Hardware virtualization is not available (on a VPS: ask the provider to enable nested virtualization)."
  local mode
  KVM_GID=$(stat -c %g /dev/kvm)
  mode=$(stat -c %a /dev/kvm)
  if [ "$KVM_GID" = 0 ] && [ $(( 8#$mode & 6 )) -ne 6 ]; then
    die "/dev/kvm belongs to root only (mode $mode); create a 'kvm' group for it or make it group/world accessible"
  fi
}

find_qemu() {
  local b
  for b in qemu-system-x86_64 /usr/libexec/qemu-kvm /usr/bin/qemu-kvm; do
    if command -v "$b" >/dev/null 2>&1; then command -v "$b"; return 0; fi
  done
  return 1
}

have_iso_tool() {
  command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1
}

load_conf() {
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
  fi
  if [ -z "$QEMU_BIN" ]; then QEMU_BIN=$(find_qemu || true); fi
  if [ -z "$KVM_GID" ] && [ -c /dev/kvm ]; then KVM_GID=$(stat -c %g /dev/kvm); fi
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
  if [ -z "$u" ] && [ -n "$b" ]; then return 1; fi     # bytes ("100b") not supported
  u=${u:-m}
  n=$((10#$n))
  [ "$n" -ge 1 ] || return 1
  echo "$n$u"
}

# normalized size ("100m", "1g") -> integer MB
size_mb() {
  local v=${1,,} n u
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

# "10Mbps" / "10mbit" / "10m" / "10" -> "10mbit" ; "512kbit" -> "512kbit" ; 0/off/none -> "off"
# (plain number = mbit. "MB" is rejected on purpose: megabytes vs megabits is a factor of 8)
norm_rate() {
  local s=${1,,} n u
  s=${s// /}
  case "$s" in
    0|off|none|unlimited|no) echo off; return 0 ;;
  esac
  [[ "$s" =~ ^([0-9]+)(([kmg])(bit|bps)?)?$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  u=${BASH_REMATCH[3]:-m}
  [ "$n" -ge 1 ] || return 1
  echo "${n}${u}bit"
}

validate_limits() {
  [[ "$RAM" =~ ^[1-9][0-9]*[kmgKMG]$ ]]               || die "Invalid RAM value: $RAM"
  [[ "$DISK" =~ ^[1-9][0-9]*[kKmMgGtT]$ ]]            || die "Invalid DISK value: $DISK"
  [[ "$CPU_CORES" =~ ^[0-9]+(\.[0-9]+)?$ ]]           || die "Invalid CPU_CORES value: $CPU_CORES"
  [[ "$CPU_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]]         || die "Invalid CPU_PERCENT value: $CPU_PERCENT"
  [[ "$DISK_IOPS" =~ ^[0-9]+$ ]]                      || die "Invalid DISK_IOPS value: $DISK_IOPS"
  [[ "$DISK_MBPS" =~ ^[0-9]+$ ]]                      || die "Invalid DISK_MBPS value: $DISK_MBPS"
}

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }

unit_of() { echo "vps-box-vm-$1.service"; }

vm_exists() { [ -f "$META/$1" ]; }

# VM must exist and be created by this tool
check_owned() {
  valid_name "$1" || die "Invalid name"
  vm_exists "$1" || die "Server '$1' does not exist"
}

# ---------- per-VM settings ----------
load_meta() {  # NAME -> sets M_* globals
  M_IDX=""; M_IP=""; M_PORT=""; M_MAC=""; M_RAM_MB=""; M_DISK=""; M_SMP=""; M_QUOTA=""; M_BASE=""; M_IOPS=""; M_MBPS=""
  [ -f "$META/$1" ] || return 1
  # shellcheck disable=SC1090
  . "$META/$1"
}

save_meta() {  # NAME (uses M_* globals)
  mkdir -p "$META"
  {
    printf 'M_IDX=%s\n' "$M_IDX"
    printf 'M_IP=%s\n' "$M_IP"
    printf 'M_PORT=%s\n' "$M_PORT"
    printf 'M_MAC=%s\n' "$M_MAC"
    printf 'M_RAM_MB=%s\n' "$M_RAM_MB"
    printf 'M_DISK=%s\n' "$M_DISK"
    printf 'M_SMP=%s\n' "$M_SMP"
    printf 'M_QUOTA=%s\n' "$M_QUOTA"
    printf 'M_BASE=%s\n' "$M_BASE"
    printf 'M_IOPS=%s\n' "$M_IOPS"
    printf 'M_MBPS=%s\n' "$M_MBPS"
  } > "$META/$1"
  chmod 600 "$META/$1"
}

list_names() {
  local f
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    echo "${f##*/}"
  done | sort
}

# ---------- network plan ----------
check_subnet() {
  [[ "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]] || die "SUBNET must look like 172.30.0.0/24 (a /24 ending in .0)"
}
subnet_prefix() { local s=${SUBNET%/*}; echo "${s%.*}"; }
gw_ip()         { echo "$(subnet_prefix).1"; }

alloc_idx() {
  local i used=" " f v
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    v=$(sed -n 's/^M_IDX=//p' "$f")
    used+="$v "
  done
  for i in $(seq 10 250); do
    case "$used" in
      *" $i "*) ;;
      *) echo "$i"; return 0 ;;
    esac
  done
  return 1
}

port_used_by_vm() {  # PORT
  local f
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 's/^M_PORT=//p' "$f")" = "$1" ]; then return 0; fi
  done
  return 1
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
    ask "RAM (e.g. 512MB, 1GB, 2GB)" "$(show_size "$RAM")"
    if v=$(norm_size "$ASK_REPLY"); then
      mb=$(size_mb "$v")
      if [ "$mb" -lt 128 ]; then echo "  RAM must be at least 128MB."; continue; fi
      if [ "$mb" -lt 512 ]; then echo "  Note: below 512MB Ubuntu will be slow and may run out of memory."; fi
      RAM=$v
      return 0
    fi
    echo "  Invalid value. Examples: 512MB, 1GB, 2GB"
  done
}

ask_disk() {
  local v mb min
  min=$(base_min_disk_mb)
  while true; do
    ask "Disk (e.g. 10GB, 20GB; at least $(( (min + 1023) / 1024 ))GB)" "$(show_size "$DISK")"
    if v=$(norm_size "$ASK_REPLY"); then
      mb=$(size_mb "$v")
      if [ "$mb" -lt "$min" ]; then echo "  The Ubuntu image itself needs ${min}MB; choose a larger disk."; continue; fi
      DISK=${v^^}
      return 0
    fi
    echo "  Invalid value. Examples: 10GB, 20GB"
  done
}

ask_cores() {
  local max
  max=$(nproc 2>/dev/null || echo 1)
  while true; do
    ask "CPU cores (this host has $max)" "$CPU_CORES"
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

ask_rate() {   # ask_rate "Question" VARNAME   (sets the variable named VARNAME)
  local v
  while true; do
    ask "$1 (e.g. 10mbit, 512kbit, 1gbit; 0 = unlimited)" "${!2}"
    if v=$(norm_rate "$ASK_REPLY"); then
      printf -v "$2" '%s' "$v"
      return 0
    fi
    echo "  Invalid value. Examples: 10mbit, 512kbit, 1gbit, 0  (use bits, not bytes)"
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
    elif vm_exists "$ASK_REPLY"; then
      echo "  A server named '$ASK_REPLY' already exists."
    else
      NAME_ANSWER=$ASK_REPLY
      return 0
    fi
  done
}

# ---------- bandwidth limit (tc on the VM's tap device) ----------
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
  local name=$1 tap b
  command -v tc >/dev/null || { warn "tc is not installed; bandwidth not limited"; return 1; }
  load_meta "$name" || { warn "unknown server $name"; return 1; }
  bw_conf_read "$name"
  tap="vbt$M_IDX"
  ip link show "$tap" >/dev/null 2>&1 || { warn "network device $tap of $name not found (is the server running?)"; return 1; }

  modprobe sch_tbf 2>/dev/null || true
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_police 2>/dev/null || true

  # download (traffic to the VM) = egress on the tap -> shaping with tbf
  tc qdisc del dev "$tap" root 2>/dev/null || true
  if ! is_off "$cur_down"; then
    b=$(burst_for "$cur_down")
    tc qdisc add dev "$tap" root tbf rate "$cur_down" burst "$b" latency 400ms \
      || { warn "failed to apply download limit on $tap"; return 1; }
  fi

  # upload (traffic from the VM) = ingress on the tap -> policing
  tc qdisc del dev "$tap" ingress 2>/dev/null || true
  if ! is_off "$cur_up"; then
    b=$(burst_for "$cur_up")
    tc qdisc add dev "$tap" handle ffff: ingress \
      && tc filter add dev "$tap" parent ffff: protocol all prio 1 u32 match u32 0 0 \
           police rate "$cur_up" burst "$b" mtu 65535 drop flowid :1 \
      || { warn "failed to apply upload limit on $tap"; return 1; }
  fi
  echo "[ok] bandwidth $name: upload=$cur_up download=$cur_down (on $tap)"
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
  local UPV DOWNV
  UPV=$(norm_rate "$2")   || die "Invalid UP value (examples: 10mbit, 512kbit, off)"
  DOWNV=$(norm_rate "$3") || die "Invalid DOWN value (examples: 10mbit, 512kbit, off)"
  bw_conf_write "$NAME" "$UPV" "$DOWNV"
  bw_apply "$NAME"
}

# ---------- host preparation ----------
install_deps() {
  local pk=()
  command -v curl       >/dev/null || pk+=(curl)
  command -v awk        >/dev/null || pk+=(gawk)
  command -v iptables   >/dev/null || pk+=(iptables)
  command -v flock      >/dev/null || pk+=(util-linux)
  command -v sha256sum  >/dev/null || pk+=(coreutils)
  if ! command -v tc >/dev/null || ! command -v ip >/dev/null || ! command -v ss >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(iproute2); else pk+=(iproute iproute-tc); fi
  fi
  if ! command -v ssh-keygen >/dev/null || ! command -v ssh >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(openssh-client); else pk+=(openssh-clients); fi
  fi
  if ! find_qemu >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(qemu-system-x86); else pk+=(qemu-kvm); fi
  fi
  if ! command -v qemu-img >/dev/null; then
    if [ "$PM" = apt ]; then pk+=(qemu-utils); else pk+=(qemu-img); fi
  fi
  if ! have_iso_tool; then
    if [ "$PM" = apt ]; then pk+=(genisoimage); else pk+=(xorriso); fi
  fi
  [ -d /etc/ssl/certs ] || pk+=(ca-certificates)
  if [ "${#pk[@]}" -gt 0 ]; then
    echo "[install] ${pk[*]}"
    if [ "$PM" = apt ]; then apt-get update -y; fi
    pm_install "${pk[@]}"
  fi
  command -v useradd >/dev/null || die "useradd not found (install the 'passwd' / 'shadow-utils' package)"
}

# IPv4 DNS servers the host itself uses (the real upstream resolvers, not 127.0.0.x stubs)
dns_upstreams() {
  local f
  for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    [ -r "$f" ] || continue
    awk '$1 == "nameserver" {print $2}' "$f"
  done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^127\.' | sort -u
}

# DNS servers given to every VM (max 3): up to 2 host upstreams + public fallbacks.
dns_list() {
  local out="" c=0 ip
  for ip in $(dns_upstreams || true); do
    [ "$c" -lt 2 ] || break
    out+="$ip "
    c=$((c + 1))
  done
  for ip in 1.1.1.1 8.8.8.8; do
    [ "$c" -lt 3 ] || break
    out+="$ip "
    c=$((c + 1))
  done
  echo "${out% }"
}

# Make the host kernel stricter. Only raises values; every key is skipped if the kernel lacks it.
harden_host() {
  local item key rest want dir path val lines="" conf=/etc/sysctl.d/99-vps-box.conf
  for item in $HOST_SYSCTLS; do
    key=${item%%=*}; rest=${item#*=}; want=${rest%%:*}; dir=${rest##*:}
    path="/proc/sys/${key//.//}"
    [ -r "$path" ] || continue
    val=$(cat "$path" 2>/dev/null || true)
    [[ "$val" =~ ^-?[0-9]+$ ]] || continue
    if [ "$dir" = max ]; then
      [ "$val" -lt "$want" ] || continue
    else
      [ "$val" -gt "$want" ] || continue
    fi
    if sysctl -q -w "$key=$want" >/dev/null 2>&1; then
      lines+="$key = $want"$'\n'
    else
      warn "could not set $key=$want (kernel refused); skipped"
    fi
  done
  if [ -n "$lines" ]; then
    printf '# vps-box host hardening (applied at boot by systemd-sysctl)\n%s' "$lines" > "$conf"
    echo "[ok] host kernel hardening applied: $(printf '%s' "$lines" | wc -l) setting(s) made stricter"
  else
    echo "[ok] host kernel hardening: nothing to change (already at least as strict)"
  fi
}

# how many of HOST_SYSCTLS are satisfied: prints "OK_COUNT TOTAL" (keys the kernel lacks are not counted)
host_sysctl_status() {
  local item key rest want dir path val ok=0 total=0
  for item in $HOST_SYSCTLS; do
    key=${item%%=*}; rest=${item#*=}; want=${rest%%:*}; dir=${rest##*:}
    path="/proc/sys/${key//.//}"
    [ -r "$path" ] || continue
    val=$(cat "$path" 2>/dev/null || true)
    [[ "$val" =~ ^-?[0-9]+$ ]] || continue
    total=$((total + 1))
    if [ "$dir" = max ]; then
      if [ "$val" -ge "$want" ]; then ok=$((ok + 1)); fi
    else
      if [ "$val" -le "$want" ]; then ok=$((ok + 1)); fi
    fi
  done
  echo "$ok $total"
}

net_sysctl() {
  modprobe tun 2>/dev/null || true
  printf '# vps-box: VMs are routed through the host\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/98-vps-box-net.conf
  sysctl -q -w net.ipv4.ip_forward=1 >/dev/null || die "Could not enable IPv4 forwarding"
}

# ---------- Ubuntu base image ----------
base_current() {
  local f=""
  [ -f "$BASEDIR/CURRENT" ] && f=$(cat "$BASEDIR/CURRENT")
  [ -n "$f" ] && [ -f "$f" ] || return 1
  echo "$f"
}

# virtual size of an image in MB (rounded up)
image_vsize_mb() {
  local b
  b=$(qemu-img info --output=json "$1" 2>/dev/null | grep -o '"virtual-size": *[0-9]*' | grep -o '[0-9]*$') || return 1
  [ -n "$b" ] || return 1
  echo $(( (b + 1048575) / 1048576 ))
}

# smallest disk a VM can have (the size of the image, +1GB of room)
base_min_disk_mb() {
  local f mb
  f=$(base_current) || { echo 4096; return 0; }
  mb=$(image_vsize_mb "$f") || { echo 4096; return 0; }
  echo $(( mb + 512 ))
}

download_base() {
  local url file sums hash dest tmp
  file="${UBUNTU_RELEASE}-server-cloudimg-amd64.img"
  url="https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/current"
  mkdir -p "$BASEDIR"
  echo "[info] checking the newest Ubuntu ${UBUNTU_RELEASE} cloud image"
  sums=$(curl -fsSL --max-time 60 "$url/SHA256SUMS") || die "Could not download $url/SHA256SUMS (is UBUNTU_RELEASE=$UBUNTU_RELEASE correct?)"
  hash=$(awk -v f="*$file" '$2 == f {print $1; exit}' <<<"$sums")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "Could not find $file in SHA256SUMS"
  dest="$BASEDIR/ubuntu-${UBUNTU_RELEASE}-${hash:0:12}.img"
  if [ ! -f "$dest" ]; then
    tmp="$BASEDIR/.download.$$"
    echo "[install] downloading $file (about 600MB)"
    if ! curl -fL --retry 3 -o "$tmp" "$url/$file"; then
      rm -f "$tmp"
      die "Image download failed"
    fi
    if ! echo "$hash  $tmp" | sha256sum -c --status; then
      rm -f "$tmp"
      die "Image checksum mismatch; refusing to use it"
    fi
    qemu-img info "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "Downloaded image is not valid"; }
    chmod 644 "$tmp"
    mv "$tmp" "$dest"
  fi
  echo "$dest" > "$BASEDIR/CURRENT"
  echo "[ok] base image: $dest"
}

# remove old base images that no VM uses any more
gc_bases() {
  local f cur used
  cur=$(base_current 2>/dev/null || true)
  for f in "$BASEDIR"/ubuntu-*.img; do
    [ -f "$f" ] || continue
    [ "$f" != "$cur" ] || continue
    used=0
    if grep -qsl "^M_BASE=$f\$" "$META"/* 2>/dev/null; then used=1; fi
    if [ "$used" -eq 0 ]; then rm -f "$f"; echo "[info] removed unused old base image $f"; fi
  done
}

# ---------- QEMU self test ----------
qmp_try() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' | timeout 30 "$QEMU_BIN" "$@" 2>&1
}

# Starts a paused 64MB VM (never runs a guest) to prove KVM, CPU flags and the seccomp sandbox work.
qemu_smoke() {
  [ -n "$QEMU_BIN" ] || die "qemu-system-x86_64 not found"
  local out base
  base=(-machine q35,accel=kvm -m 64 -nodefaults -no-user-config -display none -vga none -S -monitor none -serial none -qmp stdio)
  if out=$(qmp_try "${base[@]}" -cpu host,-vmx,-svm) && [[ "$out" == *QMP* ]]; then
    QEMU_CPU="host,-vmx,-svm"
  elif out=$(qmp_try "${base[@]}" -cpu host) && [[ "$out" == *QMP* ]]; then
    QEMU_CPU="host"
    warn "this QEMU cannot hide the virtualization flags; guests could run nested VMs"
  else
    echo "$out" >&2
    die "QEMU with KVM does not start (see the message above)"
  fi
  if out=$(qmp_try "${base[@]}" -cpu "$QEMU_CPU" -sandbox "$SANDBOX_OPTS") && [[ "$out" == *QMP* ]]; then
    QEMU_SANDBOX=on
    echo "[ok] QEMU test passed (KVM, seccomp sandbox on, nested virtualization hidden from guests)"
  else
    QEMU_SANDBOX=off
    warn "QEMU seccomp sandbox does not work on this host; VMs will run without it (the other protections stay)"
  fi
  mkdir -p "$CONFDIR"
  {
    echo "# written by setup"
    printf 'QEMU_BIN=%s\n' "$QEMU_BIN"
    printf 'QEMU_CPU=%s\n' "$QEMU_CPU"
    printf 'QEMU_SANDBOX=%s\n' "$QEMU_SANDBOX"
  } > "$CONF"
}

# ---------- firewall ----------
# VMs are routed (one tap device each, no bridge). Rules: VMs cannot reach the host, each other,
# private networks or the cloud metadata service; they cannot spoof addresses; abuse ports are blocked.
# The rules are rebuilt from the saved VM settings every time (idempotent).
firewall() {
  command -v iptables >/dev/null || die "iptables is not installed"
  check_subnet
  local SUB f name r p ups ip
  SUB="$(subnet_prefix).0/24"

  modprobe xt_conntrack 2>/dev/null || true

  # --- NAT: internet access for VMs and the SSH port forwards ---
  ipt -t nat -N VPSNAT 2>/dev/null || ipt -t nat -F VPSNAT
  ipt -t nat -N VPSDNAT 2>/dev/null || ipt -t nat -F VPSDNAT
  ipt -t nat -A VPSNAT -s "$SUB" ! -d "$SUB" -j MASQUERADE
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    load_meta "$name" || continue
    ipt -t nat -A VPSDNAT ! -i 'vbt+' -p tcp --dport "$M_PORT" -j DNAT --to-destination "$M_IP:22"
  done
  ipt -t nat -C POSTROUTING -j VPSNAT 2>/dev/null || ipt -t nat -I POSTROUTING -j VPSNAT
  ipt -t nat -C PREROUTING -j VPSDNAT 2>/dev/null || ipt -t nat -I PREROUTING -j VPSDNAT

  # --- filter: traffic coming FROM VMs ---
  ipt -N VPSOUT 2>/dev/null || ipt -F VPSOUT
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    load_meta "$name" || continue
    ipt -A VPSOUT -i "vbt$M_IDX" ! -s "$M_IP" -j DROP        # no address spoofing
  done
  ipt -A VPSOUT -o 'vbt+' -j DROP                            # VM -> VM is never allowed
  ipt -A VPSOUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # DNS: only the host's own resolvers may be reached inside the private ranges (public DNS is always fine).
  ups=$(dns_upstreams || true)
  if [ -n "$ups" ]; then
    for ip in $ups; do
      ipt -A VPSOUT -d "$ip" -p udp --dport 53 -j ACCEPT
      ipt -A VPSOUT -d "$ip" -p tcp --dport 53 -j ACCEPT
    done
  else
    warn "no DNS resolver detected on the host; allowing DNS to any address"
    ipt -A VPSOUT -p udp --dport 53 -j ACCEPT
    ipt -A VPSOUT -p tcp --dport 53 -j ACCEPT
  fi
  for r in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
           172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
    ipt -A VPSOUT -d "$r" -j DROP
  done
  for p in $BLOCK_TCP_PORTS; do
    [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]] || { warn "ignoring invalid port in BLOCK_TCP_PORTS: $p"; continue; }
    ipt -A VPSOUT -p tcp --dport "$p" -j DROP
  done
  ipt -A VPSOUT -j ACCEPT

  # --- filter: traffic going TO VMs (only replies and the SSH forwards) ---
  ipt -N VPSIN 2>/dev/null || ipt -F VPSIN
  ipt -A VPSIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  for f in "$META"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    load_meta "$name" || continue
    ipt -A VPSIN ! -i 'vbt+' -d "$M_IP" -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
  done
  ipt -A VPSIN -j DROP

  # hooks (removed and re-added so the order is always: VPSOUT first, then VPSIN)
  while ipt -D FORWARD -i 'vbt+' -j VPSOUT 2>/dev/null; do :; done
  while ipt -D FORWARD -o 'vbt+' -j VPSIN 2>/dev/null; do :; done
  ipt -I FORWARD -o 'vbt+' -j VPSIN
  ipt -I FORWARD -i 'vbt+' -j VPSOUT
  # VMs cannot open new connections to the host itself
  while ipt -D INPUT -i 'vbt+' -m conntrack --ctstate NEW -j DROP 2>/dev/null; do :; done
  ipt -I INPUT -i 'vbt+' -m conntrack --ctstate NEW -j DROP

  # IPv6 is not given to VMs: drop anything they try over IPv6
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6t -D INPUT -i 'vbt+' -j DROP 2>/dev/null; do :; done
    while ip6t -D FORWARD -i 'vbt+' -j DROP 2>/dev/null; do :; done
    while ip6t -D FORWARD -o 'vbt+' -j DROP 2>/dev/null; do :; done
    ip6t -I INPUT -i 'vbt+' -j DROP 2>/dev/null || true
    ip6t -I FORWARD -i 'vbt+' -j DROP 2>/dev/null || true
    ip6t -I FORWARD -o 'vbt+' -j DROP 2>/dev/null || true
  fi
}

# install this script as the docker-cssh command (and docker-cash as an alias)
install_self() {
  if [ -f "$0" ]; then
    if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF" 2>/dev/null || echo "$SELF")" ]; then
      install -m 755 "$0" "$SELF"
    fi
    ln -sf "$SELF" "$ALIAS"
    # remove the commands of earlier versions
    # shellcheck disable=SC2086
    rm -f "$OLDSELF" $OLDCMDS
  elif [ ! -x "$SELF" ]; then
    warn "Script was not run as a file; $CMD was not installed. Download the file first and run it with bash."
  fi
}

# firewall rules are re-applied after reboot
persist_firewall() {
  if [ ! -x "$SELF" ]; then
    warn "Firewall will not be restored after reboot (script not installed)"
    return 0
  fi
  if ! has_systemd; then
    die "systemd is required (every VM is a systemd service)"
  fi
  cat > /etc/systemd/system/vps-box-fw.service <<EOF
[Unit]
Description=vps-box firewall rules
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF firewall

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vps-box-fw.service >/dev/null 2>&1 || true
  systemctl restart vps-box-fw.service >/dev/null 2>&1 \
    || warn "vps-box-fw service did not start (journalctl -u vps-box-fw)"
}

# prepare host / image / firewall (does not create a server)
setup() {
  check_virt
  check_arch
  has_systemd || die "systemd is required (every VM is a systemd service)"
  check_subnet
  check_kvm
  install_deps
  load_conf
  mkdir -p "$STATE" "$BASEDIR" "$VMROOT" "$CONFDIR" "$META" "$PUBDIR" "$BWDIR" "$KEYDIR"
  chmod 711 "$STATE" "$VMROOT"
  chmod 755 "$BASEDIR" "$CONFDIR"
  chmod 700 "$KEYDIR" "$PUBDIR" "$META" "$BWDIR"
  harden_host
  net_sysctl
  download_base
  qemu_smoke
  load_conf
  gc_bases
  install_self
  firewall
  persist_firewall
  echo "[ok] setup complete"
}

setup_done() {
  [ -f "$CONF" ] && [ -f "$BASEDIR/CURRENT" ] && base_current >/dev/null 2>&1 \
    && [ -n "$QEMU_BIN" ] && [ -c /dev/kvm ] && ipt -S VPSOUT >/dev/null 2>&1
}

# ---------- helpers for servers ----------
rand_name() { echo "box-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

rand_port() {
  local p i
  for i in $(seq 1 100); do
    p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40001 ))
    if port_used_by_vm "$p"; then continue; fi
    if command -v ss >/dev/null 2>&1; then
      [ -z "$(ss -H -ltn "sport = :$p" 2>/dev/null)" ] || continue
    fi
    echo "$p"
    return 0
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

# run a command inside the VM with the management key (the output is untrusted data: callers limit it)
vm_ssh() {  # NAME command...
  local name=$1 ip
  shift
  ip=$(sed -n 's/^M_IP=//p' "$META/$name")
  [ -n "$ip" ] && [ -f "$KEYDIR/$name.mgmt" ] || return 1
  timeout 15 ssh -i "$KEYDIR/$name.mgmt" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o ForwardX11=no \
    -o ClearAllForwardings=yes -o PermitLocalCommand=no -o ProxyCommand=none \
    "root@$ip" "$@"
}

get_sshx_link() {  # NAME [TRIES]
  local name=$1 tries=${2:-10} i l=""
  for i in $(seq 1 "$tries"); do
    l=$(vm_ssh "$name" 'cat /run/sshx.log' 2>/dev/null | head -c 65536 \
        | grep -Eo 'https://sshx\.io/s/[^[:space:][:cntrl:]]+' | head -n1 || true)
    if [ -n "$l" ]; then echo "$l"; return 0; fi
    sleep 2
  done
  return 1
}

# wait until the VM answers on SSH. 0 = ready, 1 = timeout, 2 = the service stopped
wait_vm() {  # NAME [SECONDS]
  local name=$1 secs=${2:-240} ip i
  ip=$(sed -n 's/^M_IP=//p' "$META/$name")
  for i in $(seq 1 "$secs"); do
    if ! systemctl is-active --quiet "$(unit_of "$name")"; then return 2; fi
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/22" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

mk_iso() {  # OUT DIR   (volume label "cidata" = cloud-init NoCloud seed)
  local out=$1 dir=$2
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$out" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data" "$dir/network-config" >/dev/null 2>&1
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -output "$out" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data" "$dir/network-config" >/dev/null 2>&1
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -output "$out" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data" "$dir/network-config" >/dev/null 2>&1
  else
    return 1
  fi
}

# first-boot configuration of the VM (cloud-init): keys, hostname, network, ssh hardening, sshx
make_seed() {  # NAME OUT_ISO    (uses M_* globals)
  local name=$1 out=$2 tmp userkey mgmtkey ns s blocked=""
  tmp=$(mktemp -d)
  userkey=$(cat "$PUBDIR/$name")
  mgmtkey=$(awk '{print $1" "$2}' "$KEYDIR/$name.mgmt.pub")
  if [ -n "${BLOCKED_PKGS// /}" ]; then blocked="$BLOCKED_PKGS"; fi

  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" > "$tmp/meta-data"

  ns=""
  for s in $(dns_list); do ns+="$s, "; done
  ns=${ns%, }
  cat > "$tmp/network-config" <<EOF
version: 2
ethernets:
  nic0:
    match:
      macaddress: "$M_MAC"
    set-name: eth0
    addresses:
      - $M_IP/32
    routes:
      - to: 0.0.0.0/0
        via: $(gw_ip)
        on-link: true
    nameservers:
      addresses: [$ns]
EOF

  cat > "$tmp/user-data" <<EOF
#cloud-config
hostname: $name
manage_etc_hosts: localhost
ssh_pwauth: false
disable_root: false
package_update: false
package_upgrade: false
users:
  - name: root
    ssh_authorized_keys:
      - "$userkey"
      - "$mgmtkey"
write_files:
  - path: /etc/ssh/sshd_config.d/00-vps-box.conf
    permissions: "0644"
    content: |
      PermitRootLogin prohibit-password
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
      AuthenticationMethods publickey
      MaxAuthTries 3
      LoginGraceTime 20
      X11Forwarding no
      AllowAgentForwarding no
      ClientAliveInterval 60
      ClientAliveCountMax 3
  - path: /etc/systemd/system/sshx.service
    permissions: "0644"
    content: |
      [Unit]
      Description=sshx web terminal
      After=network-online.target
      Wants=network-online.target

      [Service]
      Environment=HOME=/root
      ExecStart=/bin/sh -c 'if command -v sshx >/dev/null 2>&1; then exec sshx; fi; curl -sSf https://sshx.io/get | sh -s run'
      StandardOutput=truncate:/run/sshx.log
      StandardError=inherit
      Restart=always
      RestartSec=10

      [Install]
      WantedBy=multi-user.target
EOF
  if [ -n "$blocked" ]; then
    cat >> "$tmp/user-data" <<EOF
  - path: /etc/apt/preferences.d/99-vps-box-blocked
    permissions: "0644"
    content: |
      # Packages listed here cannot be installed with apt.
      Package: $blocked
      Pin: release *
      Pin-Priority: -1
EOF
  fi
  cat >> "$tmp/user-data" <<'EOF'
runcmd:
  - [ sh, -c, "curl -sSf https://sshx.io/get | sh || true" ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, sshx.service ]
EOF

  if ! mk_iso "$out" "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

# the full QEMU command line of a VM (uses M_* globals)
vm_qemu_cmd() {  # NAME
  local name=$1 vd="$VMROOT/$1" tap s thr=""
  tap="vbt$M_IDX"
  if [ "${M_IOPS:-0}" -gt 0 ]; then thr+=",throttling.iops-total=$M_IOPS"; fi
  if [ "${M_MBPS:-0}" -gt 0 ]; then thr+=",throttling.bps-total=$(( M_MBPS * 1048576 ))"; fi
  s="$QEMU_BIN -name $name -machine q35,accel=kvm -cpu $QEMU_CPU -smp $M_SMP -m ${M_RAM_MB}M"
  s+=" -nodefaults -no-user-config -display none -vga none -serial null -monitor none"
  if [ "$QEMU_SANDBOX" = on ]; then s+=" -sandbox $SANDBOX_OPTS"; fi
  s+=" -drive file=$vd/disk.qcow2,format=qcow2,if=virtio,discard=unmap$thr"
  s+=" -drive file=$vd/seed.iso,format=raw,if=virtio,readonly=on"
  s+=" -netdev tap,id=n0,ifname=$tap,script=no,downscript=no"
  s+=" -device virtio-net-pci,netdev=n0,mac=$M_MAC,rombar=0"
  s+=" -device virtio-rng-pci"
  echo "$s"
}

# systemd unit of a VM: runs QEMU as its own unprivileged user, inside cgroup limits and a sandbox
write_unit() {  # NAME   (uses M_* globals)
  local name=$1 vd="$VMROOT/$1" memmax
  [ -n "$KVM_GID" ] || return 1
  memmax=$(( M_RAM_MB + 320 ))
  cat > "/etc/systemd/system/$(unit_of "$name")" <<EOF
[Unit]
Description=vps-box virtual machine $name
After=network.target vps-box-fw.service
Wants=vps-box-fw.service

[Service]
Type=simple
User=vbu$M_IDX
SupplementaryGroups=$KVM_GID
ExecStartPre=+$SELF _tapup $name
ExecStart=$(vm_qemu_cmd "$name")
ExecStartPost=+$SELF _bw $name
ExecStopPost=+$SELF _tapdown $name
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
KillMode=control-group
# --- resource limits (the host kernel enforces these on the whole QEMU process) ---
CPUQuota=${M_QUOTA}%
MemoryMax=${memmax}M
MemorySwapMax=0
TasksMax=256
OOMScoreAdjust=500
LimitCORE=0
# --- sandbox around QEMU itself ---
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$vd
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes
DevicePolicy=closed
DeviceAllow=/dev/kvm rw
DeviceAllow=/dev/net/tun rw
DeviceAllow=/dev/null rw
DeviceAllow=/dev/zero rw
DeviceAllow=/dev/full rw
DeviceAllow=/dev/urandom r
DeviceAllow=/dev/random r

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# create the tap device (owned by the VM's own user) and its routing; run by systemd as root before QEMU starts
tapup() {  # NAME
  local name=$1 tap
  load_meta "$name" || die "unknown server $name"
  tap="vbt$M_IDX"
  ip link del "$tap" 2>/dev/null || true
  ip tuntap add dev "$tap" mode tap user "vbu$M_IDX" || die "could not create $tap"
  ip link set "$tap" up
  ip addr add "$(gw_ip)/32" dev "$tap"
  ip route replace "$M_IP/32" dev "$tap" src "$(gw_ip)"
  sysctl -q -w "net.ipv4.conf.$tap.rp_filter=1" >/dev/null 2>&1 || true
  sysctl -q -w "net.ipv4.conf.$tap.proxy_arp=0" >/dev/null 2>&1 || true
  if [ -e "/proc/sys/net/ipv6/conf/$tap/disable_ipv6" ]; then
    sysctl -q -w "net.ipv6.conf.$tap.disable_ipv6=1" >/dev/null 2>&1 || true
    sysctl -q -w "net.ipv6.conf.$tap.accept_ra=0" >/dev/null 2>&1 || true
  fi
}

tapdown() {  # NAME
  local name=$1
  load_meta "$name" || return 0
  ip link del "vbt$M_IDX" 2>/dev/null || true
}

# create the files of a VM: user, disk, seed, unit (uses M_* globals; used by cr and re)
provision_vm() {  # NAME
  local name=$1 vd="$VMROOT/$1" user grp
  user="vbu$M_IDX"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$user" || return 1
  fi
  grp=$(id -gn "$user")
  rm -rf "$vd"
  mkdir -p "$vd" || return 1
  qemu-img create -f qcow2 -F qcow2 -b "$M_BASE" "$vd/disk.qcow2" "$M_DISK" >/dev/null || return 1
  make_seed "$name" "$vd/seed.iso" || return 1
  chown -R "$user:$grp" "$vd"
  chmod 700 "$vd"
  chmod 600 "$vd/disk.qcow2" "$vd/seed.iso"
  write_unit "$name" || return 1
  return 0
}

# remove everything of a VM (safe to call on half-created servers)
destroy_vm() {  # NAME
  local name=$1 idx unit
  unit=$(unit_of "$name")
  idx=$(sed -n 's/^M_IDX=//p' "$META/$name" 2>/dev/null || true)
  if has_systemd; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  fi
  rm -f "/etc/systemd/system/$unit"
  if has_systemd; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
  if [ -n "$idx" ]; then
    ip link del "vbt$idx" 2>/dev/null || true
    if id "vbu$idx" >/dev/null 2>&1; then userdel "vbu$idx" >/dev/null 2>&1 || true; fi
  fi
  rm -rf "${VMROOT:?}/$name"
  rm -f "$META/$name" "$PUBDIR/$name" "$BWDIR/$name" "$KEYDIR/$name" "$KEYDIR/$name.pub" "$KEYDIR/$name.mgmt" "$KEYDIR/$name.mgmt.pub"
}

# ---------- show info of one server ----------
info_one() {  # NAME [SSHX_TRIES]
  local name=$1 tries=${2:-2}
  local status link key pubip cpumodel disk_used
  load_meta "$name" || return 0
  status=$(systemctl is-active "$(unit_of "$name")" 2>/dev/null || true)
  cpumodel=$(host_cpu_model)
  pubip=$(get_pubip)
  bw_conf_read "$name"
  disk_used=$(du -sh "$VMROOT/$name/disk.qcow2" 2>/dev/null | awk '{print $1}' || true)

  key=""
  [ -f "$KEYDIR/$name" ] && key="$KEYDIR/$name"

  link=""
  if [ "$status" = "active" ]; then
    link=$(get_sshx_link "$name" "$tries" || true)
  fi

  echo
  echo "=============================================="
  echo "Name      : $name"
  echo "Status    : ${status:-unknown}"
  echo "Type      : full virtual machine (KVM), Ubuntu $UBUNTU_RELEASE"
  echo "VM address: $M_IP (private)"
  echo "SSH port  : $M_PORT"
  echo "CPU       : $M_SMP virtual core(s), limited to ${M_QUOTA}% of one core | host CPU: $cpumodel"
  echo "RAM       : ${M_RAM_MB}MB"
  echo "Disk      : ${M_DISK}B virtual, used on host: ${disk_used:-?}$( [ "${M_IOPS:-0}" -gt 0 ] && echo ", max ${M_IOPS} IOPS" )$( [ "${M_MBPS:-0}" -gt 0 ] && echo ", max ${M_MBPS}MB/s" )"
  echo "Bandwidth : upload=$cur_up download=$cur_down"
  echo "----------------------------------------------"
  echo "Connect with SSH (open port $M_PORT in the firewall / Security Group):"
  if [ -n "$key" ]; then
    echo "  ssh -i $key -p $M_PORT root@$pubip"
  else
    echo "  ssh -p $M_PORT root@$pubip"
  fi
  echo "sshx link:"
  if [ -n "$link" ]; then
    echo "  $link"
  else
    echo "  (not ready; the first boot takes a minute. Try later: $CMD info $name)"
  fi
  echo "Delete this server:"
  echo "  $CMD de $name"
  echo "=============================================="
}

info_all() {
  local n count=0
  while read -r n; do
    [ -n "$n" ] || continue
    count=$((count + 1))
    info_one "$n" 1
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

# ---------- security report ----------
sec_row() {  # 1|0 text
  local ok=$1; shift
  if [ "$ok" = 1 ]; then printf '  [ OK ] %s\n' "$*"; else printf '  [ !! ] %s\n' "$*"; fi
}

unit_prop() {  # NAME PROP
  systemctl show -p "$2" "$(unit_of "$1")" 2>/dev/null | sed -n "s/^$2=//p"
}

sec_host() {
  local ok st
  echo "Host"
  if [ -c /dev/kvm ]; then ok=1; else ok=0; fi
  sec_row "$ok" "hardware virtualization (/dev/kvm): every server is a separate VM with its own kernel"
  if [ "$QEMU_SANDBOX" = on ]; then ok=1; else ok=0; fi
  sec_row "$ok" "QEMU seccomp sandbox (blocks dangerous system calls of the QEMU process itself)"
  if [[ "$QEMU_CPU" == *-vmx* ]]; then ok=1; else ok=0; fi
  sec_row "$ok" "nested virtualization hidden from guests"
  if ipt -S VPSOUT >/dev/null 2>&1; then ok=1; else ok=0; fi
  sec_row "$ok" "firewall chains VPSOUT/VPSIN (internal networks and metadata service blocked; blocked ports: $BLOCK_TCP_PORTS)"
  if ipt -C INPUT -i 'vbt+' -m conntrack --ctstate NEW -j DROP 2>/dev/null; then ok=1; else ok=0; fi
  sec_row "$ok" "servers cannot open new connections to this host"
  if ipt -C FORWARD -i 'vbt+' -j VPSOUT 2>/dev/null; then ok=1; else ok=0; fi
  sec_row "$ok" "servers cannot talk to each other, cannot spoof addresses (routed taps, no shared network)"
  if systemctl is-active --quiet vps-box-fw.service 2>/dev/null; then ok=1; else ok=0; fi
  sec_row "$ok" "service vps-box-fw is active (rules come back after reboot)"
  st=$(host_sysctl_status)
  if [ "${st%% *}" = "${st##* }" ]; then ok=1; else ok=0; fi
  sec_row "$ok" "host kernel hardening: ${st%% *} of ${st##* } settings strict enough"
}

sec_one() {  # NAME
  local name=$1 ok st pid cmdline user v
  load_meta "$name" || return 0
  st=$(systemctl is-active "$(unit_of "$name")" 2>/dev/null || true)
  echo "Server $name (status: ${st:-unknown})"
  user=$(unit_prop "$name" User)
  if [[ "$user" == vbu* ]]; then ok=1; else ok=0; fi
  sec_row "$ok" "QEMU runs as its own unprivileged user ($user), not as root"
  v=$(unit_prop "$name" MemoryMax)
  if [ -n "$v" ] && [ "$v" != infinity ]; then ok=1; else ok=0; fi
  sec_row "$ok" "host memory cap on the VM process (MemoryMax), no swap"
  v=$(unit_prop "$name" CPUQuotaPerSecUSec)
  if [ -n "$v" ] && [ "$v" != infinity ]; then ok=1; else ok=0; fi
  sec_row "$ok" "host CPU cap on the VM process (CPUQuota=${M_QUOTA}%)"
  v=$(unit_prop "$name" NoNewPrivileges)
  if [ "$v" = yes ]; then ok=1; else ok=0; fi
  sec_row "$ok" "no-new-privileges and empty capability set for the QEMU process"
  v=$(unit_prop "$name" ProtectSystem)
  if [ "$v" = strict ]; then ok=1; else ok=0; fi
  sec_row "$ok" "host file system read-only for QEMU (only its own VM folder is writable)"
  if [ "${M_IOPS:-0}" -gt 0 ] || [ "${M_MBPS:-0}" -gt 0 ]; then ok=1; else ok=0; fi
  sec_row "$ok" "disk speed limits (IOPS ${M_IOPS:-0}, MB/s ${M_MBPS:-0})"
  if [ "$st" = active ]; then
    pid=$(unit_prop "$name" MainPID)
    cmdline=""
    if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/cmdline" ]; then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    fi
    if [[ "$cmdline" == *"-sandbox on"* ]]; then ok=1; else ok=0; fi
    sec_row "$ok" "QEMU seccomp sandbox is active on this VM"
    if [[ "$cmdline" == *"-vmx"* ]]; then ok=1; else ok=0; fi
    sec_row "$ok" "nested virtualization hidden on this VM"
    v=$(sysctl -n "net.ipv4.conf.vbt$M_IDX.rp_filter" 2>/dev/null || echo 0)
    if [ "$v" = 1 ]; then ok=1; else ok=0; fi
    sec_row "$ok" "reverse-path filter on the VM's network device (spoofed sources dropped)"
  else
    echo "  (the server is not running; process checks skipped)"
  fi
}

sec_cmd() {
  local n count=0
  if [ "$#" -gt 1 ]; then die "Usage: $CMD sec [NAME]"; fi
  sec_host
  echo
  if [ "$#" -eq 1 ]; then
    check_owned "$1"
    sec_one "$1"
    return 0
  fi
  while read -r n; do
    [ -n "$n" ] || continue
    count=$((count + 1))
    sec_one "$n"
    echo
  done < <(list_names)
  [ "$count" -gt 0 ] || echo "No servers yet."
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

  # run setup automatically if it has not been done yet
  if ! setup_done; then
    echo "[info] setup has not been done yet; running it now..."
    setup
  fi
  load_conf

  # normalize values coming from environment variables / defaults
  RAM=$(norm_size "$RAM") || die "Invalid RAM value: $RAM"
  DISK=$(norm_size "$DISK") || die "Invalid DISK value: $DISK"
  DISK=${DISK^^}
  BW_UP=$(norm_rate "$BW_UP")     || die "Invalid BW_UP value: $BW_UP (examples: 10mbit, 512kbit, off)"
  BW_DOWN=$(norm_rate "$BW_DOWN") || die "Invalid BW_DOWN value: $BW_DOWN (examples: 10mbit, 512kbit, off)"

  # ---- questions ----
  if [ "$INTERACTIVE" -eq 1 ]; then
    echo "Create a new server (press Enter to accept the value in [brackets])"
    ask_ram
    ask_disk
    ask_cores
    ask_percent
    ask_rate "Upload limit (server -> internet)" BW_UP
    ask_rate "Download limit (internet -> server)" BW_DOWN
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

  local ram_mb disk_mb min_disk
  ram_mb=$(size_mb "$RAM")
  disk_mb=$(size_mb "$DISK")
  min_disk=$(base_min_disk_mb)
  [ "$ram_mb" -ge 128 ] || die "RAM must be at least 128MB"
  [ "$disk_mb" -ge "$min_disk" ] || die "DISK is too small: the Ubuntu image needs at least ${min_disk}MB"

  if vm_exists "$NAME"; then die "A server named $NAME already exists"; fi
  if port_used_by_vm "$PORT"; then die "Port $PORT is already used by another server"; fi
  if command -v ss >/dev/null 2>&1 && [ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]; then
    die "Port $PORT is already in use on this host"
  fi

  # ---- keys ----
  local n PUBKEY tmp
  mkdir -p "$KEYDIR" "$PUBDIR"; chmod 700 "$KEYDIR" "$PUBDIR"
  if [ "$GENKEY" -eq 1 ]; then
    PRIV="$KEYDIR/$NAME"
    [ ! -e "$PRIV" ] || die "Key $PRIV already exists"
    ssh-keygen -q -t ed25519 -N "" -C "$NAME" -f "$PRIV"
    KEY="$PRIV.pub"
  fi
  [ -f "$KEY" ] || die "Key file not found: $KEY"
  n=$(grep -cv '^[[:space:]]*$' "$KEY" || true)
  if [ "$n" -ne 1 ]; then
    if [ "$GENKEY" -eq 1 ]; then rm -f "$PRIV" "$PRIV.pub"; fi
    die "The key file must contain exactly one line (one key)"
  fi
  # keep only "type base64" (the comment is dropped: it could contain characters that break the VM config)
  PUBKEY=$(grep -v '^[[:space:]]*$' "$KEY" | tr -d '\r' | awk '{print $1" "$2}')
  local keyre='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+$'
  if ! [[ "$PUBKEY" =~ $keyre ]]; then
    if [ "$GENKEY" -eq 1 ]; then rm -f "$PRIV" "$PRIV.pub"; fi
    die "Not a valid public key (must start with ssh-ed25519, ssh-rsa, ... and have no options in front)"
  fi
  tmp=$(mktemp)
  printf '%s\n' "$PUBKEY" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    if [ "$GENKEY" -eq 1 ]; then rm -f "$PRIV" "$PRIV.pub"; fi
    die "Invalid public key"
  fi
  rm -f "$tmp"

  # ---- settings ----
  M_IDX=$(alloc_idx) || { [ "$GENKEY" -eq 1 ] && rm -f "$PRIV" "$PRIV.pub"; die "No free VM slot (maximum 241 servers)"; }
  M_IP="$(subnet_prefix).$M_IDX"
  M_PORT=$PORT
  M_MAC=$(printf '52:54:00:%02x:%02x:%02x' "$(( (M_IDX * 7) % 256 ))" "$(( M_IDX % 256 ))" "$(( 255 - M_IDX ))")
  M_RAM_MB=$ram_mb
  M_DISK=$DISK
  M_SMP=$(awk -v c="$CPU_CORES" 'BEGIN{n=int(c); if (n<c) n++; if (n<1) n=1; print n}')
  M_QUOTA=$(awk -v c="$CPU_CORES" -v p="$CPU_PERCENT" 'BEGIN{q=int(c*p+0.5); if (q<1) q=1; print q}')
  M_BASE=$(base_current) || die "No base image; run: sudo bash $0 setup"
  M_IOPS=$DISK_IOPS
  M_MBPS=$DISK_MBPS

  echo "[info] RAM=$(show_size "$RAM") CPU=$M_SMP core(s) limited to ${M_QUOTA}% of one core, DISK=$(show_size "$DISK") (full VM)"
  local avail_mb
  avail_mb=$(df -Pm "$STATE" 2>/dev/null | awk 'NR==2{print $4}' || true)
  if [[ "${avail_mb:-}" =~ ^[0-9]+$ ]] && [ "$disk_mb" -gt "$avail_mb" ]; then
    warn "the virtual disk (${disk_mb}MB) is bigger than the free space on the host (${avail_mb}MB); fine while it stays mostly empty"
  fi

  # management key (lets the host read the sshx link; root only)
  ssh-keygen -q -t ed25519 -N "" -C "vps-box-mgmt" -f "$KEYDIR/$NAME.mgmt"
  printf '%s\n' "$PUBKEY" > "$PUBDIR/$NAME"
  chmod 600 "$PUBDIR/$NAME"
  save_meta "$NAME"
  bw_conf_write "$NAME" "$BW_UP" "$BW_DOWN"

  if ! provision_vm "$NAME"; then
    destroy_vm "$NAME"
    firewall || true
    die "Server creation failed (disk / seed / unit)"
  fi

  firewall
  if ! systemctl enable --now "$(unit_of "$NAME")" >/dev/null 2>&1; then
    journalctl -u "$(unit_of "$NAME")" -n 25 --no-pager >&2 || true
    destroy_vm "$NAME"
    firewall || true
    die "The VM could not start (see the log above)"
  fi

  echo "[info] waiting for the VM to boot (first boot takes 30-90 seconds)..."
  local rc=0
  wait_vm "$NAME" 240 || rc=$?
  if [ "$rc" -eq 2 ]; then
    journalctl -u "$(unit_of "$NAME")" -n 25 --no-pager >&2 || true
    warn "The VM stopped right after starting. Remove it with: $CMD de $NAME"
  elif [ "$rc" -eq 1 ]; then
    warn "The VM is running but SSH is not answering yet; check later with: $CMD info $NAME"
  fi

  info_one "$NAME" 25
}

# ---------- reinstall a server: same name/port/key/limits, ALL data wiped ----------
re() {
  local YES=0
  case "${1:-}" in
    -y|--yes) YES=1; shift ;;
  esac
  [ "$#" -eq 1 ] || die "Usage: $CMD re [-y] NAME"
  local NAME=$1
  check_owned "$NAME"
  if ! setup_done; then
    echo "[info] setup is not complete; running it now..."
    setup
  fi
  load_conf
  load_meta "$NAME" || die "Could not read the settings of $NAME"
  [ -f "$PUBDIR/$NAME" ] || die "Could not read the SSH public key of $NAME"
  [ -f "$KEYDIR/$NAME.mgmt" ] || die "Management key of $NAME is missing"

  if [ "$YES" -eq 0 ] && [ -t 0 ]; then
    ask "This will ERASE ALL DATA of '$NAME' (disk, installed packages, running programs) and start it fresh. Continue? (Y/N)" "N"
    case "${ASK_REPLY,,}" in
      y|yes) ;;
      *) echo "Cancelled."; return 0 ;;
    esac
  fi

  echo "[info] Reinstalling $NAME (port $M_PORT, RAM ${M_RAM_MB}MB, disk ${M_DISK}B)"
  systemctl stop "$(unit_of "$NAME")" >/dev/null 2>&1 || true
  M_BASE=$(base_current) || die "No base image; run setup again"
  save_meta "$NAME"
  if ! provision_vm "$NAME"; then
    die "Could not rebuild the VM files; the server was wiped but not started. Remove it with: $CMD de $NAME"
  fi
  firewall
  gc_bases
  if ! systemctl enable --now "$(unit_of "$NAME")" >/dev/null 2>&1; then
    journalctl -u "$(unit_of "$NAME")" -n 25 --no-pager >&2 || true
    die "The VM could not start. Remove it with: $CMD de $NAME"
  fi

  local rc=0
  echo "[info] waiting for the VM to boot..."
  wait_vm "$NAME" 240 || rc=$?
  if [ "$rc" -ne 0 ]; then warn "The VM is not answering on SSH yet; check later with: $CMD info $NAME"; fi

  echo "[ok] $NAME reinstalled (all old data is gone; the SSH key and port are unchanged; the sshx link is new)"
  info_one "$NAME" 25
}

# ---------- delete / start / stop ----------
de() {
  [ "$#" -eq 1 ] || die "Usage: $CMD de NAME"
  local NAME=$1
  check_owned "$NAME"
  destroy_vm "$NAME"
  firewall || warn "could not refresh the firewall rules"
  gc_bases
  echo "[ok] server $NAME deleted (disk, keys and user removed)"
}

start_cmd() {
  [ "$#" -eq 1 ] || die "Usage: $CMD start NAME"
  check_owned "$1"
  systemctl start "$(unit_of "$1")" || die "Could not start $1 (journalctl -u $(unit_of "$1"))"
  echo "[ok] $1 started"
}

stop_cmd() {
  [ "$#" -eq 1 ] || die "Usage: $CMD stop NAME"
  check_owned "$1"
  systemctl stop "$(unit_of "$1")" || die "Could not stop $1"
  echo "[ok] $1 stopped (use: $CMD start $1)"
}

usage() {
  cat <<EOF
Usage:
  $CMD cr                      create a server (asks RAM / disk / CPU / bandwidth / name)
  $CMD cr -y                   create a server with defaults, no questions
  $CMD cr NAME                 create a server with a custom name
  $CMD cr NAME PORT PUB_FILE   create with custom name, SSH port and public key file
  $CMD de NAME                 delete a server
  $CMD re NAME                 reinstall a server: fresh disk, ALL data wiped (-y = no confirmation)
  $CMD start NAME              start a stopped server
  $CMD stop NAME               stop a server
  $CMD info NAME               info of one server (sshx link, CPU, name, port ...)
  $CMD all info                info of all servers
  $CMD sec [NAME]              security report (which protections are active on the host / on each server)
  $CMD bw NAME [UP DOWN]       show / change bandwidth (off = unlimited)
Defaults can be changed with env vars, e.g.:  RAM=1g DISK=20G $CMD cr -y
Every server is a full KVM virtual machine (Ubuntu $UBUNTU_RELEASE).
EOF
}

load_conf

case "${1:-}" in
  ""|setup|install)
    take_lock
    setup
    echo
    echo "The $CMD command is installed (no server was created). If it is not found in this terminal run: hash -r"
    echo
    usage
    ;;
  cr|add|create)      shift; take_lock; cr "$@" ;;
  de|del|rm|delete)   shift; take_lock; de "$@" ;;
  re|reinstall|reset) shift; take_lock; re "$@" ;;
  start)              shift; take_lock; start_cmd "$@" ;;
  stop)               shift; take_lock; stop_cmd "$@" ;;
  info)               shift; info_cmd "$@" ;;
  all)                shift
                      case "${1:-info}" in
                        info) info_all ;;
                        *)    die "Usage: $CMD all info" ;;
                      esac ;;
  ls|list)            info_all ;;
  bw)                 shift; take_lock; bw_cmd "$@" ;;
  sec|security)       shift; sec_cmd "$@" ;;
  firewall)           take_lock; firewall ;;
  _tapup)             shift; tapup "$@" ;;
  _tapdown)           shift; tapdown "$@" ;;
  _bw)                shift; bw_apply "$@" || true ;;
  help|-h|--help)     usage ;;
  *)                  usage >&2; exit 1 ;;
esac
