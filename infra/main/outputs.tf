output "bastion_public_ip" {
  description = "Public IP of the bastion, the only SSH entry."
  value       = aws_instance.this["bastion"].public_ip
}

output "backend_private_ip" {
  description = "Private IP of the backend host (Redis, worker)."
  value       = aws_instance.this["backend"].private_ip
}

output "db_private_ip" {
  description = "Private IP of the database host (Postgres)."
  value       = aws_instance.this["db"].private_ip
}

output "app_url" {
  description = "vote, through the load balancer over HTTPS."
  value       = "https://${local.app_fqdn}/"
}

output "result_url" {
  description = "result, through the load balancer over HTTPS."
  value       = "https://${local.app_fqdn}/result/"
}
