# Employee Task Tracker — Infrastructure Repository

Terraform + Ansible for the AWS infrastructure this one application runs on: VPC, EKS, RDS, ECR, DNS/TLS lookups, and a shared Jenkins server. One `terraform apply` per environment builds everything except what's actually deployed onto the cluster — that's [employee-task-gitops](https://github.com/rashmiranjandevops/employee-task-gitops)'s job.

Part of a 3-repo project. The other two: [employee-task-app](https://github.com/rashmiranjandevops/employee-task-app) (application source and CI/CD — full setup docs live there since it's the natural starting point) and [employee-task-gitops](https://github.com/rashmiranjandevops/employee-task-gitops) (what's actually deployed).

## Project overview

This repo provisions AWS infrastructure for **one application, two environments** — not a reusable module library for multiple teams or projects. Every Terraform module here (`vpc`, `eks`, `rds`, `ecr`, `acm`, `route53`, `jenkins-server`) exists because it makes this specific setup easier to read, not because it's designed to be published or reused elsewhere.

## Architecture diagram

```
terraform/global (applied ONCE)              terraform/environments/{dev,prod}
  ECR (2 repos, shared)                        VPC (own CIDR per environment)
  ACM cert (shared)                             EKS cluster
  GitHub OIDC role (shared)                     RDS instance
  Jenkins EC2 (shared, bare)                     Kubernetes namespace + Secret
        │
        v
ansible/jenkins.yml
  installs Jenkins, Docker, kubectl,
  helm, trivy, yq, jq, Node.js
  directly on the EC2 instance
```

Global resources are applied once and shared by both environments (one ECR registry, one cert, one Jenkins server). Everything in `environments/` is applied twice — fully separate VPCs and EKS clusters per environment, real isolation rather than a namespace split on shared infrastructure.

## Folder structure

```
terraform/
  global/           ECR, ACM cert, GitHub OIDC role, Jenkins server — applied ONCE
  environments/     dev/ and prod/ tfvars + backend config
  modules/          vpc, eks, rds, ecr, acm, route53, jenkins-server

ansible/
  jenkins.yml       Configures the EC2 instance terraform/global provisions
  inventory.ini.example
  README.md

k8s/argocd/
  ingress.yaml.tpl   Template for ArgoCD's own UI Ingress — install-cluster-addons.sh
                       substitutes in the real ACM cert ARN before applying it

scripts/
  bootstrap-backend.sh       One-time S3 + DynamoDB setup for Terraform state
  sync-config.sh             Reads terraform/global's outputs, updates
                               employee-task-gitops automatically
  install-cluster-addons.sh   Installs the AWS Load Balancer Controller (with
                               IRSA, verified end-to-end) + ArgoCD + ArgoCD's
                               own Ingress onto a given environment's cluster
  update-dns.sh               Idempotent UPSERT/DELETE for one hostname —
                               always reads the current value itself rather
                               than requiring one to be hand-typed
```

## Technology stack

Terraform · Ansible · AWS (VPC, EKS, RDS, ECR, IAM, Route53, ACM, EC2)

## Setup instructions

```bash
cd terraform
../scripts/bootstrap-backend.sh us-east-1     # one-time: creates the S3 + DynamoDB backend

cd global
terraform init -backend-config=backend.hcl
terraform apply -var="jenkins_admin_cidr=<your-ip>/32" -var="jenkins_ssh_key_name=<your-key>"

cd ../../ansible
ansible-playbook jenkins.yml                   # installs Jenkins + tooling on the EC2 box
```
Full order across all 3 repos, with every value explained: `employee-task-app`'s [INSTALL.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/INSTALL.md). Copy-paste-only version: `employee-task-app`'s [runbook/EXECUTION-GUIDE.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/runbook/EXECUTION-GUIDE.md).

## Deployment instructions

"Deploying" this repo means applying Terraform and re-running Ansible when either changes:

```bash
# Infrastructure change
cd terraform/environments/dev
terraform plan -var-file=terraform.tfvars     # always review before applying
terraform apply -var-file=terraform.tfvars

# Jenkins server change
cd ../../../ansible
ansible-playbook jenkins.yml                   # idempotent, safe to re-run
```
Apply to dev first, confirm nothing broke, then repeat against `environments/prod`.

## Rollback procedure

Terraform's own state history is the rollback mechanism: `git revert` the `.tf`/`.tfvars` change in question, then `terraform apply` again — the previous `apply` output is your target state. There's no separate rollback tooling here, unlike `employee-task-gitops` (which has `rollback.sh`), because infra changes are infrequent and reviewed via `terraform plan` *before* they're ever applied — the safety net is upstream of the apply, not after it.

## Troubleshooting guide

| Symptom | Likely cause |
|---|---|
| `Error: Error acquiring the state lock` | A previous `apply`/`plan` didn't exit cleanly — `terraform force-unlock <lock-id>` after confirming no one else is applying |
| ECR/ACM "already exists" on an environment apply | `terraform/global` applied more than once, or applied after an environment instead of before |
| `data.aws_route53_zone.this: no matching Route53Zone found` | The domain's hosted zone doesn't exist in this account yet — this repo only looks it up, never creates it |
| ACM stuck `PENDING_VALIDATION` past when `terraform apply` finishes | Almost always DNS delegation, not a Terraform bug — `dig NS <domain> +short` should return AWS nameservers |
| Ansible `UNREACHABLE!` | Stale IP in `inventory.ini`, wrong key path, or your IP changed since `jenkins_admin_cidr` was set |
| Jenkins job fails with "command not found" | Ansible hasn't been (re-)run since the EC2 instance was provisioned |
| ALB never gets created / Ingress has no `ADDRESS` | Almost always IRSA — see `employee-task-app`'s TROUBLESHOOTING.md's dedicated IRSA section, which walks through checking both halves of the IRSA setup independently |

Full troubleshooting guide (covers all 3 repos): `employee-task-app`'s [TROUBLESHOOTING.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/TROUBLESHOOTING.md).

## Screenshots

_Add a `terraform plan` output, the AWS Console showing the EKS cluster and RDS instance, and the Jenkins UI here once deployed._

## Why Terraform provisions the Jenkins box but doesn't configure it

Terraform is good at "make this resource exist with these properties." It's a worse fit for "install this list of packages and make sure this service is running" — that's what Ansible is for. `terraform/modules/jenkins-server` creates a bare EC2 instance with the right IAM role and security group; `ansible/jenkins.yml` does everything after that. Two tools, each doing the part it's actually built for, instead of one giant `user_data` shell script trying to do both.

## Why the AWS Load Balancer Controller uses IRSA, not the node's IAM role

The controller's IAM role and policy (`terraform/modules/eks/irsa.tf`) are entirely Terraform-managed — no manually pre-created policy required outside of this repo, so a fresh clone works on a fresh AWS account without any undocumented setup step. `scripts/install-cluster-addons.sh` then annotates the controller's ServiceAccount with that role's ARN and verifies the annotation actually landed before continuing, since Terraform creating a correct IRSA role has zero effect on the running pod until that annotation exists. There's deliberately no fallback IAM policy on the node role — a broken IRSA setup fails loudly (`AccessDenied`) instead of silently working anyway. Full reasoning: `employee-task-app`'s [ARCHITECTURE.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/ARCHITECTURE.md#why-the-aws-load-balancer-controller-uses-irsa).

## Interview questions & lessons learned

Covered in `employee-task-app`'s [ARCHITECTURE.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/ARCHITECTURE.md) — including the Terraform/Ansible split and the global-vs-per-environment state split, both decisions made in this repo.
