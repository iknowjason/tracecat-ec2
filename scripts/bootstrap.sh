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

# MCP server. Optional — unset means the mcp container will not start, which
# leaves /mcp returning 502 and the rest of the stack working normally.
: "${OIDC_ISSUER:=}"
: "${OIDC_CLIENT_ID:=}"
: "${OIDC_CLIENT_SECRET:=}"
: "${OIDC_SCOPES:=openid profile email}"

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
# With TLS the load balancer terminates HTTPS and forwards plain HTTP to Caddy,
# so the stack still listens on 80 — but every URL it advertises must be https,
# or the browser blocks mixed content and the MCP server refuses its own issuer.
if [[ "${ENABLE_TLS:-n}" == "y" ]]; then
    url_answer="https://${APP_HOST}"
else
    url_answer="$APP_HOST"
fi
printf '%s\n%s\n%s\n%s\n' \
    "$PRODUCTION_MODE" "$url_answer" "$POSTGRES_SSL" "$SUPERADMIN_EMAIL" \
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
dotenv_set() {
    local key="$1" value="$2"
    case "$value" in
        *"'"*) fail "${key} contains a single quote, which cannot be written safely to .env. Set it directly in ${INSTALL_DIR}/.env after the deploy." ;;
    esac
    sed -i "/^${key}=/d" .env
    printf "%s='%s'\n" "$key" "$value" >> .env
}

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

# ── Configure the MCP server ───────────────────────────────────────────────
# Tracecat's mcp container is an OIDC proxy — it forwards authorization to an
# external IdP rather than issuing tokens itself. Without an issuer it raises
#
#   OIDC_ISSUER must be configured for the MCP server.
#
# retries three times, exits, and crash-loops under `restart: on-failure:3`.
# Caddy then answers an empty-bodied 502 on /mcp while every other route is
# fine, which reads like a routing fault and is not one.
#
# env.sh does not prompt for any of this, so the values come from Terraform via
# deploy.env. There is nothing to generate: they identify a client registered
# with someone else's identity provider.


# The compose file falls back to ${PUBLIC_URL:-http://localhost:${PUBLIC_APP_PORT:-80}}
# for this, and env.sh sets PUBLIC_APP_URL — not PUBLIC_URL. So left alone the
# MCP server advertises localhost to external clients. Set it either way.
dotenv_set TRACECAT_MCP__BASE_URL "$got_url"
log "  TRACECAT_MCP__BASE_URL is ${got_url}"

mcp_builtin=0
mcp_failure=""
effective_issuer=""
if [[ -n "$OIDC_ISSUER" ]]; then
    if [[ -z "$OIDC_CLIENT_ID" || -z "$OIDC_CLIENT_SECRET" ]]; then
        fail "OIDC_ISSUER is set but OIDC_CLIENT_ID and/or OIDC_CLIENT_SECRET are empty. The MCP server needs all three; set them in terraform.tfvars or leave all three unset."
    fi
    dotenv_set OIDC_ISSUER "${OIDC_ISSUER%/}"
    dotenv_set OIDC_CLIENT_ID "$OIDC_CLIENT_ID"
    dotenv_set OIDC_CLIENT_SECRET "$OIDC_CLIENT_SECRET"
    dotenv_set OIDC_SCOPES "$OIDC_SCOPES"
    effective_issuer="${OIDC_ISSUER%/}"
    log "  MCP server will authenticate against ${effective_issuer}"
    log "  OIDC scopes: ${OIDC_SCOPES} (the server adds offline_access itself)"
    mcp_configured=1
elif [[ "${BUILTIN_IDP:-n}" == "y" ]]; then
    # The MCP SDK validates its own issuer URL and rejects anything that is not
    # https (mcp/server/auth/routes.py, RFC 8414, localhost the only exemption).
    # Terraform refuses this combination too; this is the second line of defence.
    [[ "${ENABLE_TLS:-n}" == "y" ]] \
        || fail "the MCP server needs an https issuer, so the built-in provider requires app_hostname. Set it, or set enable_mcp = false."

    # Dex sits behind Caddy on the shared network rather than on a port of its
    # own: one certificate, one open port, and the issuer is simply a path on
    # the public URL.
    idp_issuer="${got_url}/dex"
    idp_client_id="tracecat-mcp"
    idp_client_secret="$(openssl rand -hex 32)"
    idp_password="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    idp_user_id="$(cat /proc/sys/kernel/random/uuid)"

    # Dex stores static passwords as bcrypt, which neither the AMI nor openssl
    # can produce. htpasswd -B can, and the httpd image is a smaller detour than
    # installing a Python bcrypt toolchain for one hash.
    idp_hash="$(docker run --rm httpd:2.4-alpine htpasswd -nbBC 10 mcp "$idp_password" | cut -d: -f2-)" \
        || fail "could not generate the bcrypt hash for the MCP login"
    [[ -n "$idp_hash" ]] || fail "bcrypt hash for the MCP login came back empty"

    mkdir -p "${INSTALL_DIR}/dex"
    # Single-quoted YAML scalars: a bcrypt hash is full of $ and the client
    # secret is hex, and neither ever contains a single quote.
    cat > "${INSTALL_DIR}/dex/config.yaml" <<EOF
