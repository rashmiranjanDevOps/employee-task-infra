output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "namespace" {
  description = "The Kubernetes namespace this environment's ArgoCD Application targets"
  value       = kubernetes_namespace.app.metadata[0].name
}

# Read by install-cluster-addons.sh to annotate the aws-load-balancer-controller
# ServiceAccount so the controller pod actually assumes this role instead of
# silently falling back to the node's own IAM role. Without this being
# wired into the Helm install command, the IRSA role Terraform creates has
# no effect at all — see ARCHITECTURE.md's IRSA section.
output "alb_controller_irsa_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller ServiceAccount"
  value       = module.eks.alb_controller_irsa_role_arn
}

output "oidc_provider_arn" {
  description = "This cluster's OIDC provider ARN - needed for any future IRSA role beyond the ALB Controller"
  value       = module.eks.oidc_provider_arn
}
