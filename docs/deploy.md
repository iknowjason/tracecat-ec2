# Deploying

From an empty directory to a working Tracecat login screen.

---

## 1. Check your prerequisites

```bash
aws sts get-caller-identity     # credentials work, and you know which account
terraform version               # 1.6 or newer
curl -s https://checkip.amazonaws.com   # your public address, for allowed_cidrs
```

If those credentials are real rather than a throwaway sandbox, encrypt them instead of
exporting them and run every command below as
`sops exec-env secrets.enc.env 'terraform ...'` — see
[secrets-sops.md](secrets-sops.md).

If your account has no default VPC, have a `vpc_id` and a **public** `subnet_id` ready —
the subnet must route to an internet gateway, since the instance pulls container images
on first boot.

### A Route 53 hosted zone, if you want `/mcp`

The MCP server refuses an issuer URL that is not https, so it needs a real DNS name and a
certificate. That means a **domain you control, hosted in Route 53 in this account**. You
do not need a whole domain to yourself — a subdomain of one you already have is the
normal case, and this module writes a single A record into an existing zone.

Everything except `/mcp` works fine on the raw IP with no domain at all. If you are only
evaluating the UI and workflows, skip this and leave `app_hostname` unset.

Find the zone ID for the domain you intend to use:

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[].{name:Name,id:Id,private:Config.PrivateZone}" --output table
```

The `Id` comes back as `/hostedzone/Z1234567890ABC`; **`hosted_zone_id` wants only the
`Z...` part.** The zone must be **public** (`private: False`) — Let's Encrypt has to
resolve the name from the internet.

### IAM permissions

The credentials Terraform runs as need EC2, VPC security group, IAM role and instance
profile, Elastic IP, and — for the DNS record — Route 53 permissions. The IAM role this
module *creates* for the instance is separate and grants only
`AmazonSSMManagedInstanceCore`, which is what makes shell access work without SSH.

**Quick path**, appropriate for a lab account you own:

| Managed policy | For |
|---|---|
| `AmazonEC2FullAccess` | Instance, security group, Elastic IP, AMI lookup |
| `IAMFullAccess` | The instance role and instance profile |
| `AmazonRoute53FullAccess` | The A record — only if you set `hosted_zone_id` |
| `AmazonSSMFullAccess` | Not used by Terraform; needed by *you* for the shell and Run Command outputs |

**Least privilege.** The actions this module actually calls, if you would rather scope it
down. Route 53 is the part people miss, so it is called out first:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53Record",
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone",
        "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/Z1234567890ABC",
        "arn:aws:route53:::change/*"
      ]
    },
    {
      "Sid": "Route53Lookup",
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones"],
      "Resource": "*"
    },
    {
      "Sid": "Compute",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:ModifyInstanceAttribute",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "InstanceRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:TagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": "*"
    }
  ]
}
```

> **This list is derived from the resources the module declares, not from an apply run
> under exactly this policy.** EC2 and IAM in particular fail with unhelpful messages when
> one action is missing. If a `plan` or `apply` dies on `UnauthorizedOperation` or
> `AccessDenied`, the error names the action — add it. Replace `Z1234567890ABC` with your
> own zone.

Route 53 is a **global** service: those permissions are not region-scoped, and the
`hostedzone/` ARN has no account or region segment.

## 2. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

**Nothing is required.** Every variable has a working default, so `terraform apply` runs
without prompting and without a `terraform.tfvars` at all — you get Tracecat on the raw
IP, over plain HTTP, reachable only from your own address.

For a deployment that also serves `/mcp`, `terraform.tfvars` ends up looking like this.
Each line is explained below:

```hcl
# terraform/terraform.tfvars

superadmin_email = "you@example.com"          # the first Tracecat user

app_hostname     = "tracecat.example.com"     # the subdomain to serve on
hosted_zone_id   = "Z1234567890ABC"           # the Route 53 zone that owns example.com
acme_email       = "you@example.com"          # optional; defaults to superadmin_email

aws_region       = "us-east-1"
```

### Setting the superadmin email

