output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "route53_zone_id" {
  value = module.route53.zone_id
}

output "acm_certificate_arn" {
  value = module.acm.certificate_arn
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "jenkins_public_ip" {
  description = "Feed into ansible/inventory.ini to run the Jenkins setup playbook"
  value       = module.jenkins_server.public_ip
}
