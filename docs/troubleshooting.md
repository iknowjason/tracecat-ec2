# Troubleshooting

Start here:

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo cat /etc/tracecat/READY          # exists only if the install succeeded
sudo tail -50 /var/log/tracecat-bootstrap.log
```

The bootstrap logs every step and fails loudly with a `FATAL:` line naming the cause. If
`READY` is missing, the log says why.

---

## The URL does not answer

**First: has the install finished?** `terraform apply` returns when the instance is
running, not when Tracecat is ready. Budget 5–15 minutes for Docker to install and ~15
images to pull.

```bash
sudo tail -f /var/log/tracecat-bootstrap.log
```

**Then check, in this order:**

```bash
# Is the stack up?
cd /opt/tracecat && sudo docker compose ps

# Does it answer locally? If yes, the problem is the network, not Tracecat.
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/
```

If `localhost` answers but your browser does not, it is the security group. Compare what
was allowed against where you actually are:

```bash
terraform output allowed_cidrs_effective    # what the rule permits
curl -s https://checkip.amazonaws.com       # where you are now
```

Three common reasons they differ:

- **Your address changed.** Residential IPs move. Re-run `terraform apply`; with the
  automatic lookup, the plan will simply re-point the rule.
- **Terraform ran somewhere else.** The lookup returns the address *Terraform* called
  from. From CI, a bastion, or a different VPN, that is not your browser's address. Set
  `allowed_cidrs` explicitly.
- **You are behind a different egress than when you applied** — VPN on versus off is the
  usual culprit.

Either way, updating `allowed_cidrs` and re-applying changes only the security group
rules, not the instance.

Also confirm you are using **http://**, not https. There is no TLS here, and browsers
increasingly try to upgrade automatically.

## CORS errors in the browser console

Symptoms: the UI loads, then every request fails, with console errors about the origin
not being allowed.

**Known upstream bug.** In Tracecat's `env.sh` at tag `1.0.0`, line 185 reads:

```bash
new_origins=$(echo "$new_origins" | tr ',' '\n' | sort -u | ...)
dotenv_replace "TRACECAT__ALLOW_ORIGINS" "$new_origins" "$env_file"
```

`$new_origins` is never assigned anywhere in the script. It expands to an empty string and
overwrites the default that `.env.example` ships, leaving the API with an empty CORS
allowlist. This affects the documented interactive install too, not just this one.

`scripts/bootstrap.sh` detects and repairs it, and logs `TRACECAT__ALLOW_ORIGINS was
blanked by env.sh`. If you hit CORS errors anyway, check the value directly:

```bash
grep -E '^(PUBLIC_APP_URL|TRACECAT__ALLOW_ORIGINS)=' /opt/tracecat/.env
```

Both must contain the exact origin your browser is using — same scheme, same host, same
port. Fix and restart:

```bash
cd /opt/tracecat
sudo sed -i 's|^TRACECAT__ALLOW_ORIGINS=.*|TRACECAT__ALLOW_ORIGINS=http://YOUR-ADDRESS|' .env
sudo docker compose up -d
```

## The address changed after a stop/start

Tracecat bakes its public URL into `.env` at first boot. If the instance came up with a
different address, the UI breaks.

This is what `allocate_eip = true` prevents. If you set it to false, either turn it back
on and re-apply, or fix the file by hand:

```bash
cd /opt/tracecat
NEW=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 \
  -H "X-aws-ec2-metadata-token: $(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')")
sudo sed -i "s|^PUBLIC_APP_URL=.*|PUBLIC_APP_URL=http://$NEW|;\
s|^PUBLIC_API_URL=.*|PUBLIC_API_URL=http://$NEW/api|;\
s|^TRACECAT__ALLOW_ORIGINS=.*|TRACECAT__ALLOW_ORIGINS=http://$NEW|" .env
sudo docker compose up -d
```

## `FATAL: ... env.sh prompts may have changed upstream`

The bootstrap pipes four answers into Tracecat's interactive `env.sh`. If upstream adds,
removes or reorders a prompt, the answers shift by one and land in the wrong variables.

Rather than let that produce a mysterious failure later, the script validates the
generated `.env` and stops with this message. To fix:

1. Read the current script: `curl -s https://raw.githubusercontent.com/TracecatHQ/tracecat/<version>/env.sh | grep -n 'read -p'`
2. Update the `printf` in `scripts/bootstrap.sh` to match the new prompt order.
3. Or pin `tracecat_version` back to a tag that works.

You can also finish the install by hand — `cd /opt/tracecat && ./env.sh` interactively,
then `docker compose up -d`.

