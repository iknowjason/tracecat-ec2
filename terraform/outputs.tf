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
  value       = "http://${local.app_host != "" ? local.app_host : (var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip)}"
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
