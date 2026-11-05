# ==============================================================================
# 1. Artifact Registry (Docker images for backend)
# ==============================================================================
resource "google_artifact_registry_repository" "docker_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "building-analytics-repo-${var.environment}"
  description   = "Docker repository for Building Analytics services (${var.environment})"
  format        = "DOCKER"
}

# ==============================================================================
# 2. Cloud Storage Bucket (Data storage)
# ==============================================================================
resource "google_storage_bucket" "app_data" {
  name                        = "building-analytics-data-${var.environment}"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
}

# ==============================================================================
# 3. Secret Manager: Database Password Generation & Secure Storage
# ==============================================================================
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_secret_manager_secret" "db_password_secret" {
  secret_id = "building-analytics-db-pass-${var.environment}"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_val" {
  secret      = google_secret_manager_secret.db_password_secret.id
  secret_data = random_password.db_password.result
}

# ==============================================================================
# 4. Networking: Custom VPC, Subnet & Private Service Access
# ==============================================================================
resource "google_compute_network" "vpc" {
  name                    = "building-analytics-vpc-${var.environment}"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "building-analytics-subnet-${var.environment}"
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  project                  = var.project_id
  private_ip_google_access = true
}

# Allocate a private IP range for Google managed services (Cloud SQL)
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "building-analytics-ip-alloc-${var.environment}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
  project       = var.project_id
}

# Establish private peering connection to Google Service Networking
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# ==============================================================================
# 5. Cloud SQL (PostgreSQL Instance with 100% Private IP - No Public IPv4)
# ==============================================================================
resource "random_id" "db_suffix_v2" {
  byte_length = 4
}

# The Cloud SQL Server Instance (Compute, RAM, Storage, and IP)
resource "google_sql_database_instance" "postgres" {
  name                = "building-analytics-instance-${var.environment}-${random_id.db_suffix_v2.hex}"
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = var.environment == "prod" ? true : false

  # Wait for the VPC peering connection to complete before creating the database
  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = var.db_tier
    availability_type = var.environment == "prod" ? "REGIONAL" : "ZONAL"

    ip_configuration {
      ipv4_enabled                                  = false # Zero Public IP!
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled    = true
      start_time = "04:00"
    }
  }
}

# The Logical PostgreSQL Database (Where tables and schemas live)
resource "google_sql_database" "app_db" {
  name     = "building_analytics_db_${var.environment}"
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
}

resource "google_sql_user" "app_user" {
  name     = "app_user"
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
  password = random_password.db_password.result
}

# ==============================================================================
# 6. Service Account for System Run & Database Connectivity
# ==============================================================================
resource "google_service_account" "app_runner" {
  account_id   = "building-analytics-runner-${var.environment}"
  display_name = "Building Analytics Runner SA (${var.environment})"
  project      = var.project_id
}

# Grant Cloud Run permission to connect to Cloud SQL
resource "google_project_iam_member" "sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app_runner.email}"
}

# Grant Cloud Run permission to read/write to the app data bucket
resource "google_storage_bucket_iam_member" "data_user" {
  bucket = google_storage_bucket.app_data.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.app_runner.email}"
}

# Grant Cloud Run permission to read the DB password secret
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  secret_id = google_secret_manager_secret.db_password_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_runner.email}"
  project   = var.project_id
}

# ==============================================================================
# 7. Cloud Run Service (Private Backend with Direct VPC Egress)
# ==============================================================================
resource "google_cloud_run_v2_service" "backend" {
  name     = "building-analytics-backend-${var.environment}"
  location = var.region
  project  = var.project_id

  # Ingress restricted to internal / load balancing only (via Firebase Hosting)
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.app_runner.email

    # Direct VPC Egress: Routes private traffic directly into the subnet (No connector fees!)
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "STORAGE_BUCKET"
        value = google_storage_bucket.app_data.name
      }
      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.postgres.private_ip_address
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app_db.name
      }
      env {
        name  = "DB_USER"
        value = google_sql_user.app_user.name
      }

      # Inject DB password directly from Secret Manager at runtime
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_secret.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}
