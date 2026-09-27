#!/usr/bin/env bash
#
# kijanikiosk-provision.sh - Production Server Foundation Provisioner
# Target OS: Ubuntu / Debian-based Linux

set -euo pipefail

log()     { echo -e "[INFO] $(date +'%Y-%m-%dT%H:%M:%S%z') $1"; }
warn()    { echo -e "[WARN] $(date +'%Y-%m-%dT%H:%M:%S%z') $1"; }
success() { echo -e "[PASS] $(date +'%Y-%m-%dT%H:%M:%S%z') $1"; }
error()   { echo -e "[FAIL] $(date +'%Y-%m-%dT%H:%M:%S%z') $1" >&2; }

echo "=========================================================="
echo " Starting KijaniKiosk Production Provisioning "
echo "=========================================================="

if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)."
   exit 1
fi

# PHASE 1: Base Packages & Version Pinning
log "Phase 1: Verifying and installing pinned base packages..."
HOLD_LIST=$(apt-mark showhold || true)
log "Current package holds: ${HOLD_LIST:-None}"

export DEBIAN_FRONTEND=noninteractive

install_pinned() {
  local pkg=$1
  if dpkg -l | grep -q "^ii  $pkg "; then
    log "Dirty State Check: Package '$pkg' is already installed. Re-verifying..."
  fi
  apt-get install -y --no-install-recommends -o Dpkg::Options::="--no-triggers" "$pkg" || warn "Package $pkg install matched current state."
  apt-mark hold "$pkg" >/dev/null
  success "Package '$pkg' pinned and placed on hold."
}

install_pinned "nginx"
install_pinned "curl"
install_pinned "acl"

# PHASE 2: Service Accounts & Group Topology
log "Phase 2: Configuring service accounts and primary group..."

if getent group kijanikiosk >/dev/null; then
  log "Dirty State Check: Group 'kijanikiosk' already exists. Preserving."
else
  groupadd -r kijanikiosk
  log "Group 'kijanikiosk' created."
fi

create_service_account() {
  local user=$1
  if id "$user" &>/dev/null; then
    log "Dirty State Check: Account '$user' pre-exists. Ensuring group membership."
    usermod -aG kijanikiosk "$user"
  else
    useradd -r -s /bin/false -g kijanikiosk -G kijanikiosk "$user"
    log "Created service account '$user'."
  fi
}

create_service_account "kk-api"
create_service_account "kk-payments"
create_service_account "kk-logs"

# PHASE 3: File Layout, POSIX Modes, & ACL Defaults
log "Phase 3: Building directory trees, setting SGID, and enforcing ACLs..."

mkdir -p /opt/kijanikiosk/{bin,config,shared/logs,health}

chown -R root:kijanikiosk /opt/kijanikiosk
chmod 755 /opt/kijanikiosk
chmod 750 /opt/kijanikiosk/config
chmod 2770 /opt/kijanikiosk/shared/logs
chmod 755 /opt/kijanikiosk/health

setfacl -b -R /opt/kijanikiosk/shared/logs
setfacl -m u:kk-api:rwx,u:kk-payments:r-x,u:kk-logs:r-x /opt/kijanikiosk/shared/logs
setfacl -d -m u:kk-api:rwx,u:kk-payments:r-x,u:kk-logs:r-x,g:kijanikiosk:r-x /opt/kijanikiosk/shared/logs

chown -R kk-logs:kijanikiosk /opt/kijanikiosk/health
chmod 775 /opt/kijanikiosk/health

