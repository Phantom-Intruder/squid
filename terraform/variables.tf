variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (prod/staging)"
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "squid-vpc"
}

variable "subnet_name" {
  description = "Name of the subnet within the VPC"
  type        = string
  default     = "squid-subnet"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "cluster_name" {
  description = "Cluster name prefix"
  type        = string
  default     = "squid"
}
