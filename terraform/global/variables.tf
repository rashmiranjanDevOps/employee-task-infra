variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "Domain this project is deployed under (already registered, nameservers already pointed at Route53)"
  type        = string
  default     = "rashmidevops.xyz"
}

variable "github_repo" {
  description = "owner/repo of the app repo, allowed to assume the CI/CD IAM role"
  type        = string
  default     = "rashmiranjandevops/employee-task-app"
}

variable "jenkins_admin_cidr" {
  description = "CIDR allowed to reach the Jenkins server (SSH + UI) - your own IP, e.g. \"203.0.113.5/32\""
  type        = string
}

variable "jenkins_ssh_key_name" {
  description = "Name of an existing EC2 key pair for Ansible to connect over SSH"
  type        = string
}
