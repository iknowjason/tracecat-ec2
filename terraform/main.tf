########################################################################
## Look up the network and the AMI
########################################################################

data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

# Only consulted when subnet_id is not supplied.
data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

# Canonical's official Ubuntu 24.04 LTS image. Owner 099720109477 is Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  # sort() so the choice is stable across runs; aws_subnets returns a set.
  subnet_id = var.subnet_id != null ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]

  # Look up our own address only when the operator did not supply a list.
  detect_my_ip = var.auto_detect_my_ip && length(var.allowed_cidrs) == 0

  # A for-expression over the (possibly empty) data source rather than
  # data.http.my_ip[0], so there is no index to evaluate when count is 0.
  detected_cidrs = [for r in data.http.my_ip : "${chomp(r.response_body)}/32"]

  effective_cidrs = length(var.allowed_cidrs) > 0 ? var.allowed_cidrs : local.detected_cidrs

  # Deploy Dex only when the MCP server is wanted and no external issuer was
  # given. An explicit oidc_issuer always wins; Dex would just be an unused
  # container and an open port.
  builtin_idp = var.enable_mcp && var.oidc_issuer == null

  # The address baked into Tracecat's .env at first boot.
  #
  # Order matters. An explicit hostname wins. Otherwise, if we allocated an
  # Elastic IP we use that — it is known before the instance exists, which
  # avoids the race where cloud-init would read the ephemeral public IP a
  # moment before the EIP is associated. With neither, this stays empty and the
  # bootstrap script asks instance metadata for the public IPv4 at boot.
  app_host = (
    var.app_hostname != null ? var.app_hostname :
    var.allocate_eip ? aws_eip.this[0].public_ip :
    ""
  )
}

########################################################################
## Who is allowed in
##
## If allowed_cidrs is empty we ask an external service for the public
## IP of the machine running Terraform and allow exactly that /32.
##
## This is a plan-time HTTP GET with no credentials. checkip.amazonaws.com
## returns the bare address as text/plain with a trailing newline.
########################################################################

data "http" "my_ip" {
  count = local.detect_my_ip ? 1 : 0

  url             = "https://checkip.amazonaws.com"
  request_headers = { Accept = "text/plain" }

  retry {
    attempts     = 3
    min_delay_ms = 500
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "checkip.amazonaws.com returned HTTP ${self.status_code}. Set allowed_cidrs explicitly, or auto_detect_my_ip = false."
    }
    postcondition {
      condition     = can(cidrnetmask("${chomp(self.response_body)}/32"))
      error_message = "Could not read an IPv4 address from checkip.amazonaws.com (got: ${chomp(self.response_body)}). Set allowed_cidrs explicitly."
    }
  }
}

########################################################################
## Security group
##
## Ingress is restricted to the effective CIDR list. Port 80 is the Caddy
## reverse proxy fronting the whole stack; nothing else is reachable.
########################################################################

resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-"
  description = "Tracecat: UI over HTTP from allowed CIDRs only"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg" })

  lifecycle {
    create_before_destroy = true

    # Without this, an empty list would silently produce a security group with
    # no ingress rules at all, and a Tracecat you cannot reach.
    precondition {
      condition     = length(local.effective_cidrs) > 0
      error_message = "No allowed CIDRs. Either set allowed_cidrs (e.g. [\"203.0.113.42/32\"]) or leave auto_detect_my_ip = true so Terraform can look up your address."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "ui" {
  for_each = toset(local.effective_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Tracecat UI (Caddy)"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "mcp_idp" {
  # The MCP sign-in flow redirects the operator's *browser* to Dex, so this has
  # to be reachable from wherever the MCP client runs — not just from the
  # instance. Same CIDRs as the UI.
  for_each = local.builtin_idp ? toset(local.effective_cidrs) : toset([])

  security_group_id = aws_security_group.this.id
  description       = "Built-in Dex identity provider for MCP"
  cidr_ipv4         = each.value
  from_port         = var.mcp_idp_port
  to_port           = var.mcp_idp_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = var.enable_ssh ? toset(local.effective_cidrs) : toset([])

  security_group_id = aws_security_group.this.id
  description       = "SSH"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Pull container images and OS packages"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

########################################################################
## Instance role
##
## Grants SSM Session Manager only. That gives you a shell on the box
## without opening port 22 and without managing a key pair.
########################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name_prefix}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.this.name
}

########################################################################
## Elastic IP
##
## Allocated before the instance so its address can be written into
## user_data. Tracecat records its public URL in .env at first boot, so a
## changing address means a broken UI after any stop/start.
########################################################################

resource "aws_eip" "this" {
  count  = var.allocate_eip ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-eip" })
}

resource "aws_eip_association" "this" {
  count = var.allocate_eip ? 1 : 0

  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this[0].id
}

########################################################################
## The instance
########################################################################

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = var.enable_ssh ? var.key_name : null

  associate_public_ip_address = true

  # Compressed twice, because EC2 caps user_data at 16 KB. The bootstrap script
  # is gzipped and base64'd on its own (cloud-init's gz+b64 encoding undoes it),
  # and the rendered document is gzipped again here — cloud-init detects and
  # decompresses that automatically. Base64-encoding the script without
  # compressing it first costs 33% on a payload the outer gzip then struggles
  # with: ~18 KB rendered, over the cap. This lands at ~12.6 KB. If you grow the
  # bootstrap script, re-measure.
  user_data_base64 = base64gzip(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    tracecat_version = var.tracecat_version
    superadmin_email = var.superadmin_email
    app_host         = local.app_host
    bootstrap_gz_b64 = base64gzip(file("${path.module}/../scripts/bootstrap.sh"))

    # Empty string rather than null: these land in a shell file that the
    # bootstrap sources, and "null" would be written literally.
    oidc_issuer        = var.oidc_issuer == null ? "" : var.oidc_issuer
    oidc_client_id     = var.oidc_client_id == null ? "" : var.oidc_client_id
    oidc_client_secret = var.oidc_client_secret == null ? "" : var.oidc_client_secret
    oidc_scopes        = var.oidc_scopes

    builtin_idp   = local.builtin_idp ? "y" : "n"
    mcp_idp_port  = var.mcp_idp_port
    mcp_idp_image = var.mcp_idp_image
  }))

  # Replace the instance if the bootstrap configuration changes; cloud-init
  # only runs on first boot, so an in-place update would do nothing.
  user_data_replace_on_change = true

  lifecycle {
    # Catch a half-configured MCP setup at plan time. The bootstrap checks this
    # too, but failing here costs nothing and saves a fifteen-minute install.
    precondition {
      condition = var.oidc_issuer == null || (
        var.oidc_client_id != null && var.oidc_client_secret != null
      )
      error_message = "oidc_client_id and oidc_client_secret are both required when oidc_issuer is set. Leave all three unset to deploy without the MCP server."
    }
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 only. The bootstrap script uses the token flow.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-server" })
}
