#!/usr/bin/env bash
# Unattended installer for the Tracecat automation platform.
#
# Run by cloud-init on first boot. Reads its configuration from
# /etc/tracecat/deploy.env, which cloud-init writes from Terraform variables.
#
# Everything this script does is logged to /var/log/tracecat-bootstrap.log.
# On success it writes /etc/tracecat/READY. If that file is missing, the install
# did not finish — read the log.
set -euo pipefail

readonly LOG=/var/log/tracecat-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

log "=== Tracecat bootstrap starting ==="

# ── Configuration ───────────────────────────────────────────────────────────
[[ -f /etc/tracecat/deploy.env ]] || fail "/etc/tracecat/deploy.env is missing"
# shellcheck disable=SC1091
source /etc/tracecat/deploy.env

: "${TRACECAT_VERSION:?not set in deploy.env}"
: "${SUPERADMIN_EMAIL:?not set in deploy.env}"
: "${INSTALL_DIR:=/opt/tracecat}"
: "${APP_HOST:=}"          # explicit hostname/IP, or empty to autodetect
: "${PRODUCTION_MODE:=y}"
: "${POSTGRES_SSL:=n}"

readonly RAW="https://raw.githubusercontent.com/TracecatHQ/tracecat/${TRACECAT_VERSION}"

# ── Work out the address the browser will use ───────────────────────────────
# This has to be right or the UI loads and every API call fails CORS. Tracecat
# requires PUBLIC_APP_URL and PUBLIC_API_URL to match the origin the browser
# actually uses, and it bakes them into .env here at first boot.