## `/mcp` returns 502 but everything else works

The giveaway is that `https://<host>/` answers 200 while `POST /mcp` returns a 502 with
an empty body: Caddy is routing correctly and reporting that it cannot reach what it
proxies to — the `mcp` container is not listening.

```bash
docker compose logs mcp
```

**By far the most likely cause is the version.** If you see

```
ERROR __main__:main:48 - MCP server failed to start after maximum startup attempts
  {'attempts': 3, 'error': 'OIDC_ISSUER must be configured for the MCP server.'}
```

you are running a Tracecat older than `1.0.0-beta.51`, where the MCP server was an OIDC
*proxy* that refused to start without an external identity provider. This module no
longer deploys one, because from beta.51 Tracecat issues its own tokens.

Upstream's tags do not sort by date. Check what you actually deployed:

```bash
sudo grep -E '^tracecat_(version|image_tag)' /etc/tracecat/READY
grep -E '^TRACECAT__IMAGE_TAG=' /opt/tracecat/.env
```

`1.0.0` was cut 2026-04-03, four months *before* `1.0.0-beta.51`, and its own compose file
defaults the images to `1.0.0-beta.37`. Set `tracecat_version = "1.0.0-beta.51"` and
re-apply — which replaces the instance, so take a database backup first.

## `mcp` logs "Issuer URL must be HTTPS"

```
MCP server failed to start ... {'error': 'Issuer URL must be HTTPS'}
```

The MCP server validates its own issuer URL and refuses anything that is not https. That
check is in the MCP SDK (`mcp/server/auth/routes.py::validate_issuer_url`), is hard-coded
per RFC 8414, and exempts only `localhost` — so it applies to Tracecat's own issuer too.
There is no flag and no escape hatch.

`enable_mcp` requires `app_hostname` for exactly this reason, and Terraform says so at
plan time. If you reach this error you have edited `.env` by hand, or `PUBLIC_API_URL` is
http:// when it should be https://:

```bash
grep -E '^(PUBLIC_APP_URL|PUBLIC_API_URL)=' /opt/tracecat/.env
```

Both must be `https://<app_hostname>...`. The bootstrap rewrites them, because `env.sh`
can only emit `http://`.

## The UI loads but every action fails with "NetworkError"

The page renders, `curl` against the API returns 200 from the command line, and the
browser still cannot fetch anything. The giveaway is in the response headers:

```
alt-svc: h3=":443"; ma=2592000
```

Caddy advertises HTTP/3, so the browser moves to QUIC on **UDP** 443 after the first
request. If only TCP 443 is open, those packets are dropped with no response — a bare
"NetworkError when attempting to fetch resource", with nothing in any server log,
while curl keeps working because it does not negotiate h3.

The module opens UDP 443 to the same CIDRs as TCP. If you are running an older deploy,
or your own network blocks outbound UDP, either add the rule:

```bash
aws ec2 authorize-security-group-ingress --group-id <sg-id> \
  --ip-permissions 'IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=<your-ip>/32}]'
```

or turn HTTP/3 off in Caddy, which costs nothing and removes the dependency entirely —
add to the global options block at the top of `/opt/tracecat/Caddyfile`:

```
	servers {
		protocols h1 h2
	}
```

then `docker compose restart caddy`.

## `/mcp` authenticates and then returns 401

Sign-in succeeded but Tracecat does not know you. MCP authorises against an existing
Tracecat user, matched on the email claim, and the account is only created when someone
completes the sign-up form in the UI. Sign in at `https://<app_hostname>/` as
`superadmin_email` once, then retry.

```bash
sudo grep ^superadmin_email /etc/tracecat/READY
```

A rebuild empties Postgres, so this comes back every time you replace the instance.

## The OAuth flow ends on a `localhost` page

That is the flow working. Loopback redirection is how native applications receive an
authorization code (RFC 8252): Tracecat redirects to the client's own short-lived local
listener. Nothing to reconfigure.

If the page reports **connection refused**, the listener had already closed before the
browser got there. Common causes: a long pause at the sign-in form, opening the link in a
browser on a different machine than the client, or restarting the client mid-flow. Start
over and finish promptly:

```bash
claude mcp logout tracecat
claude mcp login tracecat
```

For a headless client, skip the browser entirely and mint a personal access token at
`https://<app_hostname>/workspaces/<workspace-id>/mcp`. See
[mcp-clients.md](mcp-clients.md).

## MCP clients fail after a rebuild

The endpoint URL is unchanged, so the client's server definition is still correct — but
the internal OIDC client secret is re-derived from a freshly generated `USER_AUTH_SECRET`,
and the client registrations the server held are gone with the old database. Clear the
stored credentials rather than removing and re-adding the server:

