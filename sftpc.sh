#!/usr/bin/env bash
# Minimal temporary SFTP server. Requires util-linux unshare with range-map support,
# sshd, ssh-keygen, openssl, mount/umount, and a valid subordinate ID allocation.
# Set SFTP_DIAGNOSTICS=1 for a namespace, mount, ownership, and root-tree report.
set -euo pipefail

dir=${1:?Usage: $0 DIRECTORY [PORT [LISTEN_ADDRESS]]}
port=${2:-2222}
listen_address=${3:-}
dir=$(realpath "$dir")
[[ -d $dir && -w $dir ]] || { echo "Directory must exist and be writable: $dir" >&2; exit 1; }
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || { echo 'Port must be 1024-65535' >&2; exit 1; }
if [[ -n $listen_address ]]; then
  [[ $listen_address =~ ^[a-zA-Z0-9._:%-]+$ ]] || { echo 'Listen address must be an IP address or hostname' >&2; exit 1; }
  listen_config="ListenAddress $listen_address"
else
  listen_config=$'ListenAddress 0.0.0.0\nListenAddress ::'
fi
diagnostics=${SFTP_DIAGNOSTICS:-0}
[[ $diagnostics == 0 || $diagnostics == 1 ]] || { echo 'SFTP_DIAGNOSTICS must be 0 or 1' >&2; exit 1; }

uid=$(id -u); gid=$(id -g)
username=$(id -un)
read -r subuid uidcount < <(awk -F: -v name="$username" -v id="$uid" '$1==name || $1==id {print $2, $3; exit}' /etc/subuid)
read -r subgid gidcount < <(awk -F: -v name="$username" -v id="$uid" '$1==name || $1==id {print $2, $3; exit}' /etc/subgid)
[[ -n ${subuid:-} && -n ${subgid:-} && $uidcount -ge 2 && $gidcount -ge 2 ]] || {
  echo 'A subordinate UID and GID range of at least two IDs is required' >&2; exit 1;
}
unshare_bin=${UNSHARE_BIN:-$(command -v unshare)}
[[ -x $unshare_bin ]] || { echo 'unshare not found; set UNSHARE_BIN to its executable path' >&2; exit 1; }
unshare_version=$("$unshare_bin" --version 2>&1) || { echo "Cannot read unshare version: $unshare_bin" >&2; exit 1; }
if [[ $unshare_version =~ util-linux[[:space:]]([0-9]+)\.([0-9]+) ]]; then
  unshare_major=${BASH_REMATCH[1]}
  unshare_minor=${BASH_REMATCH[2]}
else
  echo "Cannot identify util-linux version from: $unshare_version" >&2
  exit 1
