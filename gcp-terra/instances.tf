resource "google_compute_instance" "bastion" {
  name         = "bastion-instance"
  machine_type = "e2-micro"


  tags = ["bastion-service"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = 10

    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.analyzer.id
    network_ip = "10.10.0.11"
    access_config {
    }
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"]
    ]
  }
  metadata_startup_script = file("../provision/bastion.sh")

}

resource "google_compute_instance" "fetcher" {
  name         = "fetcher-instance"
  machine_type = var.machine_type

  depends_on = [
    google_secret_manager_secret_iam_member.datamonitor_access,
    google_compute_router_nat.analyzer
  ]


  tags = ["fetcher-service", "internal-service"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.machine_size
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.analyzer.id
    network_ip = "10.10.0.12"
  }

  service_account {
    email = google_service_account.datamonitor.email

    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
  metadata_startup_script = templatefile(
    "${path.module}/scripts/vm-startup.sh.tftpl",
    {
      install_docker_script  = file("${path.module}/scripts/install-docker.sh")
      startup_service_script = file("${path.module}/scripts/start-service.sh")
      service_role           = "fetcher"
      project_id             = var.project_id
    }
  )

}


resource "google_compute_instance" "postgres" {
  name         = "postgres-instance"
  machine_type = var.machine_type

  depends_on = [
    google_secret_manager_secret_iam_member.datamonitor_access,
    google_compute_router_nat.analyzer
  ]

  tags = ["postgres-service", "internal-service"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.machine_size
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.analyzer.id
    network_ip = "10.10.0.13"

  }

  service_account {
    email = google_service_account.datamonitor.email

    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  metadata_startup_script = templatefile(
    "${path.module}/scripts/vm-startup.sh.tftpl",
    {
      install_docker_script  = file("${path.module}/scripts/install-docker.sh")
      startup_service_script = file("${path.module}/scripts/start-service.sh")
      service_role           = "database"
      project_id             = var.project_id
    }
  )

}


resource "google_compute_instance" "history" {
  name         = "history-instance"
  machine_type = var.machine_type

  depends_on = [
    google_secret_manager_secret_iam_member.datamonitor_access,
    google_compute_router_nat.analyzer
  ]

  tags = ["history-service", "internal-service"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.machine_size
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.analyzer.id
    network_ip = "10.10.0.14"

  }

  service_account {
    email = google_service_account.datamonitor.email

    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
  metadata_startup_script = templatefile(
    "${path.module}/scripts/vm-startup.sh.tftpl",
    {
      install_docker_script  = file("${path.module}/scripts/install-docker.sh")
      startup_service_script = file("${path.module}/scripts/start-service.sh")

      service_role = "history"
      project_id   = var.project_id
    }
  )

}

resource "google_compute_instance" "ui" {
  name         = "ui-instance"
  machine_type = var.machine_type

  depends_on = [
    google_secret_manager_secret_iam_member.datamonitor_access,
    google_compute_router_nat.analyzer
  ]

  tags = ["ui-service"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.machine_size
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.analyzer.id
    network_ip = "10.10.0.15"
  }

  service_account {
    email = google_service_account.datamonitor.email

    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  metadata_startup_script = templatefile(
    "${path.module}/scripts/vm-startup.sh.tftpl",
    {
      install_docker_script  = file("${path.module}/scripts/install-docker.sh")
      startup_service_script = file("${path.module}/scripts/start-service.sh")
      service_role           = "ui"
      project_id             = var.project_id
    }
  )
}
