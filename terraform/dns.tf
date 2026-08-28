########################################################################
## DNS
##
## A record straight at the instance's Elastic IP. Caddy terminates TLS on the
## box itself and obtains its own certificate from Let's Encrypt, so there is
## no load balancer to alias onto.
##
## The record must exist before Caddy's first ACME attempt, which happens during
## the bootstrap a few minutes after this is created. Terraform writes it as
## part of the same apply, so ordering works out; a manually created record
## needs to be in place first.
########################################################################

resource "aws_route53_record" "a_record" {
  # allocate_eip is part of the condition, not just the precondition below:
  # aws_eip.this[0] is an index into a zero-length list without it, which fails
  # while evaluating the expression rather than as a readable error.
  count = local.enable_tls && var.hosted_zone_id != null && var.allocate_eip ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.app_hostname
  type    = "A"
  ttl     = 60
  records = [aws_eip.this[0].public_ip]
}