```bash
claude mcp logout tracecat
claude mcp login tracecat
```

A rebuild also empties Postgres, so sign up in the UI as `superadmin_email` again first
or you will hit the 401 above. Personal access tokens live in that database too, so any
you had minted are gone.

## MCP clients are signed out after a reboot

Expected. Access tokens are short-lived and client registrations do not survive a
replacement of the instance. Run the client's OAuth flow again:

```bash
claude mcp logout tracecat
claude mcp login tracecat
```

- **The MCP server advertises `localhost`.** `TRACECAT__PUBLIC_API_URL` is derived from
  `PUBLIC_APP_URL`, and the internal OIDC issuer is built from it. If you regenerate
  `.env` by hand, set both.
- **A secret containing `$` is silently truncated.** Docker Compose interpolates `.env`,
  so values must be single-quoted. The bootstrap always quotes; hand-edits often do not.

## Containers being OOM-killed

```bash
free -h
docker stats --no-stream
dmesg | grep -i "killed process"
```

The stack runs ~15 containers including two PostgreSQL instances, Temporal, MinIO and
Redis. `t3.large` (8 GB) is the practical floor and `t3.xlarge` (16 GB) is the default for
this reason. Raise `instance_type` and re-apply.

Changing only `instance_type` does **not** replace the instance, so the database survives.

## SSM Session Manager will not connect

- Give it a minute after boot; the agent registers shortly after start.
- The instance needs outbound internet to reach the SSM endpoints. If your subnet has no
  route to an internet gateway, SSM never comes up — and neither does the Docker install,
  so the bootstrap will have failed too.
- Your own credentials need `ssm:StartSession`.
- As a fallback, set `enable_ssh = true` with a `key_name` and re-apply.

## Docker install failed

Look for `apt-get` errors in the log. The usual cause is a lock held by Ubuntu's
`unattended-upgrades` at boot; the script waits up to five minutes and retries `apt-get`
five times, but a slow mirror can outlast that. Re-running is safe:

```bash
sudo /usr/local/sbin/tracecat-bootstrap.sh
```

Re-running is safe. If a `.env` already exists from a partial run, the script moves it
aside to `.env.bak.<timestamp>` first. `env.sh` asks an extra "overwrite?" question when
one is present; that does not currently misalign the piped answers, but only because the
prompt reads a single character and the following prompt's default absorbs the leftover
newline. Moving the file aside makes the sequence deterministic instead of coincidental.

## Terraform cannot find AWS credentials under `sops exec-env`

```bash
sops exec-env secrets.enc.env 'aws sts get-caller-identity'
```

Run that first — it isolates the credential problem from Terraform. Three things account
for most failures:

- **The age key is not where sops looks.** On macOS that is
  `~/Library/Application Support/sops/age/keys.txt`, not `~/.config/sops/age/keys.txt`.
  Most tutorials print the Linux path and sops fails against it without saying so.
- **The file does not end in `.env`.** `sops exec-env` has no `--input-type` flag and
  infers the format from the extension, so `secrets.enc` cannot work — `secrets.enc.env`
  can.
- **`AWS_REGION` in the encrypted file is ignored.** The provider is pinned to
  `var.aws_region`; set the region in `terraform.tfvars`.

Full walkthrough: [secrets-sops.md](secrets-sops.md).

## Starting over completely

```bash
terraform destroy && terraform apply
```

Nothing is preserved. That is the fastest path when the instance is in an unclear state.

## The apply fails on user_data size

EC2 caps `user_data` at 16,384 bytes and the bootstrap script travels inside it,
gzipped and base64-encoded. The failure lands on `aws_instance` creation — after the
EIP and the DNS record already exist — so you are left cleaning up a partial stack.

Check before you apply:

```bash
./scripts/preflight.sh
```

It reports the rendered size against the cap, and warns past 90%.

Terraform drops every line of `bootstrap.sh` that starts with `#` in the **first
column** (the shebang excepted) on the way in — see `locals.bootstrap_script` in
`main.tf`. That is worth about 4.5 KB. The script on disk keeps its comments; only
the copy inside `user_data` loses them.

**Consequence to remember when editing the bootstrap:** anything a heredoc writes
out must not start a line with `#` at column zero, or that line disappears from the
generated file with no warning. Indent it — YAML, Caddyfile and shell all accept an
indented comment. `preflight.sh` fails if you forget.

If trimming is not enough, the script has outgrown `user_data`: fetch it from S3 at
boot, or bake it into an AMI.
