output "allowed_cidrs_effective" {
  description = "CIDR blocks actually permitted to reach the UI — either what you set, or the address Terraform detected."
  value       = local.effective_cidrs
}

output "public_ip" {
  description = "Public IPv4 address of the Tracecat instance."
  value       = var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
}

output "app_url" {
  description = "Open this in a browser once the bootstrap finishes."
  value       = "${local.enable_tls ? "https" : "http"}://${local.app_host != "" ? local.app_host : (var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip)}"
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "superadmin_email" {
  description = "Sign up with this address on first visit to claim the superadmin account."
  value       = var.superadmin_email
}

output "ssm_session_command" {
  description = "Open a shell on the instance without SSH or an open port."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.aws_region}"
}

output "ssh_command" {
  description = "SSH command, if enable_ssh is true."
  value       = var.enable_ssh ? "ssh ubuntu@${var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip}" : "SSH is disabled; use the ssm_session_command output"
}

output "watch_bootstrap_command" {
  description = "Follow the install as it happens. Expect 5-15 minutes."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.aws_region} --document-name AWS-StartInteractiveCommand --parameters command='tail -f /var/log/tracecat-bootstrap.log'"
}

output "mcp_url" {
  description = "MCP endpoint, or a note explaining why there isn't one."
  value = (
    var.enable_mcp && local.enable_tls
    ? "https://${var.app_hostname}/mcp"
    : "MCP is not available: it needs app_hostname set for TLS"
  )
}

output "mcp_signin" {
  description = "How to authenticate an MCP client. There is no generated password to fetch."
  value = (
    var.enable_mcp && local.enable_tls
    ? "Sign in as ${var.superadmin_email} in the browser flow, or mint a personal access token at https://${var.app_hostname}/workspaces/<workspace-id>/mcp. Tracecat issues its own tokens; no identity provider to configure."
    : "MCP is not available: it needs app_hostname set for TLS"
  )
}

output "tracecat_version_deployed" {
  description = "The upstream tag the compose files came from, and the image tag pinned alongside it."
  value       = "files=${var.tracecat_version} images=${local.image_tag}"
}
