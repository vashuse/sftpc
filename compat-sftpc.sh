#!/usr/bin/env bash
# Temporary password-protected SFTP server, for systems whose unshare lacks
# --map-users/--map-groups (util-linux < 2.40). Runs unprivileged in user, mount and
# PID namespaces; newuidmap/newgidmap install the ID maps.
#
# Usage: compat-sftpc.sh DIRECTORY [PORT [LISTEN_ADDRESS]]   (default: 2222, all interfaces)
#
# Env:   SFTP_DIAGNOSTICS  1 prints a namespace, mount, permission and capability report
#
# Needs: unshare, setpriv, newuidmap/newgidmap, /etc/subuid and /etc/subgid ranges of >= 2 IDs,
#        sshd, ssh-keygen, openssl, mount/umount
set -euo pipefail

# --- Arguments ---
dir=${1:?Usage: $0 DIRECTORY [PORT [LISTEN_ADDRESS]]}
port=${2:-2222}
listen_address=${3:-}
dir=$(realpath "$dir")
[[ -d $dir && -w $dir ]] || { echo "Directory must exist and be writable: $dir" >&2; exit 1; }
[[ $port =~ ^[1-9][0-9]{3,4}$ ]] && ((port >= 1024 && port <= 65535)) || { echo 'Port must be 1024-65535' >&2; exit 1; }
if [[ -n $listen_address ]]; then
  [[ $listen_address =~ ^[a-zA-Z0-9._:%-]+$ ]] || { echo 'Listen address must be an IP address or hostname' >&2; exit 1; }
  listen_config="ListenAddress $listen_address"
else
  listen_config=$'ListenAddress 0.0.0.0\nListenAddress ::'
fi
diagnostics=${SFTP_DIAGNOSTICS:-0}
[[ $diagnostics == 0 || $diagnostics == 1 ]] || { echo 'SFTP_DIAGNOSTICS must be 0 or 1' >&2; exit 1; }

# --- Environment checks ---
uid=$(id -u); gid=$(id -g)
((uid != 0)) || { echo 'Run as an unprivileged user, not root' >&2; exit 1; }
username=$(id -un)
read -r subuid uidcount < <(awk -F: -v name="$username" -v id="$uid" '$1==name || $1==id {print $2, $3; exit}' /etc/subuid) || :
read -r subgid gidcount < <(awk -F: -v name="$username" -v id="$uid" '$1==name || $1==id {print $2, $3; exit}' /etc/subgid) || :
[[ -n ${subuid:-} && -n ${subgid:-} && $uidcount -ge 2 && $gidcount -ge 2 ]] || {
  echo 'This compatibility mapping needs at least two delegated subordinate UIDs and GIDs' >&2; exit 1;
}
for helper in unshare setpriv newuidmap newgidmap; do
  command -v "$helper" >/dev/null || { echo "Required helper is missing: $helper" >&2; exit 1; }
done

# --- Host key, temp dir, cleanup ---
# Persistent host ke.
state=${XDG_STATE_HOME:-$HOME/.local/state}/temporary-sftp
mkdir -p "$state"; chmod 700 "$state"
key=$state/host_ed25519_key
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
fingerprint=$(ssh-keygen -lf "$key" | awk '{print $2}')

tmp=$(mktemp -d)

