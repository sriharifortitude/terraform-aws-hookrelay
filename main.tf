locals {
  tags = merge({ "app" = "hookrelay", "managed-by" = "terraform" }, var.tags)
}
