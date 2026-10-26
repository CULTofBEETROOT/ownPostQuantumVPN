#!/usr/bin/env bash
set -Eeuo pipefail

HISTCONTROL=ignoreboth

 if [[ $(cat /etc/hosts | grep $(hostname) | grep 127.0.1.1) == "" ]]; then
    echo "127.0.1.1    $(hostname)" >>  /etc/hosts;
 fi

rm -f /etc/apt/*.list
rm -f /etc/apt/*.list~
rm -R /etc/apt/*.list.d
cat>/etc/apt/sources.list<<'endletsapt'
deb https://deb.debian.org/debian/ trixie main contrib non-free-firmware
deb https://security.debian.org/debian-security/ trixie-security main contrib non-free-firmware
deb https://deb.debian.org/debian/ trixie-updates main contrib non-free-firmware
endletsapt

 apt update 
 apt install -y sudo;
 apt install -y tor apt-transport-tor torsocks;
 systemctl enable --now tor.service
 echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' \  | sudo debconf-set-selections
 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades

echo "transport-tor downloaded"
echo "ExitNodes {ch}" > /etc/tor/torrc
echo "StrictNodes 1" >> /etc/tor/torrc
rm -f /etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d
touch /etc/apt/sources.list.d/debian.sources
cat>/etc/apt/sources.list.d/debian.sources<<'endupdateapt'
# Modernized from /etc/apt/sources.list
Types: deb
URIs: tor+https://deb.debian.org/debian/
Suites: trixie
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Modernized from /etc/apt/sources.list
Types: deb
URIs: tor+https://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Modernized from /etc/apt/sources.list
Types: deb
URIs: tor+https://deb.debian.org/debian/
Suites: trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
endupdateapt

rm -f /etc/apt/*.list
rm -f /etc/apt/*.list~
echo "APT::Periodic::Update-Package-Lists "1";" > cat /etc/apt/apt.conf.d/20auto-upgrades
echo "APT::Periodic::Update-Package-Lists "1";" >> cat /etc/apt/apt.conf.d/20auto-upgrades
cat>/etc/apt/apt.conf.d/50unattended-upgrades<<'end50unattended'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "true";
end50unattended

apt update
apt upgrade -y
apt autoremove -y ufw
apt install -y ufw
sudo ufw allow in 22/tcp
sudo ufw enable
    apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        ufw \
        wireguard \
        wireguard-tools \
        qrencode \
        nftables \
        curl \
		torsocks \
        jq \
        dnsutils \
        grep \
        sed \
        coreutils \
        findutils \
        procps \
        gawk \
        util-linux \
        gnupg \
        openssl \
        clamav \
        clamav-daemon \
        clamav-freshclam \
    	tar \
    	golang-go \
    	git \
		ca-certificates \
		gzip
apt autoremove -y

umask 077

# One-block Debian 13 (trixie) VPS setup:
#   - Replaces APT sources and configures Tor-routed APT.
#   - Enables unattended upgrades and UFW.
#   - Installs tools and provisions 100 Rosenpass/WireGuard key bundles.
#   - Installs AmneziaWG and creates its clients, skipping existing clients.
#
# Run as root. Keep the age PQ private identity off this VPS.
#
# Optional settings:
#   CLIENT_COUNT=100 CLIENT_PREFIX=client SSH_PORT=22 AWG_PROTOCOL=3.1
#
# Rerunning regenerates the Rosenpass output directory and its keys.
# AmneziaWG clients already present in the manager are skipped.

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID%%.*}" == 13 ]] ||
  die "This script is intended for Debian 13."

# Prevent simultaneous provisioning runs.
exec 9>/run/lock/vps-provision.lock
flock -n 9 || die "Another provisioning run is active."

[[ "$(dpkg --print-architecture)" == amd64 ]] ||
  die "This script requires Debian amd64."
findmnt -n -o FSTYPE /run | grep -qx tmpfs ||
  die "/run is not tmpfs; refusing to stage plaintext keys there."

CLIENT_COUNT="${CLIENT_COUNT:-100}"
CLIENT_PREFIX="${CLIENT_PREFIX:-client}"
SSH_PORT="${SSH_PORT:-22}"
AWG_PROTOCOL="${AWG_PROTOCOL:-3.1}"

[[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] &&
  (( CLIENT_COUNT >= 1 && CLIENT_COUNT <= 253 )) ||
  die "CLIENT_COUNT must be between 1 and 253."
[[ "$CLIENT_PREFIX" =~ ^[a-zA-Z0-9_-]+$ ]] ||
  die "CLIENT_PREFIX may contain only letters, numbers, underscores, and hyphens."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] &&
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) ||
  die "SSH_PORT must be between 1 and 65535."

case "$AWG_PROTOCOL" in
  2.0) PROTOCOL_ARG="--protocol=2.0" ;;
  3.1) PROTOCOL_ARG="--protocol=3.1" ;;
  *) die "AWG_PROTOCOL must be 2.0 or 3.1." ;;
esac

export DEBIAN_FRONTEND=noninteractive

# Ensure this host has a 127.0.1.1 entry.
if ! grep -Fq "127.0.1.1 $(hostname)" /etc/hosts; then
  printf '127.0.1.1\t%s\n' "$(hostname)" >> /etc/hosts
fi

# Replace APT source configuration, retaining the requested Trixie sources.
rm -f /etc/apt/*.list /etc/apt/*.list~
rm -rf /etc/apt/*.list.d
cat > /etc/apt/sources.list <<'EOF'
deb https://deb.debian.org/debian/ trixie main contrib non-free-firmware
deb https://security.debian.org/debian-security/ trixie-security main contrib non-free-firmware
deb https://deb.debian.org/debian/ trixie-updates main contrib non-free-firmware
EOF

apt-get update
apt-get install -y sudo tor apt-transport-tor torsocks unattended-upgrades

systemctl enable --now tor.service
printf '%s\n' 'ExitNodes {ch}' 'StrictNodes 1' > /etc/tor/torrc
systemctl restart tor.service

# Route subsequent APT access through Tor.
rm -f /etc/apt/sources.list
install -d -m 0755 /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: tor+https://deb.debian.org/debian/
Suites: trixie
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: tor+https://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: tor+https://deb.debian.org/debian/
Suites: trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f /etc/apt/*.list /etc/apt/*.list~

# Correctly write the APT periodic-upgrade configuration.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "true";
EOF


# Permit SSH before enabling UFW.
ufw allow "${SSH_PORT}/tcp" comment "SSH administration"
ufw --force enable

# Age PQ recipient is needed to encrypt the Rosenpass/WireGuard bundles.
read -r -p "Age PQ recipient (must begin age1pq1): " AGE_RECIPIENT
[[ "$AGE_RECIPIENT" == age1pq1* ]] ||
  die "Expected an age PQ recipient beginning age1pq1."

WORK="$(mktemp -d /run/rp-provision.XXXXXXXX)"
cleanup() {
  unset AGE_RECIPIENT
  rm -rf -- "${WORK:-}"
}
trap cleanup EXIT HUP INT TERM

# Install upstream age and its PQ plugin.
AGE_VERSION=1.3.2
AGE_SHA256=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10

curl --fail --location --silent --show-error \
  "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
  -o "$WORK/age.tar.gz"
printf '%s  %s\n' "$AGE_SHA256" "$WORK/age.tar.gz" | sha256sum --check -
mkdir "$WORK/age"
tar -xzf "$WORK/age.tar.gz" -C "$WORK/age"

AGE_BIN="$(find "$WORK/age" -type f -name age -print -quit)"
AGE_KEYGEN="$(find "$WORK/age" -type f -name age-keygen -print -quit)"
AGE_PQ_PLUGIN="$(find "$WORK/age" -type f -name age-plugin-pq -print -quit)"
[[ -n "$AGE_BIN" && -n "$AGE_KEYGEN" && -n "$AGE_PQ_PLUGIN" ]] ||
  die "The age archive is missing an expected executable."
install -m 0755 "$AGE_BIN" /usr/local/bin/age
install -m 0755 "$AGE_KEYGEN" /usr/local/bin/age-keygen
install -m 0755 "$AGE_PQ_PLUGIN" /usr/local/bin/age-plugin-pq

# Install Rosenpass binaries.
RP_VERSION=0.2.3
curl --fail --location --silent --show-error \
  "https://github.com/rosenpass/rosenpass/releases/download/v${RP_VERSION}/rosenpass-x86_64-linux-${RP_VERSION}.tar" \
  -o "$WORK/rosenpass.tar"
mkdir "$WORK/rosenpass"
tar -xf "$WORK/rosenpass.tar" -C "$WORK/rosenpass"
install -m 0755 "$WORK/rosenpass/bin/rosenpass" /usr/local/bin/rosenpass
install -m 0755 "$WORK/rosenpass/bin/rp" /usr/local/bin/rp

command -v age >/dev/null
command -v age-keygen >/dev/null
command -v age-plugin-pq >/dev/null
command -v wg >/dev/null
command -v rp >/dev/null
command -v rosenpass >/dev/null

printf 'age PQ capability test\n' |
  age -r "$AGE_RECIPIENT" -o "$WORK/age-test.age"

# Recreate this generated-output tree on every run, as requested. Plaintext
# private key staging remains under /run and is removed by the exit trap.
OUT=/root/rosenpass-provisioning
rm -rf -- "$OUT"
install -d -m 0700 "$OUT/encrypted-client-bundles" \
                     "$OUT/client-public-keys"

for n in $(seq -w 1 "$CLIENT_COUNT"); do
  id="client-${n}"
  secret_dir="$WORK/${id}.rosenpass-secret"
  public_dir="$WORK/${id}.rosenpass-public"
  wg_private="$WORK/${id}.wg-private"
  wg_public="$WORK/${id}.wg-public"
  archive="$WORK/${id}.tar"
  encrypted="$WORK/${id}.tar.age"
  public_stage="$WORK/${id}.public-stage"

  rp genkey "$secret_dir"
  rp pubkey "$secret_dir" "$public_dir"

  wg genkey > "$wg_private"
  wg pubkey < "$wg_private" > "$wg_public"

  tar -C "$WORK" -cf "$archive" \
    "${id}.rosenpass-secret" \
    "${id}.wg-private" \
    "${id}.wg-public"

  age -r "$AGE_RECIPIENT" -o "$encrypted" "$archive"

  # Publish only the encrypted private bundle and public keys.
  install -m 0600 "$encrypted" \
    "$OUT/encrypted-client-bundles/${id}.tar.age"
  install -d -m 0700 "$public_stage"
  cp -a "$public_dir"/. "$public_stage"/
  install -m 0644 "$wg_public" "$public_stage/wireguard-public.key"
  mv "$public_stage" "$OUT/client-public-keys/$id"

  echo "Prepared $id"
done

cat > "$OUT/README.txt" <<'EOF'
Encrypted private bundles: encrypted-client-bundles/
Public keys for server-side peer configuration: client-public-keys/
These are key materials, not complete client.conf files.
Keep the matching age PQ private identity off this VPS.
EOF
chmod 0600 "$OUT/README.txt"

unset AGE_RECIPIENT
rm -rf -- "$WORK"
WORK=""

# AmneziaWG installer and client provisioner.
INSTALLER_URL="https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg_en.sh"
INSTALLER=/root/install_amneziawg_en.sh
MANAGER=/root/awg/manage_amneziawg.sh

# Preserve SSH access before the VPN installer configures UFW.
ufw allow "${SSH_PORT}/tcp" comment "SSH administration" || true

if [[ ! -s "$INSTALLER" ]]; then
  curl --fail --location --silent --show-error --retry 3 \
    "$INSTALLER_URL" --output "$INSTALLER"
  chmod 0700 "$INSTALLER"
fi

bash "$INSTALLER" "$PROTOCOL_ARG" --yes

[[ -x "$MANAGER" ]] ||
  die "AmneziaWG manager is not available yet. Reboot if requested, then rerun."

# Reruns inspect the manager's current client list and skip exact name matches.
# This avoids re-adding clients successfully created before an earlier failure.
manager_has_client() {
  local wanted="$1"
  local listing
  listing="$(bash "$MANAGER" list 2>&1)" || return 1
  grep -Eq "(^|[^[:alnum:]_-])${wanted}([^[:alnum:]_-]|$)" <<< "$listing"
}

for (( n = 1; n <= CLIENT_COUNT; n++ )); do
  name="${CLIENT_PREFIX}${n}"

  if manager_has_client "$name"; then
    echo "Already present; skipping $name"
    continue
  fi

  echo "Adding $name..."
  bash "$MANAGER" add "$name"

  # Confirm the manager now reports the client. If not, fail so the next
  # run checks again instead of incorrectly recording completion.
  manager_has_client "$name" ||
    die "Manager did not report $name after adding it."
done

# Record the settings used by this run.
install -d -m 0700 /root/awg
{
  printf 'CLIENT_PREFIX=%q\n' "$CLIENT_PREFIX"
  printf 'CLIENT_COUNT=%q\n' "$CLIENT_COUNT"
  printf 'AWG_PROTOCOL=%q\n' "$AWG_PROTOCOL"
  printf 'COMPLETED_AT=%q\n' "$(date --iso-8601=seconds)"
} > /root/awg/.client-provisioning-complete
chmod 0600 /root/awg/.client-provisioning-complete

echo
echo "Provisioning completed."
echo "Rosenpass bundles: $OUT/encrypted-client-bundles/"
echo "Rosenpass public keys: $OUT/client-public-keys/"
echo "AmneziaWG clients: ${CLIENT_PREFIX}1 through ${CLIENT_PREFIX}${CLIENT_COUNT}"
echo "Manager: bash $MANAGER list"
echo "Keep client configuration files and the age PQ identity private."
