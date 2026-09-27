output "url" {
  description = "The load balancer's own HTTPS URL. Point a DNS name covered by certificate_arn at it (alias record: alb_dns_name + alb_zone_id)."
  value       = "https://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "admin_api_key_secret_arn" {
  description = "Where the admin API key lives. It is deliberately not an output itself: it never enters Terraform state."
  value       = aws_secretsmanager_secret.admin_api_key.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "db_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "security_group_ids" {
  value = {
    alb    = aws_security_group.alb.id
    api    = aws_security_group.api.id
    worker = aws_security_group.worker.id
    db     = aws_security_group.db.id
    cache  = aws_security_group.cache.id
  }
}
