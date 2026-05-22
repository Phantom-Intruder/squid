output "region" {
  description = "GCP region"
  value       = var.gcp_region
}

output "project_id" {
  description = "GCP Project ID"
  value       = var.gcp_project_id
}

output "vpc_name" {
  description = "VPC Network name"
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.subnet.name
}

output "squid_proxy_instances" {
  description = "Squid proxy instance names"
  value       = google_compute_instance.squid_proxy[*].name
}

output "squid_proxy_internal_ips" {
  description = "Internal IP addresses of Squid proxies"
  value       = google_compute_instance.squid_proxy[*].network_interface[0].network_ip
}
