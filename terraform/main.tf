# terraform/ (per-environment) — everything that has its own copy in dev AND
# prod: the VPC, the EKS cluster, the RDS instance, and the Kubernetes
# Secret the app needs to boot. Account-level resources shared by both
# environments (ECR, the ACM cert, the GitHub OIDC role) live in
# terraform/global instead — see that directory's main.tf for why.
#
# Usage:
#   terraform init -backend-config=environments/dev/backend.hcl
#   terraform apply -var-file=environments/dev/terraform.tfvars

terraform {
  required_version = ">= 1.6.0"

  required_providers {
  aws = {
    source  = "hashicorp/aws"
    version = "~> 5.31"
  }

  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = "~> 2.25"
  }

  random = {
    source  = "hashicorp/random"
    version = "~> 3.6"
  }

  tls = {
    source  = "hashicorp/tls"
    version = "~> 4.0"
  }
}

  backend "s3" {
    # terraform init -backend-config=environments/<env>/backend.hcl
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "employee-task"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cluster_name = "employee-task-${var.environment}"
  namespace    = "employee-task-${var.environment}"
}

# ─── Networking ─────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  database_subnets   = var.database_subnets
}

# ─── EKS ──────────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name        = local.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}

# ─── RDS ──────────────────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  identifier              = "employee-task-${var.environment}-db"
  vpc_id                  = module.vpc.vpc_id
  database_subnet_ids     = module.vpc.database_subnet_ids
  allowed_security_groups = [module.eks.node_security_group_id]
  instance_class          = var.rds_instance_class
  multi_az                = var.rds_multi_az
}

# ─── Kubernetes auth (reuses the EKS cluster this config just created) ────────

# The kubernetes provider authenticates via `aws eks get-token` (an exec
# plugin), not a static token fetched once via `data.aws_eks_cluster_auth`.
# A statically-fetched token can expire mid-apply on a long run (EKS tokens
# are short-lived); the exec plugin re-fetches a fresh token for every API
# call the provider makes instead, which avoids that failure mode entirely.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name
    ]
  }
}

# ─── App secrets ────────────────────────────────────────────────────────────
# No External Secrets Operator here — that's a whole extra controller + IAM
# role just to read two values. Terraform already knows the RDS credentials
# (it just created them) and generates the JWT signing secrets itself, so it
# writes them straight into a Kubernetes Secret in the same apply. The Helm
# chart references this Secret by name; it never creates or contains secret
# values itself, so nothing sensitive is ever committed to Git.
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "random_password" "jwt_refresh_secret" {
  length  = 48
  special = false
}

resource "kubernetes_namespace" "app" {
  metadata {
    name = local.namespace
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "app" {
  metadata {
    name      = "employee-task-secrets"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    DB_HOST            = module.rds.endpoint
    DB_PORT            = tostring(module.rds.port)
    DB_NAME            = module.rds.database_name
    DB_USER            = module.rds.master_username
    DB_PASSWORD        = module.rds.master_password
    JWT_SECRET         = random_password.jwt_secret.result
    JWT_REFRESH_SECRET = random_password.jwt_refresh_secret.result
  }

  type = "Opaque"
}