# Stop the process group (setsid made unshare its leader): TERM, then KILL after 3s.
cleanup() {
  trap '' HUP INT QUIT TERM
  trap - EXIT
  if [[ ${unshare_pid:-} =~ ^[0-9]+$ ]]; then
    kill -TERM -- "-$unshare_pid" 2>/dev/null || :
    for _ in {1..30}; do
      kill -0 "$unshare_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$unshare_pid" 2>/dev/null; then
      kill -KILL -- "-$unshare_pid" 2>/dev/null || :
    fi
    wait "$unshare_pid" 2>/dev/null || :
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

id_map_ready_fifo=$tmp/id-map-ready
namespace_init_pid_file=$tmp/namespace-init-host-pid
mkfifo -m 600 "$id_map_ready_fifo"

# --- Namespace scripts ---
cat > "$tmp/pidns.sh" <<'PIDNS'
#!/usr/bin/env bash
# Runs inside the namespaces as uid 1000: build a minimal root, pivot into it, exec sshd.
set -euo pipefail
umask 022  # copied runtime must be readable by uid 1000: umount runs as it after pivot_root
tmp=$1; dir=$2; port=$3; key=$4; listen_config=$5; diagnostics=$6
root=$tmp/root
# mount(8) needs CAP_SYS_ADMIN but must not hold CAP_SETUID ("drop permissions failed").
mount() {
  setpriv --no-new-privs \
    --inh-caps=-all,+sys_admin \
    --ambient-caps=-all,+sys_admin \
    /usr/bin/mount --internal-only "$@"
}
copy_runtime_file() {
  local src=$1
  [[ -f $src ]] || return 1
  cp -L --parents -- "$src" "$root"
}
copy_runtime_binary() {
  local src=$1 dep
  [[ -x $src ]] || return 1
  copy_runtime_file "$src"
  while IFS= read -r dep; do
    copy_runtime_file "$dep"
  done < <(ldd "$src" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^\//) print $i}' | sort -u)
}

# New root on tmpfs; unshare makes mount propagation private.
mkdir -p "$root"
mount -t tmpfs -o uid=1000,gid=1000,mode=755 tmpfs "$root"
# The privilege-separation dir is compiled into sshd and differs per distro (run/sshd, var/empty, usr/share/empty.sshd).
mkdir -p "$root"/{etc,dev,proc,tmp,var/empty,jail/data,lib,lib64,usr/share/empty.sshd,run/sshd}
# Small separate /tmp; SFTP writes go to /jail/data.
mount -t tmpfs -o size=16m,mode=1777,uid=1000,gid=1000,nosuid,nodev,noexec tmpfs "$root/tmp"

for bin in /usr/sbin/sshd /usr/bin/setpriv /usr/bin/umount; do
  copy_runtime_binary "$bin"
done
if [[ $diagnostics == 1 ]]; then
  copy_runtime_binary /usr/bin/bash
  for tool in cat find id readlink; do
    bin=$(command -v "$tool") || { echo "Diagnostic tool is missing: $tool" >&2; exit 1; }
    copy_runtime_binary "$bin"
  done
fi
# glibc before 2.34 dlopen()s libnss_files, so ldd doesn't list it; it sits next to libc.
libc=$(ldd /usr/sbin/sshd | awk '$1 ~ /^libc\.so/ {print $3}')
[[ ! -f ${libc%/*}/libnss_files.so.2 ]] || copy_runtime_file "${libc%/*}/libnss_files.so.2"

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
PidFile none
UsePAM no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication no
AllowUsers sshuser
ChrootDirectory /jail
ForceCommand internal-sftp -u 0077
PermitTTY no
DisableForwarding yes
MaxAuthTries 3
MaxSessions 1
MaxStartups 10:30:30
Subsystem sftp internal-sftp
EOF

cd "$root"
# sshd rejects chroot and privilege-separation directories that aren't root-owned, even under -T.
setpriv --reuid=0 --regid=0 --clear-groups chown 0:0 . jail run run/sshd var/empty usr/share/empty.sshd etc etc/passwd etc/group etc/shadow etc/nsswitch.conf etc/sshd_config etc/ssh_host_ed25519_key
# sshd -T names the helper binaries (sshd-session, sshd-auth) of newer OpenSSH.
while read -r helper; do
  [[ $helper == /* ]] || continue
  copy_runtime_binary "$helper"
done < <(setpriv --reuid=0 --regid=0 --clear-groups /usr/sbin/chroot "$root" /usr/sbin/sshd -T -f /etc/sshd_config | awk '{key=tolower($1); gsub(/[^a-z0-9]/, "", key); if (key=="sshdauthpath" || key=="sshdsessionpath") print $2}')
setpriv --reuid=0 --regid=0 --clear-groups chown -R 0:0 usr lib lib64

# Preflight the copied runtime; if it is incomplete, fall back to read-only mounts of the host's.
if ! setpriv --reuid=0 --regid=0 --clear-groups /usr/sbin/chroot "$root" /usr/sbin/sshd -t -f /etc/sshd_config; then
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

# Enter the new root and detach the old one.
/usr/sbin/pivot_root . .
setpriv --no-new-privs \
  --inh-caps=-all,+sys_admin \
  --ambient-caps=-all,+sys_admin \
  /usr/bin/umount --no-mtab --no-canonicalize --lazy .
cd /
setpriv --reuid=0 --regid=0 --clear-groups /usr/sbin/sshd -t -f /etc/sshd_config

# sshd keeps only setuid/setgid (drop to users), sys_chroot (jail) and kill (children).
# Switching uid clears unshare's --kill-child signal, so --pdeathsig re-arms it for sshd.
sshd_caps=(--bounding-set=-all,+setuid,+setgid,+sys_chroot,+kill
  --inh-caps=-all,+setuid,+setgid,+sys_chroot,+kill
  --ambient-caps=-all,+setuid,+setgid,+sys_chroot,+kill
  --no-new-privs --pdeathsig TERM --reuid=0 --regid=0 --clear-groups)
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
  printf '\n--- Credentials and capabilities before sshd reduction ---\n'
  setpriv --dump
  printf '\n--- Root tree and key permissions ---\n'
  printf 'Runtime: %s. UID/GID are namespace-internal (see maps above); mounts and /dev are not expanded.\n' "$runtime_mode"
  find / /usr/sbin/sshd /usr/bin/bash /usr/share/empty.sshd /dev/null -maxdepth 4 \
    \( -path /usr -o -path /lib -o -path /lib64 -o -path /proc -o -path /dev -o -path /jail/data \) \
    -prune -printf '%M uid=%U gid=%G %p [not expanded]\n' -o \
    -printf '%M uid=%U gid=%G %p\n' || :
  printf '\n--- Mount table (per-mount ro/rw,nosuid,nodev,noexec flags) ---\n'
  cat /proc/self/mountinfo
  printf '\n--- Credentials and capabilities after sshd reduction ---\n'
  setpriv "${sshd_caps[@]}" setpriv --dump
  printf '\n===== End namespace report =====\n\n'
fi
exec setpriv "${sshd_caps[@]}" /usr/sbin/sshd -D -e -f /etc/sshd_config
PIDNS

# Older unshare can't map IDs itself: the bootstrap publishes its host PID, waits while the parent
# installs the maps, then continues into pidns.sh.
cat > "$tmp/bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
tmp=$1; id_map_ready_fifo=$2; namespace_init_pid_file=$3; shift 3
namespace_init_host_pid=
while read -r label first rest; do
  if [[ $label == NSpid: ]]; then namespace_init_host_pid=$first; break; fi
done < /proc/self/status
[[ $namespace_init_host_pid =~ ^[0-9]+$ ]] || { echo 'Could not determine namespace init host PID' >&2; exit 1; }
printf '%s\n' "$namespace_init_host_pid" > "$namespace_init_pid_file"
IFS= read -r _ < "$id_map_ready_fifo"
# Maps are installed. --mount-proc: older libcap-ng (used by setpriv) reads /proc/<tid>/status and fails
# unless /proc matches this PID namespace. --clear-groups: unmapped host groups would reach sshd as GID 65534.
exec unshare --mount-proc setpriv --clear-groups bash "$tmp/pidns.sh" "$tmp" "$@"
BOOTSTRAP

# --- Launch ---
random_password=$(openssl rand -hex 12)
password="${random_password:0:4}-${random_password:4:4}-${random_password:8:4}-${random_password:12:4}-${random_password:16:4}-${random_password:20:4}"
hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)
printf '%s\n' "$hash" > "$tmp/hash"; chmod 600 "$tmp/hash"
# setsid: own process group for cleanup's group kill. --pdeathsig: unshare dies with this script, even on SIGKILL.
setsid setpriv --pdeathsig KILL unshare --user --mount --pid --fork --kill-child --keep-caps --setgroups allow \
  bash "$tmp/bootstrap.sh" "$tmp" "$id_map_ready_fifo" "$namespace_init_pid_file" \
  "$dir" "$port" "$key" "$listen_config" "$diagnostics" &
unshare_pid=$!
# The bootstrap's PID file appears once the namespaces exist.
for _ in {1..200}; do
  [[ -s $namespace_init_pid_file ]] && break
  if ! kill -0 "$unshare_pid" 2>/dev/null; then
    wait "$unshare_pid" || :
    unshare_pid=
    exit 1
  fi
  sleep 0.05
done
[[ -s $namespace_init_pid_file ]] || { echo 'Timed out waiting for namespace bootstrap PID' >&2; exit 1; }
namespace_init_host_pid=$(<"$namespace_init_pid_file")
# IDs: 0 (sshd) and 65534 (privsep) -> subordinate IDs; 1000 (SFTP user) -> you.
newuidmap "$namespace_init_host_pid" 0 "$subuid" 1 1000 "$uid" 1 65534 "$((subuid+1))" 1
newgidmap "$namespace_init_host_pid" 0 "$subgid" 1 1000 "$gid" 1 65534 "$((subgid+1))" 1
printf 'go\n' > "$id_map_ready_fifo"
printf '\n============================================================\n'
printf '              TEMPORARY SFTP SERVER READY\n'
printf '============================================================\n'
printf 'SFTP password:       %s\n' "$password"
printf 'Host key:            %s\n' "$fingerprint"
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
if wait "$unshare_pid"; then
  status=0
else
  status=$?
fi
# Forget the PID: cleanup must not signal a recycled one.
unshare_pid=
exit "$status"