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

# Container image tag. Defaults to the tag the compose files came from, which
# is almost always what you want; they are only split deliberately.
: "${TRACECAT_IMAGE_TAG:=$TRACECAT_VERSION}"

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
# Answered without a scheme on purpose: env.sh strips whatever scheme you give
# it ("sed -E 's/^\s*.*:\/\///g'") and then hardcodes base_url="http://${hostname}".
# There is no answer that makes it emit https, so the URLs are corrected after
# it runs instead.
printf '%s\n%s\n%s\n%s\n' \
    "$PRODUCTION_MODE" "$APP_HOST" "$POSTGRES_SSL" "$SUPERADMIN_EMAIL" \
    | bash ./env.sh || fail "env.sh exited non-zero"

[[ -f .env ]] || fail "env.sh did not produce a .env file"

# Replace a key outright rather than sed-substituting into it: the values are
# operator-supplied and may contain characters that are meaningful in a sed
# replacement. Only the key, which is a fixed literal, reaches sed here.
#
# The value is single-quoted because Docker Compose interpolates .env: an
# unquoted secret containing `$` silently loses everything from the $ onward,
# and one containing a space or `#` can be truncated. Compose treats a
# single-quoted value as a literal and strips the quotes. A value containing a
# single quote of its own cannot be expressed this way, so reject it rather
# than write a broken file.
#
# Position is preserved when the key already exists, and that matters: Compose
# interpolates variables *inside* .env in file order, and Tracecat's .env chains
# them — PUBLIC_API_URL is ${PUBLIC_APP_URL}/api, NEXT_PUBLIC_API_URL is
# ${PUBLIC_API_URL}, TRACECAT__ALLOW_ORIGINS ends in ${PUBLIC_APP_URL}. Deleting
# a key and appending it at the end would leave every earlier reference
# resolving to an empty string, and the UI would fetch from nowhere.
dotenv_set() {
    local key="$1" value="$2"
    case "$value" in
        *"'"*) fail "${key} contains a single quote, which cannot be written safely to .env. Set it directly in ${INSTALL_DIR}/.env after the deploy." ;;
    esac
    if grep -q "^${key}=" .env; then
        python3 - "$key" "$value" <<'PYENV'
import sys
key, value = sys.argv[1], sys.argv[2]
out, done = [], False
for line in open(".env"):
    if line.startswith(key + "=") and not done:
        out.append("%s='%s'\n" % (key, value)); done = True
    elif line.startswith(key + "="):
        continue  # drop any duplicate further down
    else:
        out.append(line)
open(".env", "w").writelines(out)
PYENV
    else
        printf "%s='%s'\n" "$key" "$value" >> .env
    fi
}

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

# env.sh can only produce http:// (it strips the scheme from the answer and
# rebuilds the URL with a literal "http://"), so with TLS on, every URL it just
# wrote is wrong. Fix them here: ALLOW_ORIGINS and PUBLIC_API_URL are derived
# from this value, and PUBLIC_API_URL is what the MCP server's own OIDC issuer
# is built from.
if [[ "${ENABLE_TLS:-n}" == "y" ]]; then
    got_url="https://${APP_HOST}"
    dotenv_set PUBLIC_APP_URL "$got_url"
    dotenv_set PUBLIC_API_URL "${got_url}/api"
    log "  Rewrote the URLs env.sh wrote as http:// to ${got_url}"
fi
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


# ── Turn on TLS ────────────────────────────────────────────────────────────
# Caddy gets its own certificate from Let's Encrypt. Setting BASE_DOMAIN to a
# hostname is what switches its automatic HTTPS on: it then listens on 443 and
# redirects 80, serving the ACME challenge there. env.sh leaves BASE_DOMAIN as
# ":${PUBLIC_APP_PORT}", a port-only address, which serves plain HTTP forever.
# The override is assembled from fragments just before the stack comes up. Two
# sections contribute services to it, and a YAML document cannot carry two
# top-level "services:" keys — appending one would silently discard the other.
rm -f docker-compose.override.yml "${INSTALL_DIR}/.override.services" "${INSTALL_DIR}/.override.volumes"
if [[ "${ENABLE_TLS:-n}" == "y" ]]; then
    dotenv_set PUBLIC_APP_PORT 443
    dotenv_set BASE_DOMAIN "$APP_HOST"
    app_port=443
    log "  TLS on: Caddy will request a certificate for ${APP_HOST}"

    # Caddy global options have to be the first block in the file.
    if ! grep -q "^{" Caddyfile; then
        # Defaulted rather than bare: the script runs under `set -u`, and an
        # instance whose deploy.env predates this variable would otherwise die
        # here rather than fall back.
        acme_email="${ACME_EMAIL:-$SUPERADMIN_EMAIL}"
        printf '{\n\temail %s\n}\n\n%s' "$acme_email" "$(cat Caddyfile)" > Caddyfile.new
        mv Caddyfile.new Caddyfile
        log "  ACME account email is ${acme_email}"
    fi

    # Two things the stock compose file does not do: publish 80 (it publishes
    # PUBLIC_APP_PORT only, now 443) and keep Caddy's /data across container
    # recreates. Without the volume every recreate re-issues the certificate,
    # and Let's Encrypt allows five identical certificates a week.
    cat >> "${INSTALL_DIR}/.override.services" <<EOF
  caddy:
    ports:
      - "80:80"
    volumes:
      - caddy-data:/data
      - caddy-config:/config