`superadmin_email` is the first Tracecat user — the account with full privileges. You
claim it by signing up with that **exact** address on first visit and choosing a
password.

It defaults to `admin@example.com`, which works: the compose stack has no SMTP service,
so nothing is ever mailed to it and the address is an identity rather than a mailbox that
must receive. Sign in with `admin@example.com` and a password you choose and you are the
superadmin.

To log in as yourself instead, set it in `terraform.tfvars`:

```hcl
superadmin_email = "you@example.com"
```

Or pass it on the command line for a one-off:

```bash
terraform apply -var 'superadmin_email=you@example.com'
```

Check what will be used before you apply, and confirm it afterwards:

```bash
terraform output superadmin_email
```

> **Decide before the first apply.** The address is written into `/opt/tracecat/.env` when
> the instance boots, and cloud-init only runs once. Changing the variable afterwards
> forces Terraform to replace the instance, taking the database with it. To change it on a
> running instance, edit `TRACECAT__AUTH_SUPERADMIN_EMAIL` in `/opt/tracecat/.env` and run
> `docker compose up -d` — see [operations.md](operations.md).

### The DNS name and the subdomain

Only needed if you want `/mcp`. Skip it and Tracecat serves on the instance's public IP
over plain HTTP.

Two variables, and they are a pair — set one without the other and you get a name that
does not resolve, or a zone with nothing written into it:

| Variable | What it is | Example |
|---|---|---|
| `app_hostname` | The **fully qualified** name to serve on, no scheme, no port, no trailing dot | `tracecat.example.com` |
| `hosted_zone_id` | The Route 53 zone that owns the parent domain, `Z...` only | `Z1234567890ABC` |

**Pick the subdomain first, then find the zone that owns it.** The hostname is the
subdomain; the zone is the domain above it. For `tracecat.example.com` you want the zone
for `example.com` — not a zone for `tracecat.example.com`, unless you have genuinely
delegated one.

```bash
# The zone that owns the parent domain. Note the trailing dot in Name.
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='example.com.'].{name:Name,id:Id,private:Config.PrivateZone}" \
  --output table
```

Then in `terraform.tfvars`:

```hcl
app_hostname   = "tracecat.example.com"
hosted_zone_id = "Z1234567890ABC"      # NOT "/hostedzone/Z1234567890ABC"
```

Terraform writes the A record — TTL 60, pointing at the Elastic IP — in the **same apply**
that creates the instance, so it exists before Caddy's first ACME attempt a few minutes
later. Nothing to do by hand.

Three ways this goes wrong:

- **The `/hostedzone/` prefix.** `list-hosted-zones` returns `Id` as
  `/hostedzone/Z1234567890ABC`. Strip it; `hosted_zone_id` wants the bare `Z...`.
- **A private zone.** Let's Encrypt resolves the name from the public internet. A private
  zone gets you a record nobody outside the VPC can see and an ACME failure that looks
  like a Caddy problem.
- **The domain is registered elsewhere and its nameservers still point there.** Having a
  zone in Route 53 is not the same as the internet using it. Check:
  ```bash
  dig +short NS example.com
  aws route53 get-hosted-zone --id Z1234567890ABC --query 'DelegationSet.NameServers'
  ```
  Those two lists must match.

Leaving `hosted_zone_id` null with `app_hostname` set is legitimate — it means *"I will
create the record myself"* — but the record has to exist and resolve **before** you apply,
because the bootstrap does not wait for DNS.

`acme_email` is the Let's Encrypt account contact and defaults to `superadmin_email`.
Expiry notices go there.

### Who may reach the UI

This is worked out for you. Leave `allowed_cidrs` unset and Terraform
asks `checkip.amazonaws.com` for the public IP of the machine running it, then allows
exactly that address as a `/32`. The plan shows you what it found, and so does an output:

```bash
terraform output allowed_cidrs_effective
```

Set it explicitly when the automatic answer is wrong:

```hcl
allowed_cidrs = ["203.0.113.42/32", "198.51.100.0/24"]
```

