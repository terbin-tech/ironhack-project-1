# TFLint for both root modules: scripts/check.sh runs it with --recursive and
# this file's absolute path. The bundled terraform ruleset needs no block.
plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
