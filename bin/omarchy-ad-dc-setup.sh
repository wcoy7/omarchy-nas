#!/usr/bin/env bash
# Omarchy / Arch: Samba AD DC + file shares + DNS + DHCP (Kea) + wsdd
# plus an optional restic backup helper.
#
# Run as root on the machine that will be the DC.
# Edit the CONFIG block, then:  sudo ./omarchy-ad-dc-setup.sh
#
# DC uses samba.service only (not smb/nmb/winbind).
# DNS is Samba internal. Existing LAN DNS can stay if you later add a
# conditional forward; this script makes THIS box authoritative and
# hands itself out via DHCP.
set -euo pipefail

############################
# CONFIG  — edit these
############################
REALM="OFFICE.LAN"                 # Kerberos realm, UPPERCASE, usually DNS domain
DOMAIN="OFFICE"                    # NetBIOS domain, UPPERCASE, <= 15 chars
SHORT_HOSTNAME="dc1"               # this machine
IP_ADDRESS="192.168.1.10"          # static IP of this DC
PREFIX="24"
INTERFACE="eth0"                   # ip -br link
GATEWAY="192.168.1.1"
DHCP_RANGE_START="192.168.1.100"
DHCP_RANGE_END="192.168.1.199"
DNS_FORWARDER="1.1.1.1"            # for names outside REALM
SHARE_PATH="/srv/samba/office"
SHARE_NAME="Office"
# Admin password: export SAMBA_ADMIN_PASS before running, or you will be prompted.
# Must be 8+ chars with upper + digit (Samba complexity).

############################
# helpers
############################
log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "run as root"; }

pkg_add() {
  if command -v omarchy-pkg-add >/dev/null 2>&1; then
    omarchy-pkg-add "$@"
  else
    pacman -S --noconfirm --needed "$@"
  fi
}

realm_dns="${REALM,,}"
fqdn="${SHORT_HOSTNAME}.${realm_dns}"

reverse_octets() {
  # 192.168.1.10 /24 -> zone 1.168.192.in-addr.arpa, host octet 10
  local ip=$1
  IFS=. read -r a b c d <<<"$ip"
  printf '%s %s' "${c}.${b}.${a}.in-addr.arpa" "$d"
}

install_pkgs() {
  log "Installing packages"
  pkg_add samba krb5 chrony python-cryptography python-dnspython python-markdown \
          kea kea-docs wsdd restic bind
}

set_identity() {
  log "Hostname and hosts file"
  hostnamectl hostname "$SHORT_HOSTNAME"
  if ! grep -qE "[[:space:]]${fqdn}([[:space:]]|$)" /etc/hosts; then
    printf '%s\t%s %s\n' "$IP_ADDRESS" "$fqdn" "$SHORT_HOSTNAME" >> /etc/hosts
  fi
}

free_dns_port() {
  log "Freeing port 53 for Samba DNS"
  systemctl disable --now systemd-timesyncd.service 2>/dev/null || true
  if systemctl is-enabled systemd-resolved.service >/dev/null 2>&1 \
     || systemctl is-active systemd-resolved.service >/dev/null 2>&1; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved.service || true
  fi
}

write_resolv() {
  log "Pointing resolver at local Samba DNS"
  # Keep a fallback copy
  [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]] && cp -a /etc/resolv.conf /etc/resolv.conf.pre-ad || true
  rm -f /etc/resolv.conf
  cat >/etc/resolv.conf <<EOF
search ${realm_dns}
nameserver 127.0.0.1
nameserver ${DNS_FORWARDER}
EOF
  chmod 644 /etc/resolv.conf
}

provision_domain() {
  if [[ -f /var/lib/samba/private/sam.ldb ]]; then
    log "Samba AD already provisioned (sam.ldb exists), skipping provision"
    return
  fi
  log "Provisioning Samba AD DC ($REALM / $DOMAIN)"
  samba-tool domain provision \
    --use-rfc2307 \
    --realm="$REALM" \
    --domain="$DOMAIN" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --host-name="$SHORT_HOSTNAME" \
    --host-ip="$IP_ADDRESS" \
    --adminpass="$SAMBA_ADMIN_PASS" \
    --option="dns forwarder = ${DNS_FORWARDER}" \
    --option="netbios name = ${SHORT_HOSTNAME^^}"
}

install_krb5() {
  log "Installing krb5.conf from Samba"
  if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    [[ -f /etc/krb5.conf ]] && mv -f /etc/krb5.conf /etc/krb5.conf.pre-ad
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
  fi
}

configure_chrony() {
  log "Chrony + Samba NTP signing"
  install -d -m 0750 -o root -g chrony /var/lib/samba/ntp_signd
  cat >/etc/chrony.conf <<EOF
pool 2.arch.pool.ntp.org iburst maxsources 4
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow ${IP_ADDRESS%.*}.0/${PREFIX}
ntpsigndsocket /var/lib/samba/ntp_signd
bindcmdaddress unix
EOF
  systemctl disable --now systemd-timesyncd.service 2>/dev/null || true
  systemctl enable --now chronyd.service
}

