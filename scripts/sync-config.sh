#!/usr/bin/env bash
# sync-config.sh — automates the one repetitive, error-prone part of
# post-terraform setup: copying the ECR registry and ACM cert ARN into
# employee-task-gitops by hand. Run once, after `terraform apply` in
# terraform/global succeeds (global's outputs are shared by both
# environments).
#
# What it automates:
#   - Writes the ECR registry + ACM cert ARN into BOTH
#     environments/dev/values.yaml and environments/prod/values.yaml,
#     commits, and pushes. Both files get the same two values because both
#     environments share one ECR registry and one ACM certificate — there's
#     no shared values.yaml to hold them in a single place anymore, since
#     the Helm chart (and its defaults) now lives in employee-task-app, not
#     in the GitOps repo. See employee-task-app/ARCHITECTURE.md for why.
#
# What it prints instead of automating: the 5 GitHub Actions secrets/variables
# this project needs. Those get set once, by hand, in repo Settings → Secrets
# and variables → Actions — copying 5 values into a web form is a two-minute
# task that doesn't need a script and a GitHub CLI dependency to replace it.
#
# Requires: terraform, yq, jq, git.
#
# Usage:
#   ./sync-config.sh <gitops-repo-path>
# Example:
#   ./sync-config.sh ../employee-task-gitops

set -euo pipefail

GITOPS_PATH="${1:?Usage: $0 <gitops-repo-path>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBAL_DIR="${REPO_ROOT}/terraform/global"
AWS_REGION="us-east-1"
APP_DOMAIN="rashmidevops.xyz"

echo "==> Reading terraform/global outputs"
cd "${GLOBAL_DIR}"
ECR_URLS_JSON="$(terraform output -json ecr_repository_urls)"
ACM_CERT_ARN="$(terraform output -raw acm_certificate_arn)"
GITHUB_ROLE_ARN="$(terraform output -raw github_actions_role_arn)"

# Both repo URLs share the same registry prefix (everything before the
# first "/") — take it from either one.
ECR_REGISTRY="$(echo "${ECR_URLS_JSON}" | jq -r 'to_entries[0].value | split("/")[0]')"

# ─── Update both environment values files ──────────────────────────────────
cd "${GITOPS_PATH}"
for ENV in dev prod; do
  VALUES_FILE="environments/${ENV}/values.yaml"
  echo "==> Updating ${VALUES_FILE}"
  yq -i ".image.registry = \"${ECR_REGISTRY}\"" "${VALUES_FILE}"
  yq -i ".ingress.tls.certificateArn = \"${ACM_CERT_ARN}\"" "${VALUES_FILE}"
  git add "${VALUES_FILE}"
done

if git diff --cached --quiet; then
  echo "    (no changes — already up to date)"
else
  git commit -m "chore: sync registry + cert ARN from terraform/global outputs"
  git push origin HEAD
  echo "    committed and pushed"
fi

# ─── Print what to paste into GitHub Settings ──────────────────────────────
echo ""
echo "==> employee-task-gitops updated. Now set these in employee-task-app's"
echo "    GitHub Settings -> Secrets and variables -> Actions:"
echo ""
echo "    Secret    AWS_ROLE_ARN     ${GITHUB_ROLE_ARN}"
echo "    Variable  AWS_REGION       ${AWS_REGION}"
echo "    Variable  ECR_REGISTRY     ${ECR_REGISTRY}"
echo "    Variable  GITOPS_REPO      rashmiranjandevops/employee-task-gitops"
echo "    Variable  APP_DOMAIN       ${APP_DOMAIN}"
echo ""
echo "    Plus two more that don't come from terraform output at all:"
echo "    Secret    GITOPS_PAT         a fine-grained PAT, contents:write on employee-task-gitops only"
echo "    Secret    SLACK_WEBHOOK_URL  optional — from a Slack incoming webhook"
