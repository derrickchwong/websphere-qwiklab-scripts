resource "google_project_service" "container" {
  service = "container.googleapis.com"
}

resource "google_project_service" "artifactregistry" {
  service = "artifactregistry.googleapis.com"
}

resource "google_project_service" "cloudbuild" {
  service = "cloudbuild.googleapis.com"
}

resource "google_project_service" "cloudapis" {
  service = "cloudapis.googleapis.com"
}

resource "google_project_service" "alloydb" {
  service = "alloydb.googleapis.com"
}

resource "google_project_service" "datamigration" {
  service = "datamigration.googleapis.com"
}

resource "google_project_service" "servicenetworking" {
  service = "servicenetworking.googleapis.com"
}

resource "google_project_service" "workstations" {
  service = "workstations.googleapis.com"
}

resource "google_project_iam_binding" "cloudbuild_compute_admin" {
  project = var.gcp_project_id
  role    = "roles/compute.admin"
  members = ["serviceAccount:${var.gcp_project_number}@cloudbuild.gserviceaccount.com"]
}

resource "google_project_iam_binding" "cloudbuild_iam_service_account_user" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountUser"
  members = ["serviceAccount:${var.gcp_project_number}@cloudbuild.gserviceaccount.com"]
}

resource "google_project_iam_binding" "cloudbuild_iam_service_account_token_creator" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  members = ["serviceAccount:${var.gcp_project_number}@cloudbuild.gserviceaccount.com"]
}

resource "google_workstations_cluster" "workstation_cluster" {
  name        = "workstation-cluster"
  location    = var.gcp_region
  network     = "projects/${var.gcp_project_id}/global/networks/default"
  subnetwork  = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/default"
  description = "Terraform-created workstation cluster"
  state       = "ACTIVE"

}

resource "google_workstations_config" "workstation_config" {
  name          = "workstation-config"
  cluster       = google_workstations_cluster.workstation_cluster.name
  location      = google_workstations_cluster.workstation_cluster.location
  machine_type  = "e2-standard-4"
  pool_size     = 1
}

resource "google_workstations_workstation" "default" {
  provider               = google-beta
  workstation_id         = "work-station"
  workstation_config_id  = google_workstations_workstation_config.workstation_config.id
  workstation_cluster_id = google_workstations_workstation_cluster.workstation_cluster.id
  location               = var.gcp_region
  project                = var.gcp_project_id
}

resource "google_container_cluster" "autopilot_cluster" {
  name     = "autopilot-cluster-1"
  location = var.gcp_region

  network    = "projects/${var.gcp_project_id}/global/networks/default"
  subnetwork = "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/default"

  enable_autopilot = true

  cluster_ipv4_cidr = "/17"

  release_channel {
    channel = "GOOGLE_STABLE"
  }

  binary_authorization {
    evaluation_mode = "DISABLED"
  }
}

resource "google_artifact_registry_repository" "container" {
  location      = var.gcp_region
  repository_id = "container"
  description   = "Container repository"
  format        = "DOCKER"
}

resource "google_compute_address" "default-ip-range" {
  name          = "default-ip-range"
  purpose       = "VPC_PEERING"
  prefix_length = 16
  network       = "default"
}

resource "google_service_vpc_peering_connection" "default" {
  service = "servicenetworking.googleapis.com"
  network = "default"
  ranges  = ["default-ip-range"]
}

resource "google_alloydb_cluster" "alloydb1" {
  cluster_id       = "alloydb1"
  name             = "alloydb1"
  location         = var.gcp_region
  database_version = "POSTGRES_14"
  initial_user {
    password = "postgres"
  }
  network_config {
    allocated_ip_range = google_compute_address.default-ip-range
  }
}

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.alloydb1
  instance_type = "PRIMARY"
  instance_id = "primary"
  machine_config {
    cpu_count = 2
  }
  client_connection_config {
    ssl_config {
      ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }
  }
}

resource "google_compute_firewall" "allow-was" {
  network = google_compute_network.default.name
  name        = "allow-was"
  direction   = "INGRESS"
  target_tags = ["was"]
  allow {
    protocol = "tcp"
    ports        = ["9060", "9080"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow-oracle" {
  network = google_compute_network.default.name
  name        = "allow-oracle"
  direction   = "INGRESS"
  target_tags = ["oracle"]
  allow {
    protocol = "tcp"
    ports        = ["1521"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_network" "dms-psc-vpc" {
  name         = "dms-psc-vpc"
  project      = var.gcp_project_id
  auto_create_subnetworks = false
  
}

resource "google_compute_subnetwork" "dms-psc" {
  name          = "dms-psc-${var.gcp_region}"
  project       = var.gcp_project_id
  network       = google_compute_network.dms-psc-vpc.name
  region        = var.gcp_region
  ip_cidr_range = "10.0.0.0/16"
}

resource "google_compute_router" "ex-router" {
  name        = "ex-router-${var.gcp_region}"
  network     = google_compute_network.dms-psc-vpc.name
  project     = var.gcp_project_id
  region      = var.gcp_region
  description = "Terraform-created router"
}

resource "google_compute_router_nat" "ex-nat" {
  name        = "ex-nat-${var.gcp_region}"
  router      = google_compute_router.ex-router.name

  
}
