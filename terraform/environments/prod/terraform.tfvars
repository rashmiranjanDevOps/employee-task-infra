environment = "prod"
aws_region  = "us-east-1"

# ─── Networking ─────────────────────────────────────────────────────────────
vpc_cidr           = "10.20.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
public_subnets     = ["10.20.0.0/24", "10.20.1.0/24"]
private_subnets    = ["10.20.10.0/24", "10.20.11.0/24"]
database_subnets   = ["10.20.20.0/24", "10.20.21.0/24"]

# ─── EKS ──────────────────────────────────────────────────────────────────────
cluster_version     = "1.30"
node_instance_types = ["t3.medium"]
node_min_size       = 1
node_max_size       = 3
node_desired_size   = 2

# ─── RDS ──────────────────────────────────────────────────────────────────────
rds_instance_class = "db.t3.small"
rds_multi_az       = true
