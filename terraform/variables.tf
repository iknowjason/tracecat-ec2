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
  default     = "admin@example.com"

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.superadmin_email))
    error_message = "Must be a valid email address; Tracecat's own env.sh rejects anything else."
  }
}

variable "tracecat_version" {
  description = "Tracecat git tag to install. The bootstrap fetches env.sh, .env.example, Caddyfile and docker-compose.yml from this tag."
  type        = string
  default     = "1.0.0"
}

variable "app_hostname" {
  description = <<-DESC
    Hostname the browser will use, if you have one (e.g. tracecat.example.com).

    Leave null to use the instance's public IP address. Set this only once the
    DNS record actually points at the instance — Tracecat bakes it into
    PUBLIC_APP_URL and rejects mismatched browser origins.
  DESC
  type        = string
  default     = null
}

# ── MCP server ───────────────────────────────────────────────────────────────
# Tracecat's MCP container is an OIDC *proxy*: it forwards authorization to an
# identity provider rather than issuing tokens itself, and refuses to start
# without an issuer. Because docker-compose.yml sets `restart: on-failure:3` it
# then crash-loops, and Caddy answers an empty-bodied 502 on /mcp while the rest
# of the stack is perfectly healthy.
#
# It proxies via fastmcp's OIDCProxy, which registers ONE static client upstream
# and emulates dynamic client registration towards MCP clients itself. So the
# provider does not need to support DCR — any OIDC provider with a discovery
# document will do.
#
# By default this module deploys one: a Dex container alongside the stack, with
# a generated client secret and a single seeded login. That is what makes /mcp
# work out of the box. Set oidc_issuer to point at your own IdP instead.
#
# Why not Cognito, Okta or Auth0 by default: all three require callback URLs to
# be https:// (only http://localhost is exempt), and this deploy serves plain
# HTTP on an IP address. The MCP proxy's callback is
# <public URL>/auth/callback, so a hosted IdP cannot register it until the
# instance has a DNS name and a certificate. Dex accepts an http issuer, so it
# works on the box as shipped.

variable "enable_mcp" {
  description = <<-DESC
    Deploy the built-in Dex identity provider so the MCP server starts and
    http://<host>/mcp works without any external account.

    Dex is published on mcp_idp_port and its login is generated at boot; the
    bootstrap prints the credentials and writes them to /etc/tracecat/READY.

    Ignored when oidc_issuer is set — an explicit issuer always wins. Set this
    false and leave oidc_issuer null to deploy without the MCP server at all.
  DESC
  type        = bool
  default     = true
}

variable "mcp_idp_port" {
  description = <<-DESC
    Port the built-in Dex identity provider listens on, reachable from the same
    CIDRs as the UI. The browser is redirected here during MCP sign-in, so it
    must be reachable from wherever you run the MCP client.
  DESC
  type        = number
  default     = 5556

  validation {
    condition     = var.mcp_idp_port > 1024 && var.mcp_idp_port < 65536
    error_message = "mcp_idp_port must be between 1025 and 65535."
  }
}

variable "mcp_idp_image" {
  description = <<-DESC
    Container image for the built-in Dex identity provider.

    Pinned rather than :latest so a rebuild six months from now deploys what was
    tested. Bump it deliberately.
  DESC
  type        = string
  default     = "ghcr.io/dexidp/dex:v2.45.1"
}

variable "oidc_issuer" {
  description = <<-DESC
    External OIDC issuer URL for the MCP server, no trailing slash. For example
    https://example.okta.com/oauth2/default or https://accounts.google.com.

    Leave null to use the built-in Dex provider (see enable_mcp). Setting this
    replaces Dex entirely: no Dex container is deployed and mcp_idp_port is not
    opened.

    The issuer must serve /.well-known/openid-configuration, the instance needs
    outbound access to reach it, and the client registered there must allow
    <public URL>/auth/callback as a redirect URI — which for a hosted IdP means
    this instance needs a DNS name and TLS first.
  DESC
  type        = string
  default     = null

  validation {
    condition     = var.oidc_issuer == null || can(regex("^https://[^/]+(/[^/]+)*$", var.oidc_issuer))
    error_message = "oidc_issuer must be an https:// URL with no trailing slash."
  }
}

variable "oidc_client_id" {
  description = "OIDC client ID registered with the external issuer. Required when oidc_issuer is set; unused otherwise."
  type        = string
  default     = null
}

variable "oidc_client_secret" {
  description = <<-DESC
    OIDC client secret. Required when oidc_issuer is set.

    SECURITY: this is written into the instance's user_data, which is not a
    secret store. Anyone holding ec2:DescribeInstanceAttribute in this account
    can read it back, as can any process on the instance that reaches IMDS —
    including a compromised container. It is also recorded in Terraform state.

    For anything past evaluation, leave this null and write the secret into
    /opt/tracecat/.env by hand after the deploy. See docs/deploy.md.
  DESC
  type        = string
  default     = null
  sensitive   = true
}

variable "oidc_scopes" {
  description = <<-DESC
    Space-separated OIDC scopes requested by the MCP server.

    The server appends offline_access itself so the IdP issues refresh tokens,
    and retries once without it if the issuer rejects that scope.
  DESC
  type        = string
  default     = "openid profile email"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload   = "tracecat"
    managed_by = "terraform"
  }
}
