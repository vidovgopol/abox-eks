output "agentgw_sg_id" {
  description = "Security group ID attached to the agentgateway load balancer"
  value       = aws_security_group.agentgw_lb.id
}
