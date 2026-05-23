# Squid Proxy Infrastructure on GCP

locals {
  cluster_name = "${var.cluster_name}-${var.environment}"

  common_labels = {
    environment = var.environment
    cluster     = local.cluster_name
  }
}

# VPC NETWORK
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.0.64.0/20"
  }
}

# FIREWALL RULES
resource "google_compute_firewall" "allow_internal" {
  name    = "${local.cluster_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${local.cluster_name}-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.vpc_name}-allow-iap-ssh"
  network = google_compute_network.vpc.id

  # This is the MANDATORY range for Google Identity Aware Proxy
  source_ranges = ["35.235.240.0/20"] 

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "squid_proxy" {
  count        = 2
  name         = "squid-proxy-${count.index + 1}"
  machine_type = "e2-medium"
  zone         = "${var.gcp_region}-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  labels = local.common_labels
}

resource "google_compute_router" "router" {
  name    = "${var.vpc_name}-router"
  network = google_compute_network.vpc.id
  region  = var.gcp_region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.vpc_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# 1. The Proxy-Only Subnet (Required for Regional Proxy ILBs)
resource "google_compute_subnetwork" "proxy_only" {
  name          = "proxy-only-subnet"
  ip_cidr_range = "10.129.0.0/23" # Must not overlap with your main subnet
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  region        = var.gcp_region
  network       = google_compute_network.vpc.id
}

# 2. The Health Check
resource "google_compute_region_health_check" "squid_health" {
  name   = "squid-health-check"
  region = var.gcp_region
  tcp_health_check {
    port = "3128"
  }
}

# 1. Create an Unmanaged Instance Group for your existing VMs
resource "google_compute_instance_group" "squid_group" {
  name        = "squid-proxy-group"
  description = "Group containing our Squid VMs"
  instances   = google_compute_instance.squid_proxy[*].id
  zone        = "${var.gcp_region}-a"

  named_port {
    name = "squid"
    port = 3128
  }
}

# 2. The Backend Service (The "Brain" of the Load Balancer)
resource "google_compute_region_backend_service" "squid_backend" {
  name                  = "squid-backend"
  region                = var.gcp_region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.squid_health.id]

  backend {
    group           = google_compute_instance_group.squid_group.id
    balancing_mode  = "UTILIZATION"
  }
}

# 3. The Forwarding Rule (The "Virtual IP" for the App)
resource "google_compute_forwarding_rule" "squid_ilb" {
  name                  = "squid-ilb-forwarding-rule"
  region                = var.gcp_region
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "3128"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.subnet.id
  backend_service       = google_compute_region_backend_service.squid_backend.id
  
  # This ensures the ILB only uses the Proxy-Only subnet
  depends_on = [google_compute_subnetwork.proxy_only]
}