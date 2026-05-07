output "server_public_ip" {
  description = "The public IP address of the web server"
  value       = aws_instance.web.public_ip
}
