# Architecture

What Terraform builds, what cloud-init does with it, and why the unattended install is
shaped the way it is.

---

## AWS resources

| Resource | Notes |
|---|---|
| `aws_instance` | Ubuntu 24.04 LTS (Canonical AMI, looked up by filter), encrypted gp3 root volume, IMDSv2 required |
| `aws_eip` + `aws_eip_association` | Allocated **before** the instance so the address can be written into `user_data` |
| `aws_security_group` | Ingress on 80 from `allowed_cidrs` only; 22 as well when `enable_ssh` |
| `aws_iam_role` + instance profile | `AmazonSSMManagedInstanceCore` only — shell access without SSH |
| `data.aws_vpc` / `data.aws_subnets` | Default VPC unless you supply `vpc_id` / `subnet_id` |

Security group rules use the modern `aws_vpc_security_group_ingress_rule` resources
rather than inline `ingress` blocks, so a rule change does not churn the whole group.

## The Elastic IP ordering problem

Tracecat bakes its public URL into `.env` at first boot and validates browser origins
against it. That means the address has to be known *before* cloud-init runs.

The obvious approach — let the instance take an ephemeral public IP, then associate an
EIP — races: cloud-init may read the ephemeral address from instance metadata a moment
before the association lands, and Tracecat is then configured for an address that no
longer routes to it.

So the EIP is allocated first, with no instance attached, and its address is interpolated
into `user_data`:

```hcl
app_host = (
  var.app_hostname != null ? var.app_hostname :
  var.allocate_eip ? aws_eip.this[0].public_ip :
  ""
)
```

That reference creates the dependency `aws_eip → aws_instance`, and the association
happens afterwards. When `allocate_eip` is false, `app_host` is empty and the bootstrap
falls back to asking instance metadata — correct, just not stable across a stop/start.

### What the bootstrap does with instance metadata

The IMDSv2 query runs on **every** path, not only the fallback, because it is the one
source of truth for the address this instance actually answers on:

| `APP_HOST` from Terraform | What happens |
|---|---|
| empty (no EIP, no hostname) | Metadata supplies the address. Fatal if metadata returns nothing — the instance has no public address to serve on. |
| an IPv4 (the Elastic IP) | Metadata **confirms** it. A mismatch is expected for a few seconds while the association lands, so it polls for up to 60s, then logs a prominent `WARNING` if they still disagree. |
| a hostname | Logs the instance's public IP alongside it, so you can check the DNS record resolves to the right box. |

The mismatch case warns rather than fails on purpose: the address could legitimately be
fronted by something else, and failing the whole install on a heuristic would be worse
than a loud log line. The observed address is also written to `/etc/tracecat/READY` as
`instance_public_ipv4`, so the two values are side by side after the fact.

This matters because the failure it catches is a nasty one — Tracecat writes the address
into `.env`, the UI loads fine, and then every API call fails CORS. That looks like a
Tracecat problem and is actually a networking one.

## Getting the script onto the box

`user_data` is rendered from `cloud-init.yaml.tftpl`, which writes two files:

- `/etc/tracecat/deploy.env` — the handful of values Terraform knows
  (`TRACECAT_VERSION`, `SUPERADMIN_EMAIL`, `APP_HOST`, …)
- `/usr/local/sbin/tracecat-bootstrap.sh` — the installer, **base64-encoded**

The base64 encoding is not decoration. Terraform's template engine and bash share the
`${VAR}` syntax, so templating a shell script directly means escaping every bash variable
as `$${VAR}` and getting it wrong exactly once. Passing the script through
`base64encode(file(...))` means Terraform never parses its contents at all, and the
script stays a plain file you can lint and run locally.

The script reads its configuration by sourcing `deploy.env`. Terraform interpolates only
that small, flat file.

### The 16 KB budget

EC2 caps `user_data` at **16 KB**. The rendered cloud-init is about 19 KB — the
base64-encoded script costs a further 33% on top of the script itself — so it does not
fit as plain text.

Terraform therefore submits it compressed:

```hcl
user_data_base64 = base64gzip(templatefile(...))
```

cloud-init detects gzipped user-data and decompresses it without any extra
configuration. That brings the payload to roughly 8 KB, leaving about half the budget
spare. **If you grow `scripts/bootstrap.sh` substantially, check the compressed size
still fits** — the failure mode is an `apply` rejected by the EC2 API, which is at least
loud.

## The unattended install

Tracecat's documented install runs `env.sh`, which is **interactive**. On a host with no
existing `.env` it asks exactly four questions, in order:

1. Use production mode? *(y/n, default y)*
2. Set `PUBLIC_APP_URL` to *(default localhost)*
3. Require PostgreSQL SSL mode? *(y/n, default n)*
4. Email address for the first user (superadmin)

The bootstrap answers them on stdin:

```bash
printf '%s\n%s\n%s\n%s\n' \
    "$PRODUCTION_MODE" "$APP_HOST" "$POSTGRES_SSL" "$SUPERADMIN_EMAIL" \
    | bash ./env.sh
```

**Why pipe into their script instead of writing `.env` directly?** `env.sh` generates the
four cryptographic secrets with `openssl` and knows the current shape of `.env.example`.
Hand-rolling the file would mean reimplementing that and silently drifting from upstream
at every release.

**Why that is risky, and what is done about it.** Piping answers into an interactive
script breaks silently if upstream adds or reorders a prompt — the values shift by one and
you find out later through a confusing CORS error. So the script asserts the result
before continuing: all four secrets present and non-empty, the superadmin email exactly
what was passed, and `PUBLIC_APP_URL` containing the expected host. A mismatch fails the
install loudly, with a message naming the likely cause.

## Version pinning

The bootstrap fetches `env.sh`, `.env.example`, `Caddyfile` and `docker-compose.yml` from
`https://raw.githubusercontent.com/TracecatHQ/tracecat/${TRACECAT_VERSION}/`.

They are fetched rather than vendored, so this repository does not ship a stale copy of
someone else's compose file. They are pinned to a tag rather than tracking `main`, so a
deployment is reproducible and an upstream change cannot alter an install you did last
week. Change `tracecat_version` to move.

## Boot sequence

```
cloud-init
  └─ write /etc/tracecat/deploy.env
  └─ write /usr/local/sbin/tracecat-bootstrap.sh   (base64-decoded)
  └─ runcmd: tracecat-bootstrap.sh
        1. resolve APP_HOST (from deploy.env, else IMDSv2 public-ipv4)
        2. wait for apt/dpkg locks — unattended-upgrades runs at boot
        3. install docker-ce + compose plugin from Docker's apt repo
              (Tracecat needs Docker 26+/Compose 2.29+; Ubuntu's docker.io is older)
        4. curl the four Tracecat files at the pinned tag
        5. run env.sh with answers piped in
        6. VALIDATE the resulting .env, and repair TRACECAT__ALLOW_ORIGINS
        7. docker compose up -d
        8. poll http://localhost:80 for up to ~15 minutes
        9. write /etc/tracecat/READY
```

Everything is logged to `/var/log/tracecat-bootstrap.log`. `/etc/tracecat/READY` exists
only on success, which gives you a single file to check.

## What is deliberately not here

- **TLS.** The stack serves HTTP on port 80. Terminating TLS properly means a domain, a
  certificate and a Caddy config change — see [operations.md](operations.md#going-to-production).
- **RDS, or any managed data store.** Tracecat's compose stack runs its own PostgreSQL.
  Moving to RDS is a real production step and a different project.
- **Backups.** Nothing is backed up. The instance is cattle; its database is not.
- **Autoscaling or high availability.** One instance, by design.