# IMDSv2 only — the instance is launched with http_tokens = "required".
imds_public_ipv4() {
    local token ip
    token=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" --max-time 5 2>/dev/null) || return 1
    ip=$(curl -sS -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
        "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null) || return 1
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

observed_ip=$(imds_public_ipv4 || true)
log "Instance metadata reports public IPv4: ${observed_ip:-<none>}"

if [[ -z "$APP_HOST" ]]; then
    # No Elastic IP and no hostname from Terraform — metadata is the only source.
    [[ -n "$observed_ip" ]] || fail "APP_HOST was not supplied and instance metadata returned no public IPv4. Is this instance in a public subnet with a public address?"
    APP_HOST="$observed_ip"
    log "APP_HOST not supplied; using the metadata address ${APP_HOST}"

elif is_ipv4 "$APP_HOST"; then
    # Terraform baked in an Elastic IP. Confirm it actually reaches this box.
    #
    # A mismatch right now is normal for a few seconds: Terraform allocates the
    # EIP before the instance so its address can go into user_data, and the
    # association lands in parallel with this boot. So poll rather than judging
    # on the first read.
    if [[ "$observed_ip" != "$APP_HOST" ]]; then
        log "Configured address ${APP_HOST} does not match metadata yet; waiting for the Elastic IP association"
        for _ in $(seq 1 12); do
            sleep 5
            observed_ip=$(imds_public_ipv4 || true)
            [[ "$observed_ip" == "$APP_HOST" ]] && break
        done
    fi

    if [[ "$observed_ip" == "$APP_HOST" ]]; then
        log "Confirmed: ${APP_HOST} is this instance's public address"
    else
        log "WARNING: configured for ${APP_HOST} but metadata reports ${observed_ip:-<none>}."
        log "WARNING: Tracecat is about to bake ${APP_HOST} into .env. If that address does"
        log "WARNING: not reach this instance, the UI will load and every API call will fail"
        log "WARNING: CORS. Check the Elastic IP association, then see docs/troubleshooting.md"
    fi

else
    # A DNS name. We cannot resolve it to this instance from here with any
    # confidence, so record both and let the operator check the record.
    log "Serving on hostname ${APP_HOST}; ensure its DNS record points at ${observed_ip:-this instance}"
fi

[[ -n "$APP_HOST" ]] || fail "APP_HOST is empty — no public address to serve on"
log "Tracecat will be served at http://${APP_HOST}"

# ── Wait for the package system to settle ───────────────────────────────────
# A fresh Ubuntu instance runs unattended-upgrades and apt-daily on boot. If we
# race them we get "Could not get lock /var/lib/dpkg/lock-frontend".
log "Waiting for apt/dpkg locks to clear"
for _ in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

export DEBIAN_FRONTEND=noninteractive

apt_retry() {
    local tries=0
    until apt-get "$@"; do
        tries=$((tries + 1))
        (( tries >= 5 )) && fail "apt-get $* failed after $tries attempts"
        log "apt-get $* failed; retry $tries in 15s"
        sleep 15
    done
}

# ── Docker, from Docker's own repository ────────────────────────────────────
# Tracecat needs Docker 26+ and Compose 2.29+. Ubuntu's docker.io package is
# older than that on most releases, so use the upstream repo.
log "Installing Docker Engine and the Compose plugin"
apt_retry update
apt_retry install -y ca-certificates curl gnupg openssl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc || fail "could not fetch Docker's GPG key"
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091
codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

apt_retry update
apt_retry install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker || fail "docker failed to start"

log "docker:  $(docker --version)"
log "compose: $(docker compose version)"

# Let the default user drive docker without sudo.
if id ubuntu &>/dev/null; then
    usermod -aG docker ubuntu
    log "added user 'ubuntu' to the docker group"
fi

# ── Fetch Tracecat's own deployment files ──────────────────────────────────
# These are pulled from the pinned tag rather than vendored, so this repo does
# not silently ship a stale copy of someone else's compose file.
log "Fetching Tracecat ${TRACECAT_VERSION} deployment files into ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

for f in env.sh .env.example Caddyfile docker-compose.yml; do
    curl -fsSL --retry 5 --retry-delay 5 -o "$f" "${RAW}/${f}" \
        || fail "could not download ${f} from ${RAW}"
    log "  fetched ${f}"
done
chmod +x env.sh

# ── Generate .env without a human ──────────────────────────────────────────
# env.sh is interactive. On a host with no pre-existing .env it asks exactly
# three questions, in this order:
#   1. Use production mode? (y/n, default y)
#   2. Set PUBLIC_APP_URL to (default localhost)
#   3. Require PostgreSQL SSL mode? (y/n, default n)
#   4. Email address for the first user (superadmin)
# We answer them on stdin. env.sh generates the four secrets itself with
# openssl, which is why we do not hand-roll the .env file.
# If a .env already exists (a re-run), env.sh asks an EXTRA question first:
# "A .env file already exists. Do you want to overwrite it? (y/n)".
#
# Tested: this does NOT currently shift our answers, but only by accident. That
# prompt uses `read -n 1`, which consumes the single "y" and leaves the newline
# behind; the next prompt reads that empty line and falls back to its default,
# which happens to be the "y" we wanted for production mode. Change either the
# default or the `-n 1` upstream and every subsequent answer lands one position
# out. Move the old file aside so the sequence is always the four we expect,
# rather than relying on that coincidence.
if [[ -f .env ]]; then
    backup=".env.bak.$(date -u '+%Y%m%dT%H%M%SZ')"
    mv .env "$backup"
    log "Existing .env moved to ${INSTALL_DIR}/${backup} so env.sh prompts stay predictable"
fi

log "Running env.sh non-interactively"
printf '%s\n%s\n%s\n%s\n' \
    "$PRODUCTION_MODE" "$APP_HOST" "$POSTGRES_SSL" "$SUPERADMIN_EMAIL" \
    | bash ./env.sh || fail "env.sh exited non-zero"

[[ -f .env ]] || fail "env.sh did not produce a .env file"

# ── Verify the answers actually landed ─────────────────────────────────────
# Piping answers into an interactive script is brittle by nature: if upstream
# adds or reorders a prompt, the values silently shift. Rather than find out
# later via a confusing CORS error, assert the result now.
log "Validating the generated .env"
check_set() {
    local key="$1" value
    value=$(grep -E "^${key}=" .env | head -1 | cut -d= -f2-)
    [[ -n "$value" ]] || fail "${key} is empty in .env — env.sh prompts may have changed upstream. Inspect ${INSTALL_DIR}/.env and see docs/troubleshooting.md"
    echo "$value"
}

for key in TRACECAT__SERVICE_KEY TRACECAT__SIGNING_SECRET \
           TRACECAT__DB_ENCRYPTION_KEY USER_AUTH_SECRET; do
    check_set "$key" >/dev/null
    log "  ${key} is set"
done

got_email=$(check_set TRACECAT__AUTH_SUPERADMIN_EMAIL)
[[ "$got_email" == "$SUPERADMIN_EMAIL" ]] \
    || fail "superadmin email is '${got_email}', expected '${SUPERADMIN_EMAIL}' — the prompt order in env.sh has changed"
log "  superadmin email is ${got_email}"

got_url=$(check_set PUBLIC_APP_URL)
[[ "$got_url" == *"$APP_HOST"* ]] \
    || fail "PUBLIC_APP_URL is '${got_url}', which does not contain '${APP_HOST}' — the prompt order in env.sh has changed"
log "  PUBLIC_APP_URL is ${got_url}"

app_port=$(grep -E '^PUBLIC_APP_PORT=' .env | head -1 | cut -d= -f2- || true)
app_port=${app_port:-80}
log "  Caddy will publish port ${app_port}"

# ── Work around an upstream bug in env.sh ──────────────────────────────────
# As of tag 1.0.0, env.sh line 185 reads:
#
#   new_origins=$(echo "$new_origins" | tr ',' '\n' | sort -u | ...)
#   dotenv_replace "TRACECAT__ALLOW_ORIGINS" "$new_origins" "$env_file"
#
# but $new_origins is never assigned anywhere in the script. It expands to the
# empty string and overwrites the sensible default that .env.example ships
# (http://localhost:3000,${PUBLIC_APP_URL}), leaving the API with an empty CORS
# allowlist. The UI then loads but every API call it makes is rejected.
#
# This affects anyone following the documented interactive install too, not
# just this unattended one. Remove this block once upstream fixes it.
origins=$(grep -E '^TRACECAT__ALLOW_ORIGINS=' .env | head -1 | cut -d= -f2- || true)
if [[ -z "$origins" ]]; then
    log "  TRACECAT__ALLOW_ORIGINS was blanked by env.sh; setting it to ${got_url}"
    sed -i "s|^TRACECAT__ALLOW_ORIGINS=.*|TRACECAT__ALLOW_ORIGINS=${got_url}|" .env
    origins=$(grep -E '^TRACECAT__ALLOW_ORIGINS=' .env | head -1 | cut -d= -f2-)
    [[ -n "$origins" ]] || fail "could not set TRACECAT__ALLOW_ORIGINS in .env"
fi
log "  TRACECAT__ALLOW_ORIGINS is ${origins}"

# ── Bring the stack up ─────────────────────────────────────────────────────
log "Starting the Tracecat stack (this pulls ~15 images and takes a few minutes)"
docker compose up -d || fail "docker compose up failed"

# ── Wait until it actually answers ─────────────────────────────────────────
log "Waiting for the UI to respond on port ${app_port}"
ready=0
for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://localhost:${app_port}/" || echo 000)
    if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
        log "UI responded with HTTP ${code} after ~$((i * 10))s"
        ready=1
        break
    fi
    sleep 10
done

if (( ready == 0 )); then
    log "UI did not respond within ~15 minutes. Container status:"
    docker compose ps || true
    fail "stack did not become healthy — see 'docker compose logs' in ${INSTALL_DIR}"
fi

# ── Done ───────────────────────────────────────────────────────────────────
cat > /etc/tracecat/READY <<EOF
tracecat_version=${TRACECAT_VERSION}
install_dir=${INSTALL_DIR}
app_url=http://${APP_HOST}
app_port=${app_port}
instance_public_ipv4=${observed_ip:-unknown}
superadmin_email=${SUPERADMIN_EMAIL}
completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

log "=== Tracecat is up at http://${APP_HOST} ==="
log "First login: ${SUPERADMIN_EMAIL} (set a password via the sign-up form)"
log "Secrets live in ${INSTALL_DIR}/.env — back that file up before you lose the instance."
