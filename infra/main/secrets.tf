# The database password lives only in Parameter Store. Terraform generates it as an
# ephemeral value and writes it through a write-only argument, so it never reaches
# the plan or the state; Ansible and the result instances read it from there.

locals {
  # Bump to rotate the password: the next apply writes a fresh one. Postgres keeps
  # the old one until it is changed there too (README, "Design notes").
  db_password_version = 1
}

ephemeral "random_password" "db" {
  # Letters and digits only: result puts the password unencoded into a
  # postgresql:// URL and the worker into a ;-separated connection string.
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  #checkov:skip=CKV_AWS_337:the AWS managed aws/ssm key encrypts it, and that key's policy allows decryption only to this account, through SSM

  name             = "${var.name_prefix}db-password"
  description      = "Postgres password for the voting app"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.db.result
  value_wo_version = local.db_password_version
}
