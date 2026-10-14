#!/usr/bin/env bash
# Runs every code check, locally before a push and in CI (.github/workflows/checks.yml).
# Each check runs even if an earlier one failed; the exit status is 1 if any failed.
# It installs no tools: terraform init and ansible-lint fetch into gitignored folders on a
# fresh checkout; run `tflint --init` once to fetch the TFLint aws plugin.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

failed=()

check() {
  local name=$1
  shift
  echo "==> ${name}"
  if "$@"; then
    echo "ok: ${name}"
  else
    echo "FAILED: ${name}"
    failed+=("${name}")
  fi
}

# A fresh checkout has no .terraform: initialize without the S3 backend,
# which needs no AWS credentials. An initialized directory is left as it is.
terraform_validate() {
  local dir status=0
  for dir in infra/bootstrap infra/main; do
    if [[ ! -d "${dir}/.terraform" ]]; then
      terraform -chdir="${dir}" init -backend=false -input=false >/dev/null || { status=1; continue; }
    fi
    terraform -chdir="${dir}" validate || status=1
  done
  return "${status}"
}

# Tracked and new files only: ansible-lint installs collections into the
# gitignored ansible/.ansible/, which carry their own scripts and Dockerfiles.
repo_files() {
  git ls-files --cached --others --exclude-standard "$@"
}

mapfile -t shell_scripts < <(repo_files '*.sh')
mapfile -t dockerfiles < <(repo_files '*Dockerfile')

check "terraform fmt" terraform fmt -check -recursive infra
check "terraform validate" terraform_validate
check "tflint" tflint --recursive --config "${PWD}/.tflint.hcl"
# The variables file supplies admin_cidr, without which Checkov cannot expand
# the security group rules and checks them only vacuously.
check "checkov" checkov --directory . \
  --framework terraform ansible dockerfile github_actions secrets \
  --var-file infra/main/terraform.tfvars.example --quiet --compact
check "ansible-lint" ansible-lint --project-dir ansible --profile production
check "shellcheck" shellcheck "${shell_scripts[@]}"
check "hadolint" hadolint "${dockerfiles[@]}"
check "actionlint" actionlint

if ((${#failed[@]})); then
  echo "Failed checks: ${failed[*]}"
  exit 1
fi
echo "All checks passed."
