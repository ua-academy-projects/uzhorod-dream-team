locals {
  instances = {
    for key, vm in var.config.instances : key => merge(vm, {
      machine_type           = coalesce(vm.machine_type, var.config.defaults.machine_type)
      public_ip              = coalesce(vm.public_ip, var.config.defaults.public_ip)
      attach_service_account = coalesce(vm.attach_service_account, var.config.defaults.attach_service_account)
      boot_disk = {
        image   = coalesce(vm.boot_disk.image, var.config.defaults.boot_disk.image)
        size_gb = coalesce(vm.boot_disk.size_gb, var.config.defaults.boot_disk.size_gb)
        type    = coalesce(vm.boot_disk.type, var.config.defaults.boot_disk.type)
      }
    })
  }
}

resource "google_compute_address" "static_public_ips" {
  for_each = { for key, vm in local.instances : key => vm if vm.static_public_ip }

  name         = "${each.value.name}-ip"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_instance" "instances" {
  for_each = local.instances

  name         = each.value.name
  project      = var.project_id
  zone         = var.zone
  machine_type = each.value.machine_type
  tags         = each.value.tags

  boot_disk {
    initialize_params {
      image = each.value.boot_disk.image
      size  = each.value.boot_disk.size_gb
      type  = each.value.boot_disk.type
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    network_ip = each.value.network_ip

    dynamic "access_config" {
      for_each = each.value.public_ip ? [true] : []
      content {
        nat_ip       = each.value.static_public_ip ? google_compute_address.static_public_ips[each.key].address : null
        network_tier = "PREMIUM"
      }
    }
  }

  dynamic "service_account" {
    for_each = each.value.attach_service_account ? [var.service_account_email] : []
    content {
      email  = service_account.value
      scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  metadata_startup_script = each.value.startup.type == "none" ? null : (
    each.value.startup.type == "bastion" ? templatefile("${path.module}/scripts/bastion.sh.tftpl", { ssh_port = each.value.startup.ssh_port }) : templatefile(
      "${path.module}/scripts/vm-startup.sh.tftpl",
      {
        install_docker_script  = file("${path.module}/scripts/install-docker.sh")
        startup_service_script = file("${path.module}/scripts/start-service.sh")
        service_role           = each.value.startup.service_role
        project_id             = var.project_id
        tunnel_token_secret_id = each.value.startup.tunnel_token_secret_id
        compose_config         = file("${path.module}/../../../DataFetcher/docker-compose.yml")
        ip_https               = each.value.startup.ip_https
        setup_https_script     = file("${path.module}/scripts/setup-ui-https.sh")
        nginx_http_template    = file("${path.module}/../../../DataFetcher/nginx/ip-http.conf.template")
        nginx_https_template   = file("${path.module}/../../../DataFetcher/nginx/ip-https.conf.template")
        nginx_config           = file("${path.module}/../../../DataFetcher/nginx/default.conf")
      }
    )
  )

  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }
}
