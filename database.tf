resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-postgres17"
  family = "postgres17"

  # The default on RDS for PostgreSQL 15+, set explicitly so it can't be
  # lost by someone swapping in a different parameter group.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = local.tags
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = "17"

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  db_name             = local.db_name
  username            = local.db_username
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = var.credentials_version

  multi_az               = var.db_multi_az
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period   = var.db_backup_retention_days
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final"

  auto_minor_version_upgrade      = true
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.this.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = local.tags
}