> **The lookup returns the address *Terraform* is calling from**, which is not always the
> one your browser uses. Running Terraform from CI, a bastion, or through a different VPN
> than your browser will allow the wrong address — you will get a working instance you
> cannot reach. Set `allowed_cidrs` explicitly in those cases, or
> `auto_detect_my_ip = false` to turn the lookup off entirely.
>
> Two other things to know. A residential IP that changes will show up as a diff on the
> next `plan` — that is the lookup working, and applying it just re-points the rule. And
> if you are on an IPv6-only network the lookup fails with a clear error, because the
> `/32` assumption is IPv4.

`allowed_cidrs` rejects `0.0.0.0/0` through a variable validation. That is deliberate.
Without `app_hostname` the deployment serves unencrypted HTTP, and Tracecat's
documentation warns against exposing an HTTP-only instance publicly. Even with TLS on,
this is a single instance with no WAF and no rate limiting in front of it, so the rule
stays: opening it to the world takes a knowing edit rather than an oversight.

The one exception is automatic and narrow — with TLS on, port 80 opens to `0.0.0.0/0` for
the ACME HTTP-01 challenge. Port 443 stays restricted to `allowed_cidrs`.

Worth knowing about the rest:

| Variable | Default | Notes |
|---|---|---|
| `instance_type` | `t3.xlarge` | `t3.large` works but is tight for ~15 containers |
| `root_volume_size` | `60` | Minimum 40; the images alone are several GB |
| `allocate_eip` | `true` | Keep it — see below |
| `enable_ssh` | `false` | SSM Session Manager already gives you a shell |
| `tracecat_version` | `1.0.0` | The git tag the bootstrap fetches from |
| `app_hostname` | `null` | Set only once DNS already points at the instance |

**Why the Elastic IP matters.** Tracecat writes its public URL into `.env` at first boot
and validates browser origins against it. Without a stable address, stopping and starting
the instance changes the IP and breaks the UI until you regenerate that file. Terraform
allocates the EIP *before* the instance so the address can be baked into the boot
configuration, rather than racing the association.

## 3. Apply

```bash
terraform init
terraform plan       # read it — the security group rules and IAM role are the parts to check
terraform apply
```

`apply` returns when the **instance** is running. Tracecat is not ready yet.

## 4. Watch the install

The bootstrap takes **5–15 minutes**: installing Docker, pulling ~15 images, running
database migrations, and waiting for the UI to answer.

```bash
terraform output watch_bootstrap_command
```

Run what it prints, or open a shell and tail the log directly:

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo tail -f /var/log/tracecat-bootstrap.log
```

You are looking for this, at the end:

```
[2026-08-21T22:41:07Z] === Tracecat is up at http://203.0.113.42 ===
```

The script also writes `/etc/tracecat/READY` on success. If that file does not exist, the
install did not finish — the log will say why, and
[troubleshooting.md](troubleshooting.md) covers the likely causes.

> **If SSM will not connect**, give it a minute — the agent registers shortly after boot.
> It also needs the instance to reach the SSM endpoints, which it does through the
> internet gateway. If your subnet has no route out, SSM will never come up and neither
> will the Docker install.

## 5. First login

```bash
terraform output app_url
```

Open it. You get Tracecat's sign-in page.

**There is no default password.** The address you set as `superadmin_email` is registered
as the first user, and you claim the account by signing up with that exact address and
choosing a password. Sign in with anything else and you get an ordinary unprivileged
account.

Also available:

- `/api/docs` — the API reference
- `/mcp` — the MCP endpoint, working out of the box **when `app_hostname` is set**, since
  it requires TLS. See below for the sign-in credentials, and
  [mcp-clients.md](mcp-clients.md) for connecting a client.

Both are on whatever `terraform output app_url` prints — `https://<app_hostname>` with
TLS on, `http://<ip>` without.

## 5a. The MCP endpoint

**It needs no identity provider.** From Tracecat `1.0.0-beta.51` the MCP server
authenticates against an OIDC issuer Tracecat runs itself, on the API server at
`/api/oauth/mcp`, with a client secret derived from `USER_AUTH_SECRET` — which `env.sh`
has already generated by the time the stack comes up. Nothing to register, nothing to
configure, no extra container.