configure_samba_services() {
  log "samba.service only (disable member units)"
  systemctl disable --now smb.service nmb.service winbind.service 2>/dev/null || true
  # File share + ACL bits. provision already wrote [global]; append share if missing.
  if [[ -f /etc/samba/smb.conf ]] && ! grep -q "^\[${SHARE_NAME}\]" /etc/samba/smb.conf; then
    mkdir -p "$SHARE_PATH"
    chmod 0770 "$SHARE_PATH"
    cat >>/etc/samba/smb.conf <<EOF

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   read only = no
   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes
EOF
  fi
  # Do not add idmap config on a DC.
  systemctl enable --now samba.service
}

configure_reverse_zone() {
  log "AD reverse DNS zone"
  read -r zone host_oct <<<"$(reverse_octets "$IP_ADDRESS")"
  if ! samba-tool dns zonelist "$fqdn" -U administrator --password "${SAMBA_ADMIN_PASS:-}" 2>/dev/null | grep -q "$zone"; then
    samba-tool dns zonecreate "$fqdn" "$zone" -U administrator --password "${SAMBA_ADMIN_PASS:-}" \
      || samba-tool dns zonecreate localhost "$zone" -U administrator || true
  fi
  samba-tool dns add "$fqdn" "$zone" "$host_oct" PTR "$fqdn" -U administrator --password "${SAMBA_ADMIN_PASS:-}" 2>/dev/null || true
}

write_ddns_helper() {
  log "DHCP → Samba DNS helper"
  install -d -m 0750 /etc/kea
  cat >/usr/local/sbin/kea-samba-ddns.sh <<'EOS'
#!/usr/bin/env bash
# Called by Kea run-script hook. Uses a dedicated AD user + keytab.
set -euo pipefail
KEYTAB="${DHCP_KEYTAB:-/etc/kea/dhcp.keytab}"
PRINCIPAL="${DHCP_PRINCIPAL:-}"
NAMESERVER="${DHCP_NAMESERVER:-localhost}"
ZONE="${DHCP_ZONE:-}"
CCACHE="/tmp/kea-dhcp.krb5cc"
export KRB5CCNAME="FILE:${CCACHE}"

event="${1:-${KEA_EVENT:-}}"
ip="${KEA_LEASE4_ADDRESS:-}"
name="${KEA_LEASE4_HOSTNAME:-}"
name="${name%%.*}"

[[ -n "$PRINCIPAL" && -n "$ZONE" ]] || exit 0
[[ -n "$ip" ]] || exit 0

kinit -k -t "$KEYTAB" "$PRINCIPAL" >/dev/null

host_oct=${ip##*.}
IFS=. read -r a b c d <<<"$ip"
rev="${c}.${b}.${a}.in-addr.arpa"

add() {
  [[ -n "$name" ]] || return 0
  samba-tool dns add "$NAMESERVER" "$ZONE" "$name" A "$ip" -k yes 2>/dev/null || \
    samba-tool dns update "$NAMESERVER" "$ZONE" "$name" A "$ip" "$ip" -k yes 2>/dev/null || true
  samba-tool dns add "$NAMESERVER" "$rev" "$host_oct" PTR "${name}.${ZONE}" -k yes 2>/dev/null || true
}
del() {
  [[ -n "$name" ]] || return 0
  samba-tool dns delete "$NAMESERVER" "$ZONE" "$name" A "$ip" -k yes 2>/dev/null || true
  samba-tool dns delete "$NAMESERVER" "$rev" "$host_oct" PTR "${name}.${ZONE}" -k yes 2>/dev/null || true
}

case "$event" in
  leases4_committed|lease4_renew|lease4_rebind) add ;;
  lease4_expire|lease4_release) del ;;
esac
EOS
  chmod 0755 /usr/local/sbin/kea-samba-ddns.sh
}

configure_dhcp_user() {
  log "AD user for DHCP DNS updates"
  local pass
  pass="$(openssl rand -base64 24)"
  if ! samba-tool user show dhcp >/dev/null 2>&1; then
    samba-tool user create dhcp "$pass" --description="Unprivileged DNS updates from Kea"
    samba-tool user setexpiry dhcp --noexpiry
    samba-tool group addmembers DnsAdmins dhcp || true
  fi
  samba-tool domain exportkeytab --principal="dhcp@${REALM}" /etc/kea/dhcp.keytab
  chmod 400 /etc/kea/dhcp.keytab
  # kea typically runs as kea or root; keep keytab root-readable
}

