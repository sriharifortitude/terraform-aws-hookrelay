resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

# BullMQ requires maxmemory-policy noeviction. ElastiCache's default for
# Redis 7 is volatile-lru, under which Redis evicts keys as memory fills,
# and a delivery job's key is a key like any other: under memory
# pressure, queued deliveries would disappear with nothing logged.
resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.name}-redis7"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  tags = local.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "hookrelay delivery queue (BullMQ)"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.cache_node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.this.name

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.this.arn
  transit_encryption_enabled = true
  auth_token_wo              = ephemeral.random_password.redis.result
  auth_token_wo_version      = var.credentials_version

  snapshot_retention_limit = 3

  tags = local.tags
}