### Signing in

Two ways, both handled by Tracecat:

- **Browser OAuth** — sign in with your ordinary Tracecat account, the same email and
  password you use for the UI.
- **Personal access token** — mint a workspace-scoped token in the UI at
  `https://<app_hostname>/workspaces/<workspace-id>/mcp` and send it as a bearer token.
  No browser, no redirect; the right choice for headless clients and CI.

```bash
claude mcp add --transport http tracecat https://<app_hostname>/mcp
claude mcp login tracecat
```

**Create the Tracecat account first.** MCP authorises against an existing Tracecat user,
looked up by the email claim, and that account only exists once someone completes the
sign-up form. Until you have signed up as `superadmin_email`, you will authenticate
successfully and still get 401.

Full client walkthrough — the OAuth hops, scope conflicts, what to run after a rebuild —
in [mcp-clients.md](mcp-clients.md).

### Why TLS is not optional here

The MCP server validates its own issuer URL and refuses anything that is not https. That
check is in the MCP SDK (`mcp/server/auth/routes.py`), is hard-coded per RFC 8414, and
exempts only `localhost` — so it applies to Tracecat's own issuer exactly as it applied
to an external one. This is why `enable_mcp` requires `app_hostname`, and Terraform says
so at plan time.

Caddy obtains a Let's Encrypt certificate for that name on first boot. Two consequences
worth knowing:

- **Port 80 opens to the internet.** Let's Encrypt validates HTTP-01 from addresses it
  does not publish, so the rule cannot be narrowed. Caddy serves the challenge there and
  redirects everything else to 443, which stays restricted to `allowed_cidrs`.
- **The name must resolve before the bootstrap runs.** Set `hosted_zone_id` and Terraform
  writes the A record in the same apply; otherwise create it yourself first.

### Mind the version

This works from `1.0.0-beta.51` onward and **not before**. Earlier releases shipped the
MCP server as an OIDC *proxy* that forwarded authorization to an external provider and
refused to start without one:

```
OIDC_ISSUER must be configured for the MCP server.
```

It then crash-loops under `restart: on-failure:3` and Caddy answers an empty-bodied 502 on
`/mcp` while every other route stays healthy — which reads like a routing fault and is not
one.

**Upstream's tag names do not sort by date.** `1.0.0` was cut 2026-04-03, four months
*before* `1.0.0-beta.51` (2026-08-10), and its own `docker-compose.yml` defaults the
images to `1.0.0-beta.37`. Pinning `tracecat_version = "1.0.0"` therefore gets you the old
behaviour and a 502. Check a tag's commit date before pinning it.

`tracecat_version` selects the tag the compose files are fetched from *and* the container
images, written into `.env` as `TRACECAT__IMAGE_TAG`. Upstream's compose file has its own
hardcoded fallback for that variable, which is not always the tag the file came from, so
this module sets it explicitly. Split them with `tracecat_image_tag` only if you have a
reason to.

```bash
terraform output tracecat_version_deployed   # files=... images=...
terraform output mcp_signin
```

## 6. Back up the secrets, now

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo cat /opt/tracecat/.env
```

Four values in that file are unrecoverable if lost:
`TRACECAT__SERVICE_KEY`, `TRACECAT__SIGNING_SECRET`, `TRACECAT__DB_ENCRYPTION_KEY`,
`USER_AUTH_SECRET`. They were generated on the instance and exist nowhere else — not in
Terraform state, not in this repository. Losing them means losing every stored credential
and every webhook.

Copy them somewhere safe before you do anything else with the instance. See
[operations.md](operations.md#backups), or
[secrets-sops.md](secrets-sops.md#storing-the-instances-own-secrets-the-same-way) for a
one-liner that pulls them off the instance and encrypts them in place.

---

## Tearing down

```bash
terraform destroy
```

Removes the instance, the volume, the Elastic IP, the security group and the IAM role.
Nothing persists — including the Tracecat database. Take a backup first if you care about
what is in it.
