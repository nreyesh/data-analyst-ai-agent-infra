# ==============================================================================
# 1. Artifact Registry (Docker images for backend & frontend)
# ==============================================================================
resource "google_artifact_registry_repository" "docker_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "building-analytics-repo-${var.environment}"
  description   = "Docker repository for Building Analytics services (${var.environment})"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-latest-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-older-than-10d"
    action = "DELETE"
    condition {
      older_than = "864000s" # 10 days
    }
  }
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
# 3. Secret Manager: Passwords & Cryptographic Signing Keys
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

# Chainlit Session Auth Secret (Cryptographic signing key for frontend user sessions)
resource "random_password" "chainlit_secret" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "chainlit_secret" {
  secret_id = "building-analytics-chainlit-secret-${var.environment}"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "chainlit_secret_val" {
  secret      = google_secret_manager_secret.chainlit_secret.id
  secret_data = random_password.chainlit_secret.result
}

# Gemini API Key Secret
resource "google_secret_manager_secret" "gemini_api_key_secret" {
  secret_id = "building-analytics-gemini-api-key-${var.environment}"
  project   = var.project_id

  replication {
    auto {}
  }
}

# Initial secret version to guarantee 'latest' exists when Cloud Run validates the job
resource "google_secret_manager_secret_version" "gemini_api_key_val" {
  secret      = google_secret_manager_secret.gemini_api_key_secret.id
  secret_data = "initial-placeholder-key"

  lifecycle {
    ignore_changes = [
      secret_data,
    ]
  }
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
      ssl_mode                                      = "ENCRYPTED_ONLY" # Enforce strict TLS in-transit encryption
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

# Grant Cloud Run permission to read secrets (DB password and Chainlit auth secret)
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  secret_id = google_secret_manager_secret.db_password_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_runner.email}"
  project   = var.project_id
}

resource "google_secret_manager_secret_iam_member" "chainlit_secret_accessor" {
  secret_id = google_secret_manager_secret.chainlit_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_runner.email}"
  project   = var.project_id
}

resource "google_secret_manager_secret_iam_member" "gemini_secret_accessor" {
  secret_id = google_secret_manager_secret.gemini_api_key_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_runner.email}"
  project   = var.project_id
}


# ==============================================================================
# 7. Cloud Run Service 1: Private Backend (Direct VPC Egress to Cloud SQL)
# ==============================================================================
resource "google_cloud_run_v2_service" "backend" {
  name     = "building-analytics-backend-${var.environment}"
  location = var.region
  project  = var.project_id

  # Ingress restricted to internal / load balancing only (via Frontend or internal jobs)
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  depends_on = [
    google_secret_manager_secret_version.gemini_api_key_val,
    google_secret_manager_secret_iam_member.gemini_secret_accessor,
  ]

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }


  template {
    service_account = google_service_account.app_runner.email

    # Direct VPC Egress: Routes private traffic directly into the subnet
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

      # Inject Gemini API key directly from Secret Manager at runtime
      env {
        name = "GEMINI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.gemini_api_key_secret.secret_id
            version = "latest"
          }
        }
      }

    }
  }
}

# ==============================================================================
# 7.1 Cloud Run Job: Database Migration Runner (Alembic inside VPC)
# ==============================================================================
resource "google_cloud_run_v2_job" "db_migrate" {
  name     = "building-analytics-migrate-${var.environment}"
  location = var.region
  project  = var.project_id

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  template {
    template {
      service_account = google_service_account.app_runner.email

      vpc_access {
        network_interfaces {
          network    = google_compute_network.vpc.id
          subnetwork = google_compute_subnetwork.subnet.id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = "us-docker.pkg.dev/cloudrun/container/hello"
        command = ["alembic", "upgrade", "head"]

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
}

# ==============================================================================
# 7.2 Cloud Run Job: Automated Monthly & Historical Extraction Pipeline
# ==============================================================================
resource "google_cloud_run_v2_job" "sync_monthly" {
  name     = "building-analytics-sync-${var.environment}"
  location = var.region
  project  = var.project_id

  depends_on = [
    google_secret_manager_secret_version.gemini_api_key_val,
    google_secret_manager_secret_iam_member.gemini_secret_accessor,
  ]

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  template {

    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.app_runner.email
      timeout         = "3600s" # 60 minutes max runtime for full condominium cycle

      vpc_access {
        network_interfaces {
          network    = google_compute_network.vpc.id
          subnetwork = google_compute_subnetwork.subnet.id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = "us-docker.pkg.dev/cloudrun/container/hello"
        command = ["python", "-m", "backend.app.extractor.cli"]
        args    = ["--target", "all", "--current-month"]

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
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
        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db_password_secret.secret_id
              version = "latest"
            }
          }
        }
        env {
          name = "GEMINI_API_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.gemini_api_key_secret.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }
}

# Cloud Scheduler Trigger: Runs monthly sync at 02:00 AM on the 6th day of every month
resource "google_cloud_scheduler_job" "monthly_sync_trigger" {
  name             = "building-analytics-monthly-sync-${var.environment}"
  description      = "Trigger automated monthly extraction of building and unit expenses from Kastor"
  schedule         = "0 2 18 * *"
  time_zone        = "America/Santiago"
  project          = var.project_id
  region           = var.region
  attempt_deadline = "320s"

  depends_on = [
    google_cloud_run_v2_job.sync_monthly,
  ]


  http_target {

    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.sync_monthly.name}:run"

    oauth_token {
      service_account_email = google_service_account.app_runner.email
    }
  }
}

# Allow App Runner SA to invoke Cloud Run jobs (needed by Cloud Scheduler)
resource "google_project_iam_member" "scheduler_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.app_runner.email}"
}


# ==============================================================================
# 8. Cloud Run Service 2: Public Frontend (Chat UI / Chainlit)
# ==============================================================================
resource "google_cloud_run_v2_service" "frontend" {
  name     = "building-analytics-front-${var.environment}"
  location = var.region
  project  = var.project_id

  # Public Ingress so users can access the chat UI in their browser
  ingress = "INGRESS_TRAFFIC_ALL"

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  template {
    service_account = google_service_account.app_runner.email

    # Direct VPC Egress: Routes traffic through VPC with Private Google Access for internal backend
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      # Placeholder image until the frontend CI/CD pipeline deploys the real Chainlit container
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
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend.uri
      }

      # Inject Chainlit Auth Secret directly from Secret Manager at runtime
      env {
        name = "CHAINLIT_AUTH_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.chainlit_secret.secret_id
            version = "latest"
          }
        }
      }

      # Inject Firebase Web API Key for frontend user credential verification
      env {
        name = "FIREBASE_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.firebase_api_key.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

# Allow public unauthenticated web access to the frontend chat UI
resource "google_cloud_run_v2_service_iam_member" "frontend_public_access" {
  project  = var.project_id
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Allow internal invocations on the private backend (traffic is strictly isolated to VPC via ingress)
resource "google_cloud_run_v2_service_iam_member" "backend_internal_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.backend.location
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
