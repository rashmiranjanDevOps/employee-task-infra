variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "Domain this project is deployed under (already registered, nameservers already pointed at Route53)"
  type        = string
  default     = "rashmidevops.xyz"
}

variable "github_repo_subject" {
  description = <<-EOT
    OIDC subject this role trusts, GitHub's immutable-ID format:
    repo:OWNER@OWNER_ID/REPO@REPO_ID:*
    Get the IDs with:
      gh api /orgs/<org> --jq .id          # owner_id
      gh api /repos/<org>/<repo> --jq .id  # repo_id
  EOT
  type        = string
  default     = "rashmiranjanDevOps@257695109/employee-task-app@1311664685"
}

variable "jenkins_admin_cidr" {
  description = "CIDR allowed to reach the Jenkins server (SSH + UI) - your own IP, e.g. \"203.0.113.5/32\""
  type        = string
}

variable "jenkins_ssh_key_name" {
  description = "Name of an existing EC2 key pair for Ansible to connect over SSH"
  type        = string
}