configure_kea() {
  log "Kea DHCPv4"
  local hook
  hook="$(find /usr/lib /usr/lib64 -name 'libdhcp_run_script.so' 2>/dev/null | head -n1 || true)"
  [[ -n "$hook" ]] || die "Kea run-script hook library not found (libdhcp_run_script.so)"

  cat >/etc/kea/kea-dhcp4.conf <<EOF
{
  "Dhcp4": {
    "interfaces-config": { "interfaces": [ "${INTERFACE}" ] },
    "lease-database": { "type": "memfile", "persist": true, "name": "/var/lib/kea/kea-leases4.csv" },
    "valid-lifetime": 28800,
    "option-data": [
      { "name": "routers", "data": "${GATEWAY}" },
      { "name": "domain-name-servers", "data": "${IP_ADDRESS}" },
      { "name": "domain-name", "data": "${realm_dns}" },
      { "name": "domain-search", "data": "${realm_dns}" },
      { "name": "ntp-servers", "data": "${IP_ADDRESS}" }
    ],
    "subnet4": [
      {
        "id": 1,
        "subnet": "${IP_ADDRESS%.*}.0/${PREFIX}",
        "pools": [ { "pool": "${DHCP_RANGE_START} - ${DHCP_RANGE_END}" } ]
      }
    ],
    "hooks-libraries": [
      {
        "library": "${hook}",
        "parameters": {
          "name": "/usr/local/sbin/kea-samba-ddns.sh",
          "sync": false
        }
      }
    ],
    "loggers": [
      { "name": "kea-dhcp4", "severity": "INFO", "output_options": [ { "output": "stdout" } ] }
    ]
  }
}
EOF
  cat >/etc/kea/kea-env <<EOF
DHCP_KEYTAB=/etc/kea/dhcp.keytab
DHCP_PRINCIPAL=dhcp@${REALM}
DHCP_NAMESERVER=${fqdn}
DHCP_ZONE=${realm_dns}
EOF
  mkdir -p /etc/systemd/system/kea-dhcp4.service.d
  cat >/etc/systemd/system/kea-dhcp4.service.d/env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/kea/kea-env
EOF
  kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  systemctl daemon-reload
  systemctl enable --now kea-dhcp4.service
}

configure_wsdd() {
  log "wsdd"
  mkdir -p /etc/conf.d
  cat >/etc/conf.d/wsdd <<EOF
WSDD_ARGS="--workgroup ${DOMAIN} --shortname"
EOF
  systemctl enable --now wsdd.service
}

write_backup_helper() {
  log "samba-tool + restic backup helper"
  cat >/usr/local/sbin/samba-ad-backup.sh <<EOF
#!/usr/bin/env bash
# Online AD backup, then optional restic push if RESTIC_REPOSITORY is set.
set -euo pipefail
DEST=/var/backups/samba-ad
mkdir -p "\$DEST"
samba-tool domain backup online --targetdir="\$DEST" -UAdministrator
# Keep the newest few tarballs locally
ls -1t "\$DEST"/*.tar.bz2 2>/dev/null | tail -n +8 | xargs -r rm -f
if [[ -n "\${RESTIC_REPOSITORY:-}" ]]; then
  restic backup "\$DEST" ${SHARE_PATH}
fi
EOF
  chmod 0755 /usr/local/sbin/samba-ad-backup.sh
  cat >/etc/systemd/system/samba-ad-backup.service <<'EOF'
[Unit]
Description=Samba AD online backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-ad-backup.sh
EOF
  cat >/etc/systemd/system/samba-ad-backup.timer <<'EOF'
[Unit]
Description=Nightly Samba AD backup
[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now samba-ad-backup.timer
}

self_test() {
  log "Tests"
  sleep 2
  host -t SRV "_ldap._tcp.${realm_dns}." || true
  host -t SRV "_kerberos._udp.${realm_dns}." || true
  host -t A "$fqdn." || true
  smbclient //localhost/netlogon -U administrator -c ls || true
  echo
  echo "If SRV lookups failed, wait a few seconds and rerun:"
  echo "  host -t SRV _ldap._tcp.${realm_dns}."
  echo
  echo "Next: join PCs to ${REALM}. DHCP will hand out ${IP_ADDRESS} as DNS."
  echo "restic offsite: export RESTIC_REPOSITORY and RESTIC_PASSWORD, then restic init."
}

ask_admin_pass() {
  if [[ -z "${SAMBA_ADMIN_PASS:-}" ]]; then
    read -r -s -p "Samba Administrator password: " SAMBA_ADMIN_PASS
    echo
  fi
  [[ -n "${SAMBA_ADMIN_PASS}" ]] || die "empty password"
  export SAMBA_ADMIN_PASS
}

main() {
  need_root
  if [[ ! -e "/sys/class/net/${INTERFACE}" ]]; then
    echo "warning: INTERFACE=${INTERFACE} not found. Run: ip -br link" >&2
  fi
  ask_admin_pass
  install_pkgs
  set_identity
  free_dns_port
  write_resolv
  provision_domain
  install_krb5
  configure_chrony
  configure_samba_services
  write_ddns_helper
  configure_dhcp_user
  configure_kea
  configure_wsdd
  write_backup_helper
  configure_reverse_zone || true
  self_test
  log "Done"
}

main "$@"
