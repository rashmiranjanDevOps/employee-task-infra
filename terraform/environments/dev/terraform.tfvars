environment = "dev"
aws_region  = "us-east-1"

# ─── Networking ─────────────────────────────────────────────────────────────
vpc_cidr           = "10.10.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
public_subnets     = ["10.10.0.0/24", "10.10.1.0/24"]
private_subnets    = ["10.10.10.0/24", "10.10.11.0/24"]
database_subnets   = ["10.10.20.0/24", "10.10.21.0/24"]

# ─── EKS ──────────────────────────────────────────────────────────────────────
cluster_version     = "1.30"
node_instance_types = ["c7i-flex.large"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 4

# ─── RDS ──────────────────────────────────────────────────────────────────────
rds_instance_class = "db.t4g.micro"
rds_multi_az       = false