EOF
    cat >> "${INSTALL_DIR}/.override.volumes" <<EOF
  caddy-data:
  caddy-config:
EOF
fi

# ── Pin the container images ───────────────────────────────────────────────
# Upstream's docker-compose.yml reads ${TRACECAT__IMAGE_TAG} and falls back to a
# tag hardcoded in that file. The fallback is not always the tag the compose
# file itself was fetched from — at the 1.0.0 tag it is 1.0.0-beta.37 — so
# leaving it unset silently runs a different version of the code than the
# configuration was written for. Set it explicitly from Terraform.
dotenv_set TRACECAT__IMAGE_TAG "$TRACECAT_IMAGE_TAG"
log "  TRACECAT__IMAGE_TAG is ${TRACECAT_IMAGE_TAG}"

# ── The MCP server ─────────────────────────────────────────────────────────
# Nothing to configure. From 1.0.0-beta.51 the mcp container authenticates
# against an OIDC issuer Tracecat runs itself, on the API server at
# /api/oauth/mcp, with a client secret derived from USER_AUTH_SECRET — which
# env.sh has already generated by this point. The issuer URL is built from
# PUBLIC_API_URL, corrected above, so it is already right.
#
# Older tags needed an external identity provider and this script used to
# deploy a Dex container to be one. That is gone. If TRACECAT_VERSION is pinned
# to a tag older than beta.51 the mcp container will crash-loop on
# "OIDC_ISSUER must be configured for the MCP server" and /mcp will 502.
#
# TRACECAT_MCP__BASE_URL is deliberately NOT set: beta.51 removed it from the
# compose file, and a leftover value in .env is at best ignored.
if [[ "${ENABLE_TLS:-n}" == "y" ]]; then
    mcp_configured=1
    log "  /mcp will authenticate against Tracecat's own issuer at ${got_url}/api/oauth/mcp"
    log "  Sign in as ${SUPERADMIN_EMAIL}, or mint a personal access token in the UI."
    log "  MCP authorises against an existing Tracecat user, so sign up first."
else
    mcp_configured=0
    log "  /mcp is unavailable: the MCP server refuses an issuer URL that is not"
    log "  https, and this deploy has no certificate. Everything else works."
fi

# ── Assemble the compose override ──────────────────────────────────────────
if [[ -s "${INSTALL_DIR}/.override.services" ]]; then
    {
        echo "# Generated by tracecat-bootstrap."
        echo "services:"
        cat "${INSTALL_DIR}/.override.services"
        if [[ -s "${INSTALL_DIR}/.override.volumes" ]]; then
            echo
            echo "volumes:"
            cat "${INSTALL_DIR}/.override.volumes"
        fi
    } > "${INSTALL_DIR}/docker-compose.override.yml"
    rm -f "${INSTALL_DIR}/.override.services" "${INSTALL_DIR}/.override.volumes"
    docker compose config >/dev/null 2>&1 \
        || fail "the generated docker-compose.override.yml is not valid; see ${INSTALL_DIR}/docker-compose.override.yml"
    log "Wrote docker-compose.override.yml and compose accepted it"
fi

# ── Bring the stack up ─────────────────────────────────────────────────────
log "Starting the Tracecat stack (this pulls ~15 images and takes a few minutes)"
docker compose up -d || fail "docker compose up failed"

# ── Wait until it actually answers ─────────────────────────────────────────
# Probe port 80 either way: with TLS Caddy answers there with a 308 to https,
# which is proof enough that it is up, and https://localhost would fail the
# certificate's hostname.
log "Waiting for the UI to respond"
ready=0
for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://localhost:80/" || echo 000)
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
tracecat_image_tag=${TRACECAT_IMAGE_TAG}
mcp_configured=${mcp_configured}
completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

# No generated credentials live here any more, but it still names the deployment
# and the superadmin, so it is not world readable.
chmod 0600 /etc/tracecat/READY

log "=== Tracecat is up at ${got_url} ==="
log "Tracecat ${TRACECAT_VERSION}, images ${TRACECAT_IMAGE_TAG}"
log "First login: ${SUPERADMIN_EMAIL} (set a password via the sign-up form)"
if (( mcp_configured == 1 )); then
    log "MCP endpoint: ${got_url}/mcp — Tracecat issues its own tokens, no IdP to set up"
    log "  Sign up in the UI as ${SUPERADMIN_EMAIL} FIRST. MCP authorises against an"
    log "  existing Tracecat user, so /mcp returns 401 until that account exists."
    log "  Then authenticate in the browser, or mint a personal access token under"
    log "  ${got_url}/workspaces/<workspace-id>/mcp."
else
    log "MCP endpoint: unavailable — /mcp needs an https issuer, so it needs app_hostname"
fi
log "Secrets live in ${INSTALL_DIR}/.env — back that file up before you lose the instance."