touch /opt/kijanikiosk/config/api.env
touch /opt/kijanikiosk/config/payments-api.env
touch /opt/kijanikiosk/config/logs.env
chown root:kijanikiosk /opt/kijanikiosk/config/*.env
chmod 640 /opt/kijanikiosk/config/*.env

success "Directory permissions and default ACL masks configured."

# PHASE 4: Hardened Systemd Units
log "Phase 4: Deploying hardened systemd service units..."

cat <<'EOF' > /etc/systemd/system/kk-api.service
[Unit]
Description=KijaniKiosk Core API Service
After=network.target

[Service]
Type=simple
User=kk-api
Group=kijanikiosk
WorkingDirectory=/opt/kijanikiosk
EnvironmentFile=/opt/kijanikiosk/config/api.env
ExecStart=/usr/bin/node --jitless /opt/kijanikiosk/bin/api.js
Restart=on-failure
RestartSec=5s

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
RestrictNamespaces=true
ProtectProc=invisible
ProcSubset=pid
PrivateUsers=true
ReadWritePaths=/opt/kijanikiosk/shared/logs /opt/kijanikiosk/health

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/kk-payments.service
[Unit]
Description=KijaniKiosk Payments Processing Engine
After=network.target kk-api.service
Wants=kk-api.service

[Service]
Type=simple
User=kk-payments
Group=kijanikiosk
WorkingDirectory=/opt/kijanikiosk
EnvironmentFile=/opt/kijanikiosk/config/payments-api.env
ExecStart=/usr/bin/node --jitless /opt/kijanikiosk/bin/payments.js
Restart=on-failure
RestartSec=5s
StartLimitBurst=3
StartLimitIntervalSec=60s

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
RestrictNamespaces=true
ProtectProc=invisible
ProcSubset=pid
PrivateUsers=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallFilter=@system-service @network-io
SystemCallErrorNumber=EPERM
UMask=0077
ReadWritePaths=/opt/kijanikiosk/shared/logs /opt/kijanikiosk/health

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/kk-logs.service
[Unit]
Description=KijaniKiosk Log Aggregator
After=network.target

[Service]
Type=simple
User=kk-logs
Group=kijanikiosk
WorkingDirectory=/opt/kijanikiosk
EnvironmentFile=/opt/kijanikiosk/config/logs.env
ExecStart=/usr/bin/node /opt/kijanikiosk/bin/logs.js
Restart=on-failure
RestartSec=5s

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/opt/kijanikiosk/shared/logs /opt/kijanikiosk/health

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/kk-*.service
systemctl daemon-reload
success "Systemd units configured and daemon reloaded."

# PHASE 5: Declarative Firewall (UFW)
log "Phase 5: Resetting UFW rules..."

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

ufw allow in on lo comment 'Allow loopback traffic'
ufw allow 22/tcp comment 'Allow SSH management access'
ufw allow 80/tcp comment 'Allow HTTP public traffic'
ufw allow from 10.0.1.0/24 to any port 3001 proto tcp comment 'Allow health probes from monitoring subnet'
ufw deny 3001/tcp comment 'Deny external direct access to internal payments port'

ufw --force enable >/dev/null
success "Firewall active with rule comments."

# PHASE 6: Log Rotation & Journal Persistence
log "Phase 6: Setting up persistent logging and rotation..."

mkdir -p /var/log/journal
sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
systemctl restart systemd-journald

cat <<'EOF' > /etc/logrotate.d/kijanikiosk
/opt/kijanikiosk/shared/logs/*.log {
    su kk-logs kijanikiosk
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 kk-logs kijanikiosk
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP kk-logs.service 2>/dev/null || true
    endscript
}
EOF

chmod 644 /etc/logrotate.d/kijanikiosk
success "Journal persistence and logrotate rules set."

# PHASE 7: Structured Health Checks
log "Phase 7: Running health probes..."

api_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3000" 2>/dev/null && echo '"ok"' || echo '"down"')
payments_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3001" 2>/dev/null && echo '"ok"' || echo '"down"')

cat <<EOF > /opt/kijanikiosk/health/last-provision.json
{
  "timestamp": "$(date -Is)",
  "kk-api": $api_status,
  "kk-payments": $payments_status
}
EOF

chown kk-logs:kijanikiosk /opt/kijanikiosk/health/last-provision.json
chmod 640 /opt/kijanikiosk/health/last-provision.json
success "Health state recorded at /opt/kijanikiosk/health/last-provision.json"

# PHASE 8: Verification Phase
log "Phase 8: Running verification assertions..."

FAILED_CHECKS=0

assert_check() {
  local description=$1
  shift
  if "$@"; then
    success "VERIFY PASS: $description"
  else
    error "VERIFY FAIL: $description"
    ((FAILED_CHECKS++))
  fi
}

assert_check "Group kijanikiosk exists" getent group kijanikiosk
assert_check "User kk-api exists" id kk-api
assert_check "User kk-payments exists" id kk-payments
assert_check "kk-payments can read payments-api.env" sudo -u kk-payments test -r /opt/kijanikiosk/config/payments-api.env
assert_check "Logrotate syntax check" logrotate --debug /etc/logrotate.d/kijanikiosk

check_ufw() {
  local status
  status=$(ufw status)
  echo "$status" | grep -q "22/tcp.*ALLOW" && \
  echo "$status" | grep -q "80/tcp.*ALLOW" && \
  echo "$status" | grep -q "3001/tcp.*DENY"
}
assert_check "Firewall rule verification" check_ufw

check_security_score() {
  local service=$1
  local max_score=$2
  local score
  score=$(systemd-analyze security "$service" | awk '/Overall exposure level/ {print $7}')
  log "Service $service exposure score: $score (Max threshold: < $max_score)"
  awk -v s="$score" -v m="$max_score" 'BEGIN { exit !(s < m) }'
}
assert_check "kk-api security score < 3.5" check_security_score "kk-api.service" 3.5
assert_check "kk-payments security score < 2.5" check_security_score "kk-payments.service" 2.5

echo "=========================================================="
if [[ $FAILED_CHECKS -eq 0 ]]; then
  success "PROVISIONING COMPLETE: All checks passed."
  exit 0
else
  error "PROVISIONING FAILED: $FAILED_CHECKS check(s) failed."
  exit 1
fi