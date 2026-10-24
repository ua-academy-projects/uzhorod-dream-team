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
  metadata_startup_script = file("../provision/bastion.sh")

}

resource "google_compute_instance" "fetcher" {
  name         = "fetcher-instance"
  machine_type = var.machine_type


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
  metadata_startup_script = file("./scripts/install-docker.sh")

}


resource "google_compute_instance" "postgres" {
  name         = "postgres-instance"
  machine_type = var.machine_type

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
  metadata_startup_script = file("./scripts/install-docker.sh")

}


resource "google_compute_instance" "history" {
  name         = "history-instance"
  machine_type = var.machine_type

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
  metadata_startup_script = file("./scripts/install-docker.sh")

}

resource "google_compute_instance" "ui" {
  name         = "ui-instance"
  machine_type = var.machine_type

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
    access_config {
    }
  }

  metadata_startup_script = file("./scripts/install-docker.sh")
}