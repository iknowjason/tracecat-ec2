# Tracecat-ec2

Unattended, single-command deployment of the [Tracecat](https://tracecat.com) open
source security automation platform onto an EC2 instance in **your own AWS account**.

Terraform builds the instance and its network; cloud-init installs Docker, fetches
Tracecat's own deployment files at a pinned version, generates the environment
non-interactively, and brings the stack up. You run `terraform apply`, wait, and open a
URL.

```
terraform apply
      │
      ├── EC2 (Ubuntu 24.04) + Elastic IP + security group locked to your CIDR
      ├── IAM role for SSM Session Manager (shell access with no open SSH port)
      └── cloud-init user_data
              │
              └── scripts/bootstrap.sh
                     ├── Docker CE + Compose plugin (from Docker's own repo)
                     ├── curl env.sh / .env.example / Caddyfile / docker-compose.yml
                     │      at the pinned Tracecat tag
                     ├── run env.sh with answers piped in  → .env with generated secrets
                     ├── verify the .env actually came out right
                     └── docker compose up -d  → poll until the UI answers
```

The result is the stack Tracecat documents at
[docs.tracecat.com/self-hosting/docker-compose](https://docs.tracecat.com/self-hosting/docker-compose) —
roughly 15 containers: API, worker, executor, agent worker, agent executor, MCP server,
UI, Caddy, two PostgreSQL instances, Temporal, MinIO and Redis.

The MCP server is an OIDC proxy and will not start without an identity provider, so this
module deploys one: a Dex container with a generated secret and a single seeded login.
It also **requires TLS** — the MCP server rejects its own issuer URL unless it is https,
whatever the provider — so `/mcp` needs `app_hostname` and `hosted_zone_id`, and Caddy
takes a Let's Encrypt certificate on first boot. Read the credentials with
`sudo grep ^mcp_ /etc/tracecat/READY`, and sign up in the UI first, since MCP authorises
against an existing Tracecat user. Deploy without any of it using `enable_mcp = false`;
see [docs/deploy.md](docs/deploy.md#5a-the-mcp-endpoint).

---

## Quickstart

```bash
git clone https://github.com/iknowjason/tracecat-ec2.git
cd tracecat-ec2/terraform

terraform init
terraform apply
```

**Nothing is required.** Every variable has a default, so that is the whole thing — no
`terraform.tfvars` needed and no prompts. Two defaults are worth knowing:

| | Default | Change it if |
|---|---|---|
| `superadmin_email` | `admin@example.com` | you would rather log in as yourself. Nothing is emailed — the stack has no SMTP — so this is an identity, not a mailbox |
| `allowed_cidrs` | your detected public IP, as a `/32` | Terraform runs somewhere your browser does not (CI, a bastion, a different VPN) |

```bash
cp terraform.tfvars.example terraform.tfvars   # optional — to override either
```

Then:

```bash
terraform output app_url                   # http://<elastic-ip>
terraform output watch_bootstrap_command   # follow the install live
```

The install takes **5–15 minutes** after `apply` returns — Terraform finishes when the
instance is running, not when Tracecat is ready. Watch the log, or just wait and reload.

Full walkthrough: [docs/deploy.md](docs/deploy.md).

---

## What you need

| | Why |
|---|---|
| An AWS account and credentials | `aws sts get-caller-identity` should work |
| Terraform 1.6+ | |
| Permission to create EC2, VPC security groups, IAM roles and EIPs | The IAM role is only for SSM Session Manager |
| A default VPC, **or** an existing VPC and public subnet | Pass `vpc_id` / `subnet_id` if you have no default VPC |
| An email address | Becomes the Tracecat superadmin — the only required variable |

---

## Security posture

This deployment serves **plain HTTP**. Tracecat's own documentation is explicit that an
HTTP-only deployment should not be exposed to a public domain. The design follows from
that:

- **Ingress is restricted to your own address by default.** Leave `allowed_cidrs` unset
  and Terraform looks up the public IP it is calling from and allows that `/32` only.
  `0.0.0.0/0` is rejected by a variable validation, so opening it to the world takes a
  deliberate edit rather than an oversight.
- **SSH is off by default.** The instance gets an IAM role for **SSM Session Manager**,
  so you can get a shell with no inbound port open and no key pair to manage. Set
  `enable_ssh = true` if you want port 22 anyway.
- **IMDSv2 is required** (`http_tokens = "required"`). The bootstrap uses the token flow.
- **The root volume is encrypted.**
- **Secrets are generated on the instance**, by Tracecat's own `env.sh`, and never pass
  through Terraform state.

**Before this handles anything real:** put TLS in front of it and switch to SSO. See
[Tracecat's TLS docs](https://docs.tracecat.com/self-hosting/deployment-options/docker-compose)
and [docs/operations.md](docs/operations.md#going-to-production).

---

## Cost

Rough `us-east-1` on-demand pricing, running continuously:

| | |
|---|---|
| `t3.xlarge` (4 vCPU / 16 GB, default) | ~$0.166/hr — about **$120/month** |
| `t3.large` (2 vCPU / 8 GB, budget) | ~$0.083/hr — about **$60/month** |
| 60 GB gp3 root volume | ~$4.80/month |
| Elastic IP | free while attached to a running instance |

The default is `t3.xlarge` because the stack runs ~15 containers including two databases
and Temporal. `t3.large` works but leaves little headroom. **Stop the instance when you
are not using it** — with the Elastic IP the address survives, though a stopped instance
with an attached EIP does incur a small hourly charge.

`terraform destroy` removes everything.

---

## Documentation

| | |
|---|---|
| [docs/deploy.md](docs/deploy.md) | Full deployment walkthrough and first login |
| [docs/architecture.md](docs/architecture.md) | What gets built and why, including the unattended-install design |
| [docs/operations.md](docs/operations.md) | Logs, backups, upgrades, going to production, teardown |
| [docs/troubleshooting.md](docs/troubleshooting.md) | When the URL does not answer |

---

## Project status

**Verified:** the bootstrap script passes `bash -n` and `shellcheck`; the cloud-init
template renders to valid YAML with the embedded script round-tripping byte-identical;
Terraform files are `terraform fmt` clean; and the non-interactive `env.sh` flow was
executed locally against Tracecat's real `env.sh` and `.env.example` at tag `1.0.0`,
producing a correct `.env` with all four secrets generated.

**Not verified:** `terraform init/validate/plan/apply` has not been run, and no instance
has been launched. Treat your first `apply` as the verification pass.

**One upstream bug is worked around.** In Tracecat's `env.sh` at tag `1.0.0`, the
variable `new_origins` is used but never assigned, so `TRACECAT__ALLOW_ORIGINS` is
overwritten with an empty string — leaving the API with an empty CORS allowlist. This
affects the documented interactive install too. `scripts/bootstrap.sh` detects and
repairs it, and says so in the log. See
[docs/troubleshooting.md](docs/troubleshooting.md#cors-errors-in-the-browser-console).

## License

[Apache License 2.0](LICENSE). Tracecat itself is separately licensed — see
[TracecatHQ/tracecat](https://github.com/TracecatHQ/tracecat).