# Generated by tracecat-bootstrap. The identity provider behind /mcp.
#
# storage.type is memory: restarting this container signs every MCP client out,
# which beats fighting volume ownership on a box that is rebuilt from Terraform
# anyway. Sessions do not survive a reboot.
issuer: ${idp_issuer}
storage:
  type: memory
web:
  http: 0.0.0.0:5556
oauth2:
  skipApprovalScreen: true
staticClients:
  - id: ${idp_client_id}
    name: Tracecat MCP
    secret: '${idp_client_secret}'
    redirectURIs:
      - ${got_url}/auth/callback
enablePasswordDB: true
staticPasswords:
  - email: '${SUPERADMIN_EMAIL}'
    hash: '${idp_hash}'
    username: mcp
    userID: ${idp_user_id}
EOF
    # The config holds the client secret and the bcrypt hash, so it does not go
    # world readable. The dex image runs as a non-root user and bind mounts keep
    # host ownership on Linux, so root:root 0640 is simply unreadable to it —
    # dex loops on "open etc/dex/config.yaml: permission denied". The image
    # declares its user by name ("dex:dex"), which means nothing to chown here,
    # so ask the image for the number and survive a version bump.
    chmod 0640 "${INSTALL_DIR}/dex/config.yaml"
    dex_uid="$(docker run --rm --entrypoint id "${MCP_IDP_IMAGE:-ghcr.io/dexidp/dex:v2.45.1}" -u 2>/dev/null || true)"
    dex_gid="$(docker run --rm --entrypoint id "${MCP_IDP_IMAGE:-ghcr.io/dexidp/dex:v2.45.1}" -g 2>/dev/null || true)"
    if [[ "$dex_uid" =~ ^[0-9]+$ && "$dex_gid" =~ ^[0-9]+$ ]]; then
        chown "${dex_uid}:${dex_gid}" "${INSTALL_DIR}/dex/config.yaml"
        log "  dex config owned by ${dex_uid}:${dex_gid}, the image's own user"
    else
        # Readable by dex whatever it runs as, rather than a container that
        # crash-loops. Everything in here is also in .env alongside it.
        chmod 0644 "${INSTALL_DIR}/dex/config.yaml"
        log "  WARNING: could not read the dex image's uid; config left 0644"
    fi

    cat >> "${INSTALL_DIR}/.override.services" <<EOF
  dex:
    image: ${MCP_IDP_IMAGE:-ghcr.io/dexidp/dex:v2.45.1}
    restart: unless-stopped
    command: ["dex", "serve", "/etc/dex/config.yaml"]
    volumes:
      - ./dex/config.yaml:/etc/dex/config.yaml:ro
    networks:
      - core

  mcp:
    # Reach Caddy on this box rather than out through the internet gateway and
    # back: traffic to our own public address returns with a source the security
    # group rejects. The hostname is what makes this possible — the certificate
    # matches it either way, so TLS still verifies.
    extra_hosts:
      - "${APP_HOST}:host-gateway"
    depends_on:
      dex:
        condition: service_started
EOF

    # Caddy fronts dex, so the route has to exist. Inserted before the catch-all
    # to the UI; if upstream reshapes the Caddyfile this fails loudly rather
    # than silently producing a stack with no /dex.
    grep -q "reverse_proxy http://ui:3000" Caddyfile \
        || fail "Caddyfile no longer ends with the UI catch-all; the /dex route cannot be placed"
    python3 - "$PWD/Caddyfile" <<'PYDEX'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "\treverse_proxy http://ui:3000"
route = (
    "\t# Dex, the identity provider behind /mcp. Path preserved: dex derives its\n"
    "\t# endpoint paths from the issuer, which ends in /dex.\n"
    "\thandle /dex* {\n"
    "\t\treverse_proxy http://dex:5556\n"
    "\t}\n\n"
)
open(path, "w").write(text.replace(anchor, route + anchor, 1))
PYDEX
    grep -q "http://dex:5556" Caddyfile || fail "failed to add the /dex route to the Caddyfile"
    log "  Caddy will serve dex at ${idp_issuer}"

    dotenv_set OIDC_ISSUER "$idp_issuer"
    dotenv_set OIDC_CLIENT_ID "$idp_client_id"
    dotenv_set OIDC_CLIENT_SECRET "$idp_client_secret"
    dotenv_set OIDC_SCOPES "${OIDC_SCOPES:-openid profile email}"
    effective_issuer="$idp_issuer"
    log "  Built-in IdP at ${idp_issuer}, sign-in as ${SUPERADMIN_EMAIL}"
    mcp_configured=1
    mcp_builtin=1
