variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the names of created resources."
  type        = string
  default     = "tracecat"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,24}$", var.name_prefix))
    error_message = "name_prefix must be 2-24 characters of lowercase letters, digits or hyphens."
  }
}

# ── Access control ───────────────────────────────────────────────────────────

variable "allowed_cidrs" {
  description = <<-DESC
    CIDR blocks allowed to reach the Tracecat UI on port 80, and SSH if enabled.

    Leave this empty to have Terraform look up the public IP of whatever machine
    is running it and allow just that address as a /32. Set it explicitly when
    you need something else — a corporate range, several offices, a VPN egress.

    Your current address:  curl -s https://checkip.amazonaws.com
    Explicit form:         ["203.0.113.42/32"]
  DESC
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "Refusing 0.0.0.0/0. This instance serves unencrypted HTTP; restrict it to known addresses, or put TLS in front of it and edit this rule deliberately."
  }
}

variable "auto_detect_my_ip" {
  description = <<-DESC
    When allowed_cidrs is empty, look up the public IP of the machine running
    Terraform and allow that address only.

    This is the IP Terraform sees, which is not necessarily the one your browser
    uses — running from CI, a bastion, or a different VPN than your browser will
    allow the wrong address. Set allowed_cidrs explicitly in those cases.
  DESC
  type        = bool
  default     = true
}

variable "enable_ssh" {
  description = "Open port 22 to allowed_cidrs. Not required — SSM Session Manager is enabled and needs no inbound ports."
  type        = bool
  default     = false
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH. Only used when enable_ssh is true."
  type        = string
  default     = null
}

# ── Instance ─────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = <<-DESC
    EC2 instance type.

    The Tracecat compose stack runs roughly 15 containers, including two
    PostgreSQL instances, Temporal, MinIO, Redis and the agent workers.
    t3.xlarge (4 vCPU / 16 GB) is the comfortable default. t3.large
    (2 vCPU / 8 GB) works but leaves little headroom — expect slower starts and
    watch for OOM kills under load.
  DESC
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. The container images alone are several GB."
  type        = number
  default     = 60

  validation {
    condition     = var.root_volume_size >= 40
    error_message = "Use at least 40 GB; the Tracecat images plus volumes will not fit comfortably below that."
  }
}

# ── Networking ───────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC to deploy into. Leave null to use the account's default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Public subnet to deploy into. Leave null to pick one from the default VPC. The subnet must route to an internet gateway."
  type        = string
  default     = null
}

variable "allocate_eip" {
  description = <<-DESC
    Allocate an Elastic IP and bake it into the instance's configuration.

    Strongly recommended. Tracecat writes its public URL into .env at first boot
    and validates browser origins against it, so an address that changes when
    the instance stops breaks the UI until you regenerate the file.
  DESC
  type        = bool
  default     = true
}

# ── Tracecat ─────────────────────────────────────────────────────────────────

variable "superadmin_email" {
  description = <<-DESC
    Email address for the first Tracecat user — the superadmin.

    You claim the account by signing up with this exact address on first visit
    and choosing a password. Nothing is emailed to it: the compose stack has no
    SMTP service, so this is an identity, not a mailbox that has to receive.

    The default lets you deploy without supplying anything. Override it in
    terraform.tfvars if you would rather log in as yourself.
  DESC
  type        = string
  default     = "jostrom@stora.io"

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.superadmin_email))
    error_message = "Must be a valid email address; Tracecat's own env.sh rejects anything else."
  }
}

variable "tracecat_version" {
  description = <<-DESC
    Tracecat git tag to install. The bootstrap fetches env.sh, .env.example,
    Caddyfile and docker-compose.yml from this tag, and pins the container
    images to it unless tracecat_image_tag overrides that.

    DO NOT "upgrade" this to "1.0.0". Upstream's tag names do not sort by date:
    1.0.0 was cut 2026-04-03, four months BEFORE 1.0.0-beta.51 (2026-08-10), and
    its own compose file defaults the images to 1.0.0-beta.37. At 1.0.0 the mcp
    container is an OIDC proxy that needs an external identity provider; from
    beta.51 Tracecat issues its own tokens and needs none. Check the commit date
    of any tag before pinning it.
  DESC
  type        = string
  default     = "1.0.0-beta.51"
}

