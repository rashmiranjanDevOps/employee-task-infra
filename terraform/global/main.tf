# terraform/global — resources that exist ONCE per AWS account, not once per
# environment: ECR repositories (dev and prod push to the SAME repos, just
# different tags), the ACM certificate, and the IAM role GitHub Actions
# assumes. Applying this from two environments' separate state files would
# mean both trying to create the same ECR repo — apply this ONE time,
# before either environment. See INSTALL.md for the exact order.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.31"
    }
  }

  backend "s3" {
    # terraform init -backend-config=backend.hcl
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "employee-task"
      Scope     = "global"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

module "ecr" {
  source = "../modules/ecr"
}

module "route53" {
  source = "../modules/route53"

  domain_name = var.domain_name
}

module "acm" {
  source = "../modules/acm"

  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  route53_zone_id           = module.route53.zone_id
}

# ─── GitHub Actions OIDC: lets .github/workflows/ci-cd.yml push to ECR ────────
# without storing a long-lived AWS access key as a GitHub secret. GitHub
# issues a short-lived, workflow-scoped OIDC token; AWS trusts it was really
# issued by GitHub via this provider, then hands out short-lived AWS
# credentials scoped to exactly the role below. One role, shared by both
# environments' CI runs, since they push to the same ECR repos.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # No thumbprint_list: AWS provider v5.x made this optional for
  # well-known OIDC providers (including GitHub's) — AWS validates the
  # certificate chain itself now instead of requiring a manually-supplied
  # thumbprint. This is intentional, not an oversight.
}

resource "aws_iam_role" "github_actions" {
  name = "employee-task-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Scoped to this one repo so no other GitHub repo can assume this role.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_subject}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "employee-task-github-actions-ecr"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = values(module.ecr.repository_arns)
      }
    ]
  })
}

# ─── Jenkins ────────────────────────────────────────────────────────────────
# One shared server — either environment's CI can push through it, the same
# way both push through the same ECR repos. Terraform only provisions the
# instance itself; ../ansible/jenkins.yml installs and configures Jenkins.
module "jenkins_server" {
  source = "../modules/jenkins-server"

  admin_cidr          = var.jenkins_admin_cidr
  ssh_key_name        = var.jenkins_ssh_key_name
  ecr_repository_arns = values(module.ecr.repository_arns)
}
