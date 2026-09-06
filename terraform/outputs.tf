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
    (var.enable_mcp || var.oidc_issuer != null) && local.enable_tls
    ? "https://${var.app_hostname}/mcp"
    : "MCP is not available: it needs app_hostname set for TLS"
  )
}

output "mcp_credentials_command" {
  description = "Read the generated MCP sign-in, which exists only on the instance."
  value = (
    local.builtin_idp
    ? "aws ssm start-session --target ${aws_instance.this.id} --region ${var.aws_region} --document-name AWS-StartInteractiveCommand --parameters command='sudo grep ^mcp_ /etc/tracecat/READY'"
    : "Not applicable: no built-in identity provider was deployed"
  )
}

# Same secret, fetched through Run Command instead of an interactive session, for
# anyone without the session-manager-plugin installed. The tradeoff is real:
# start-session streams the password and persists nothing, while Run Command keeps
# StandardOutputContent in SSM's invocation history (and the console) for 30 days.
# Prefer mcp_credentials_command unless the plugin is in the way.
output "mcp_credentials_command_no_plugin" {
  description = "Read the generated MCP sign-in without the session-manager-plugin. Leaves the password in SSM command history."
  value = (
    local.builtin_idp
    ? "cid=$(aws ssm send-command --region ${var.aws_region} --instance-ids ${aws_instance.this.id} --document-name AWS-RunShellScript --parameters 'commands=[\"grep ^mcp_ /etc/tracecat/READY\"]' --query Command.CommandId --output text) && aws ssm wait command-executed --region ${var.aws_region} --command-id \"$cid\" --instance-id ${aws_instance.this.id} && aws ssm get-command-invocation --region ${var.aws_region} --command-id \"$cid\" --instance-id ${aws_instance.this.id} --query StandardOutputContent --output text"
    : "Not applicable: no built-in identity provider was deployed"
  )
}
