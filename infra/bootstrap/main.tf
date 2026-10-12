# Remote state bucket for infra/main. This module keeps its own state locally,
# because the bucket it creates cannot store the state that creates it.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:one-person state bucket; access logs would need a second bucket
  #checkov:skip=CKV_AWS_145:encrypted with S3-managed keys; a KMS key adds cost for no gain here
  #checkov:skip=CKV_AWS_144:a one-week stack needs no cross-region copy; versioning covers mistakes
  #checkov:skip=CKV2_AWS_62:nothing consumes bucket events

  # Bucket names are global, so the account id and region keep it unique.
  bucket = "${var.name_prefix}tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"

  # The stack is torn down after the course presentation; let destroy remove
  # the versioned state objects too.
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}tfstate"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions only matter for a recent rollback.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  # Noncurrent-version rules need versioning enabled first (provider docs).
  depends_on = [aws_s3_bucket_versioning.state]

  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "local_file" "main_backend_config" {
  filename        = "${path.module}/../main/backend.hcl"
  file_permission = "0644"
  content         = <<-EOT
    bucket = "${aws_s3_bucket.state.bucket}"
    region = "${var.region}"
  EOT
}
