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
  description = "Email address for the first Tracecat user. You sign up with this address on first visit."
  type        = string

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

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload   = "tracecat"
    managed_by = "terraform"
  }
}
