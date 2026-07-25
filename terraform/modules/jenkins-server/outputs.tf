output "public_ip" {
  description = "Feed this into ansible/inventory.ini to run the playbook"
  value       = aws_instance.jenkins.public_ip
}

output "instance_id" {
  value = aws_instance.jenkins.id
}