variable "tracecat_image_tag" {
  description = <<-DESC
    Container image tag for the Tracecat services, written into .env as
    TRACECAT__IMAGE_TAG. Leave null to track tracecat_version.

    Upstream's docker-compose.yml interpolates $${TRACECAT__IMAGE_TAG} with a
    hardcoded fallback, so without this the images come from whatever default
    that file happened to ship with — which is not necessarily the tag the
    compose file itself was fetched from. Setting it keeps code and images on
    the same version. Override only to run a different image against a known
    compose file.
  DESC
  type        = string
  default     = null
}

variable "app_hostname" {
  description = <<-DESC
    Hostname the browser will use, if you have one (e.g. tracecat.example.com).

    Leave null to use the instance's public IP address.

    Setting this turns on TLS, which is what makes /mcp usable: Caddy obtains a
    Let's Encrypt certificate for the name on first boot and the stack moves to
    https. Port 80 is then opened to the internet for the ACME challenge, while
    443 stays restricted to allowed_cidrs.

    Tracecat bakes this into PUBLIC_APP_URL and rejects mismatched browser
    origins, so it must be the name you actually browse to.
  DESC
  type        = string
  default     = null

  validation {
    condition     = var.app_hostname == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.app_hostname))
    error_message = "app_hostname must be a bare DNS name such as tracecat.example.com — no scheme, port or trailing dot."
  }
}

# ── MCP server ───────────────────────────────────────────────────────────────
# From 1.0.0-beta.51 the MCP server authenticates against an OIDC issuer that
# Tracecat runs itself, on the API server at /api/oauth/mcp. The internal client
# secret is derived from USER_AUTH_SECRET, which env.sh already generates, so
# there is nothing to configure and no identity provider to deploy: bring the
# stack up and /mcp works.
#
# Earlier tags (including 1.0.0 — see tracecat_version) required an external
# provider, which is why this module used to deploy a Dex container. That is
# gone. If you pin an older tag, /mcp will not start.
#
# Two ways to authenticate a client, both handled by Tracecat:
#   - the browser OAuth flow, signing in as your Tracecat user;
#   - a workspace-scoped personal access token, minted in the UI under
#     /workspaces/<id>/mcp and sent as a bearer token.

# ── TLS ──────────────────────────────────────────────────────────────────────
# The MCP server refuses to start unless its own issuer URL is https. That check
# lives in the MCP SDK (mcp/server/auth/routes.py::validate_issuer_url), is
# hard-coded per RFC 8414, and exempts only localhost — so no choice of identity
# provider avoids it. If you want /mcp, this instance needs a DNS name and a
# certificate; everything else works fine over plain HTTP.

variable "hosted_zone_id" {
  description = <<-DESC
    Route 53 hosted zone ID that app_hostname belongs to, e.g. "Z1234567890ABC".

    Set alongside app_hostname and Terraform writes the A record pointing at the
    instance's Elastic IP. Leave null and create that record yourself — it has
    to resolve before Caddy's first ACME attempt during the bootstrap.
  DESC
  type        = string
  default     = null
}

variable "acme_email" {
  description = <<-DESC
    Contact address for the Let's Encrypt account. Defaults to superadmin_email.

    Expiry notices go here. It is not published, but it is sent to the CA.
  DESC
  type        = string
  default     = null
}

variable "enable_mcp" {
  description = <<-DESC
    Whether this deployment is expected to serve /mcp.

    Tracecat starts the mcp container either way — nothing here switches it off.
    What this does is enforce, at plan time, the one prerequisite it has:
    app_hostname must be set, because the MCP server refuses an issuer URL that
    is not https and a bare IP cannot have a certificate.

    Set false to deploy over plain HTTP and accept that /mcp will not work.
  DESC
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload   = "tracecat"
    managed_by = "terraform"
  }
}