else
    log "  MCP is disabled — the mcp container will not start."
    log "  This affects only http://${APP_HOST}/mcp; the UI, API and workflows"
    log "  are unaffected. Set enable_mcp = true for the built-in provider, or"
    log "  oidc_issuer/oidc_client_id/oidc_client_secret for your own."
    mcp_configured=0
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

# ── Confirm the discovery document is reachable the way the mcp container ──
# ── will reach it ──────────────────────────────────────────────────────────
# fastmcp fetches this at startup and refuses to serve if the issuer does not
# match, so a wrong answer here is the difference between /mcp working and
# another empty 502. Run from a container with the same /etc/hosts override the
# mcp service gets, so this is the exact path that matters. Retried, because
# Caddy may still be completing the ACME handshake.
if (( mcp_builtin == 1 )); then
    log "Checking the discovery document is reachable at ${idp_issuer}"
    discovery_ok=0
    for i in $(seq 1 18); do
        if docker run --rm --add-host "${APP_HOST}:host-gateway" curlimages/curl:8.10.1 \
            -fsS --max-time 10 "${idp_issuer}/.well-known/openid-configuration" 2>/dev/null \
            | grep -q "\"issuer\"[[:space:]]*:[[:space:]]*\"${idp_issuer}\""; then
            discovery_ok=1
            log "  reachable, and the issuer matches after ~$((i * 10))s"
            break
        fi
        sleep 10
    done
    if (( discovery_ok == 0 )); then
        log "  WARNING: could not fetch a matching discovery document from"
        log "  ${idp_issuer} within three minutes. The mcp container will fail"
        log "  the same way and /mcp will return 502. Check that Caddy actually"
        log "  obtained a certificate ('docker compose logs caddy'), that"
        log "  ${APP_HOST} resolves to this instance, and 'docker compose logs dex'."
        mcp_configured=0
        mcp_failure=idp_unreachable
    fi
fi

# ── Done ───────────────────────────────────────────────────────────────────
cat > /etc/tracecat/READY <<EOF
tracecat_version=${TRACECAT_VERSION}
install_dir=${INSTALL_DIR}
app_url=http://${APP_HOST}
app_port=${app_port}
instance_public_ipv4=${observed_ip:-unknown}
superadmin_email=${SUPERADMIN_EMAIL}
mcp_configured=${mcp_configured}
mcp_builtin_idp=${mcp_builtin}
mcp_issuer=${effective_issuer}
completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

# This file now carries the generated MCP login, so it stops being world
# readable. Appended rather than written inline because a "0" for mcp_builtin is
# still a non-empty string, and ${var:+...} would happily expand on it.
chmod 0600 /etc/tracecat/READY
if (( mcp_builtin == 1 )); then
    cat >> /etc/tracecat/READY <<EOF
mcp_login_email=${SUPERADMIN_EMAIL}
mcp_login_password=${idp_password}
EOF
fi

log "=== Tracecat is up at http://${APP_HOST} ==="
log "First login: ${SUPERADMIN_EMAIL} (set a password via the sign-up form)"
if (( mcp_configured == 1 )); then
    log "MCP endpoint: http://${APP_HOST}/mcp (OIDC via ${effective_issuer})"
    if (( mcp_builtin == 1 )); then
        log "MCP sign-in: ${SUPERADMIN_EMAIL} / ${idp_password}"
        log "  Sign into the UI and create that account FIRST. MCP authorises against"
        log "  an existing Tracecat user, so /mcp returns 401 until it exists."
        log "  The password is in /etc/tracecat/READY and nowhere else."
    fi
elif [[ "$mcp_failure" == "idp_unreachable" ]]; then
    # Distinct from "no issuer configured": one is a choice, this is a fault, and
    # telling you to set an issuer you already have would send you the wrong way.
    log "MCP endpoint: BROKEN — an issuer is configured but the built-in provider at"
    log "  ${idp_issuer} is not reachable from a container, so"
    log "  the mcp container will fail the same way and /mcp will return 502."
    log "  Start with 'docker compose logs dex'; see docs/troubleshooting.md."
else
    log "MCP endpoint: not enabled — /mcp will return 502 until an OIDC issuer is set"
fi
log "Secrets live in ${INSTALL_DIR}/.env — back that file up before you lose the instance."