fi
if (( unshare_major < 2 || (unshare_major == 2 && 10#$unshare_minor < 40) )); then
  echo "unshare from util-linux 2.40 or newer is required for --map-users/--map-groups (found $unshare_version)" >&2
  exit 1
fi

state=${XDG_STATE_HOME:-$HOME/.local/state}/temporary-sftp
mkdir -p "$state"; chmod 700 "$state"
key=$state/host_ed25519_key
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"

tmp=$(mktemp -d); chmod 700 "$tmp"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ ${child:-} =~ ^[0-9]+$ ]]; then
    kill -KILL "$child" 2>/dev/null || :
    wait "$child" 2>/dev/null || :
  fi
  rm -rf "$tmp"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$tmp/pidns.sh" <<'PIDNS'
#!/usr/bin/env bash
set -euo pipefail
tmp=$1; dir=$2; port=$3; key=$4; listen_config=$5; diagnostics=$6
root=$tmp/root
mount() {
  setpriv --no-new-privs \
    --inh-caps=-all,+sys_admin \
    --ambient-caps=-all,+sys_admin \
    /usr/bin/mount "$@"
}
copy_runtime_file() {
  local src=$1
  [[ -f $src ]] || return 1
  mkdir -p "$root$(dirname "$src")"
  cp -L --parents -- "$src" "$root"
}
copy_runtime_dependencies() {
  local src=$1 dep
  [[ -x $src ]] || return 1
  while IFS= read -r dep; do
    [[ -n $dep ]] && copy_runtime_file "$dep"
  done < <(ldd "$src" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^\//) {sub(/\(.*/, "", $i); print $i}}' | sort -u)
}
copy_runtime_binary() {
  local src=$1
  [[ -x $src ]] || return 1
  copy_runtime_file "$src"
  chmod 755 "$root$src"
  copy_runtime_dependencies "$src"
}
mkdir -p "$root"
# unshare --mount makes propagation private by default.
mount -t tmpfs -o uid=1000,gid=1000 tmpfs "$root"
mkdir -p "$root"/{etc,dev,proc,tmp,run,var/empty,jail/data,lib,lib64,usr/share/empty.sshd}
# Keep /tmp on its own small tmpfs. SFTP writes go to /jail/data instead.
mount -t tmpfs -o size=16m,mode=1777,uid=1000,gid=1000,nosuid,nodev,noexec tmpfs "$root/tmp"

# Start with a curated copied runtime; preflight checks config and helper files.
for bin in /usr/sbin/sshd /usr/bin/setpriv /usr/bin/mount /usr/bin/umount \
           /usr/sbin/pivot_root /usr/sbin/chroot /usr/bin/chown; do
  copy_runtime_binary "$bin"
done
if [[ $diagnostics == 1 ]]; then
  for bin in /usr/bin/bash /usr/bin/awk /usr/bin/cat /usr/bin/find /usr/bin/id \
             /usr/bin/readlink /usr/bin/stat; do
    [[ ! -x $bin ]] || copy_runtime_binary "$bin"
  done
  [[ ! -x /usr/sbin/capsh ]] || copy_runtime_binary /usr/sbin/capsh
fi
chown 1000:1000 "$root/jail" "$root/jail/data"
mount --bind "$dir" "$root/jail/data"
mount -o remount,bind,rw,nosuid,nodev,noexec "$root/jail/data"
cp -- "$key" "$root/etc/ssh_host_ed25519_key"
chmod 600 "$root/etc/ssh_host_ed25519_key"
printf "root:x:0:0:root:/root:/bin/false\nsshuser:x:1000:1000:SFTP:/data:/bin/false\nsshd:x:65534:65534:Privilege separation:/var/empty:/bin/false\n" > "$root/etc/passwd"
printf "root:x:0:\nsshuser:x:1000:\nsshd:x:65534:\n" > "$root/etc/group"
printf "root:*:19000:0:99999:7:::\nsshuser:%s:19000:0:99999:7:::\n" "$(cat "$tmp/hash")" > "$root/etc/shadow"
chmod 600 "$root/etc/shadow"
printf "passwd: files\ngroup: files\nshadow: files\n" > "$root/etc/nsswitch.conf"
touch "$root/dev/null"
mount --bind /dev/null "$root/dev/null"
mount -o remount,bind,ro "$root/dev/null"
mount -t proc proc "$root/proc"
cat > "$root/etc/sshd_config" <<EOF
Port $port
$listen_config
HostKey /etc/ssh_host_ed25519_key
PidFile /run/sshd.pid
UsePAM no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication no
PermitEmptyPasswords no
AllowUsers sshuser
PermitRootLogin no
ChrootDirectory /jail
ForceCommand internal-sftp -d /data -u 0077
PermitTTY no
DisableForwarding yes
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitUserRC no
LoginGraceTime 120
MaxAuthTries 3
MaxSessions 1
MaxStartups 10:30:30
Subsystem sftp internal-sftp
EOF
# NSS loads libnss_files dynamically, so it is not necessarily in ldd output.
if command -v ldconfig >/dev/null 2>&1; then
  nss_files=$(ldconfig -p 2>/dev/null | awk '$1=="libnss_files.so.2" {print $NF; exit}')
  [[ -z ${nss_files:-} ]] || copy_runtime_binary "$nss_files"
fi
cd "$root"
setpriv --reuid=0 --regid=0 --clear-groups chown 0:0 . jail run var/empty etc etc/passwd etc/group etc/shadow etc/nsswitch.conf etc/sshd_config etc/ssh_host_ed25519_key
setpriv --reuid=0 --regid=0 --clear-groups chown 0:0 usr/share/empty.sshd
chmod 755 . jail run var/empty etc usr/share/empty.sshd
chmod 644 etc/passwd etc/group etc/nsswitch.conf etc/sshd_config
chmod 600 etc/shadow etc/ssh_host_ed25519_key
# Discover helpers only after the temporary privilege-separation directory and
# configuration have root ownership; sshd -T rejects an unsafe directory.
while read -r helper; do
  [[ $helper == /* ]] || continue
  copy_runtime_binary "$helper"
done < <(setpriv --reuid=0 --regid=0 --clear-groups chroot "$root" /usr/sbin/sshd -T -f /etc/sshd_config | awk '{key=tolower($1); gsub(/[^a-z0-9]/, "", key); if (key=="sshdauthpath" || key=="sshdsessionpath") print $2}')
setpriv --reuid=0 --regid=0 --clear-groups chown -R 0:0 usr lib lib64
# If the curated tree is incomplete, add the existing read-only system runtime.
if ! setpriv --reuid=0 --regid=0 --clear-groups chroot "$root" /usr/sbin/sshd -t -f /etc/sshd_config; then
  printf 'Curated runtime preflight failed; falling back to read-only /usr and library mounts.\n' >&2
  mount --bind /usr "$root/usr"; mount -o remount,bind,ro,nosuid,nodev "$root/usr"
  for p in /lib /lib64; do
    if [[ -e $p ]]; then
      mount --bind "$p" "$root$p"
      mount -o remount,bind,ro,nosuid,nodev "$root$p"
    fi
  done
  privsep=$root/usr/share/empty.sshd
  if [[ -d /usr/share/empty.sshd ]]; then
    mount --bind "$root/var/empty" "$privsep"
    mount -o remount,bind,ro,nosuid,nodev,noexec "$privsep"
  fi
  runtime_mode='read-only fallback mounts'
else
  runtime_mode='curated copied runtime'
  for p in /usr /lib /lib64; do
    if [[ -d $root$p ]]; then
      mount --bind "$root$p" "$root$p"
      mount -o remount,bind,ro,nosuid,nodev "$root$p"
    fi
  done
fi
pivot_root . .
setpriv --no-new-privs \
  --inh-caps=-all,+sys_admin \
  --ambient-caps=-all,+sys_admin \
  /usr/bin/umount --no-mtab --no-canonicalize --lazy .
cd /
setpriv --reuid=0 --regid=0 --clear-groups /usr/sbin/sshd -t -f /etc/sshd_config
if [[ $diagnostics == 1 ]]; then
  printf '\n===== SFTP namespace report =====\n'
  printf '\n--- Namespace identity and ID maps ---\n'
  id
  printf 'user namespace: '; readlink /proc/self/ns/user
  printf 'mount namespace: '; readlink /proc/self/ns/mnt
  printf 'PID namespace: '; readlink /proc/self/ns/pid
  printf 'uid_map:\n'; cat /proc/self/uid_map
  printf 'gid_map:\n'; cat /proc/self/gid_map
  printf 'setgroups: '; cat /proc/self/setgroups 2>/dev/null || printf 'unavailable\n'
  printf '\n--- Namespace process credentials and capabilities before sshd reduction ---\n'
  awk '/^(Name|Pid|NSpid|Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):/ {print}' /proc/self/status
  if command -v capsh >/dev/null 2>&1; then
    cap_eff_hex=$(awk '$1=="CapEff:" {print $2}' /proc/self/status)
    capsh --decode="0x$cap_eff_hex"
  fi
  printf '\n--- Root tree (numeric ownership; mounted data contents omitted) ---\n'
  printf 'UID/GID numbers are from inside the user namespace; uid_map and gid_map above show their host-side mapping.\n'
  printf 'The process root is the temporary tmpfs; the previous host root was detached after pivot_root.\n'
  printf 'Runtime: %s; /tmp is nosuid,nodev,noexec; /jail/data is the writable host-directory bind.\n' "$runtime_mode"
  find . -maxdepth 4 \
    \( -path './usr' -o -path './lib' -o -path './lib64' \
       -o -path './proc' -o -path './dev' -o -path './jail/data' \) \
    -prune -printf '%M uid=%U gid=%G %p [mounted tree omitted]\n' -o \
    -printf '%M uid=%U gid=%G %p\n'
  printf '\n--- Important binaries and mountpoint permissions ---\n'
  stat -c '%A mode=%a uid=%u gid=%g %n' \
    /usr/sbin/sshd /usr/bin/bash / \
    /usr /lib /lib64 /jail /jail/data /usr/share/empty.sshd /run \
    /dev/null /proc /tmp /etc/sshd_config /etc/ssh_host_ed25519_key /etc/shadow 2>&1 || :
  printf '\n--- Mount table (per-mount ro/rw,nosuid,nodev,noexec flags) ---\n'
  cat /proc/self/mountinfo
fi
sshd_caps=(--bounding-set=-all,+setuid,+setgid,+sys_chroot,+kill
  --inh-caps=-all,+setuid,+setgid,+sys_chroot,+kill
  --ambient-caps=-all,+setuid,+setgid,+sys_chroot,+kill
  --no-new-privs --reuid=0 --regid=0 --clear-groups)
if [[ $diagnostics == 1 ]]; then
  printf '\n--- Credentials and capabilities after sshd capability reduction ---\n'
  setpriv "${sshd_caps[@]}" /usr/bin/bash -c '
    id
    awk "/^(Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):/ {print}" /proc/self/status
  '
  printf '\n===== End namespace report =====\n\n'
fi
exec setpriv "${sshd_caps[@]}" /usr/sbin/sshd -D -e -f /etc/sshd_config
PIDNS

random_password=$(openssl rand -hex 12)
password="${random_password:0:4}-${random_password:4:4}-${random_password:8:4}-${random_password:12:4}-${random_password:16:4}-${random_password:20:4}"
hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)
printf '%s\n' "$hash" > "$tmp/hash"; chmod 600 "$tmp/hash"
"$unshare_bin" \
  --user \
  --map-users "0:$subuid:1" \
  --map-users "1000:$uid:1" \
  --map-users "65534:$((subuid+1)):1" \
  --map-groups "0:$subgid:1" \
  --map-groups "1000:$gid:1" \
  --map-groups "65534:$((subgid+1)):1" \
  --setgroups=allow --keep-caps \
  --setuid 1000 --setgid 1000 \
  --mount --pid --fork --kill-child --forward-signals \
  bash "$tmp/pidns.sh" "$tmp" "$dir" "$port" "$key" "$listen_config" "$diagnostics" &
child=$!
printf '\n============================================================\n'
printf '              TEMPORARY SFTP SERVER READY\n'
printf '============================================================\n'
printf 'SFTP password:       %s\n' "$password"
if [[ -n $listen_address ]]; then
  printf 'Listening address:   %s:%s\n' "$listen_address" "$port"
else
  printf 'Listening address:   all IPv4 and IPv6 interfaces, port %s\n' "$port"
fi
printf 'Host source folder:  %s\n' "$dir"
printf 'SFTP destination:    /data\n'
printf 'SFTP username:       sshuser\n'
printf 'Stop server:         press Ctrl-C\n'
printf '============================================================\n\n'
if wait "$child"; then
  status=0
else
  status=$?
fi
child=
exit "$status"
