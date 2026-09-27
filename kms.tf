# One customer-managed key for everything holding hookrelay's data at rest:
# the database, its Performance Insights data, Redis, and the three secrets.
# The default key policy delegates to IAM, so the only principal that can
# decrypt the secrets at runtime is the task execution role, through the
# policy in iam.tf.
resource "aws_kms_key" "this" {
  description             = "${var.name}: RDS, ElastiCache and Secrets Manager"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
