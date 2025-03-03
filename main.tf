# 1. Создание KMS-ключа для бакета
resource "yandex_kms_symmetric_key" "bucket_key" {
  name              = "bucket-encryption-key"
  description       = "KMS key for encrypting bucket content"
  default_algorithm = "AES_256"
  rotation_period   = "8760h" # 365 дней
}

# 2. Создание статического ключа доступа
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = var.service_account_id
  description        = "static access key for object storage"
}

# 3. Сеть и подсети
resource "yandex_vpc_network" "network" {
  name = "network"
}

resource "yandex_vpc_subnet" "public_subnets" {
  count = 3

  name           = "public-subnet-${count.index}"
  zone           = "ru-central1-${element(["a", "b", "d"], count.index)}"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [cidrsubnet("10.1.0.0/16", 8, count.index)]
}

resource "yandex_vpc_subnet" "private_subnets" {
  count = 3

  name           = "private-subnet-${count.index}"
  zone           = "ru-central1-${element(["a", "b", "d"], count.index)}"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [cidrsubnet("10.2.0.0/16", 8, count.index)]
}

# 4. Группа безопасности для MySQL
resource "yandex_vpc_security_group" "mysql_sg" {
  name        = "mysql-security-group"
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "MySQL"
    port           = 3306
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. Кластер MySQL
resource "yandex_mdb_mysql_cluster" "mysql_cluster" {
  name                = "netology-mysql-cluster"
  environment         = "PRESTABLE"
  network_id          = yandex_vpc_network.network.id
  version             = "8.0"
  deletion_protection = true

  resources {
    resource_preset_id = "s2.micro"
    disk_type_id       = "network-ssd"
    disk_size          = 20
  }

  maintenance_window {
    type = "WEEKLY"
    day  = "SAT"
    hour = 23
  }

  backup_window_start {
    hours   = 23
    minutes = 59
  }

  dynamic "host" {
    for_each = yandex_vpc_subnet.private_subnets
    content {
      zone      = host.value.zone
      subnet_id = host.value.id
    }
  }

  security_group_ids = [yandex_vpc_security_group.mysql_sg.id]
}

# 6. База данных и пользователь MySQL
resource "yandex_mdb_mysql_database" "netology_db" {
  cluster_id = yandex_mdb_mysql_cluster.mysql_cluster.id
  name       = "netology_db"
}

resource "yandex_mdb_mysql_user" "netology_user" {
  cluster_id = yandex_mdb_mysql_cluster.mysql_cluster.id
  name       = var.db_username
  password   = var.db_password

  permission {
    database_name = yandex_mdb_mysql_database.netology_db.name
    roles         = ["ALL"]
  }
}

# 7. Сервисный аккаунт для Kubernetes
resource "yandex_iam_service_account" "k8s_sa" {
  name        = "k8s-service-account"
  description = "Service account for Kubernetes cluster"
}

resource "yandex_resourcemanager_folder_iam_binding" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  members   = ["serviceAccount:${yandex_iam_service_account.k8s_sa.id}"]
}

resource "yandex_resourcemanager_folder_iam_binding" "k8s_agent" {
  folder_id = var.folder_id
  role      = "k8s.clusters.agent"
  members   = ["serviceAccount:${yandex_iam_service_account.k8s_sa.id}"]
}

resource "yandex_resourcemanager_folder_iam_binding" "vpc_admin" {
  folder_id = var.folder_id
  role      = "vpc.publicAdmin"
  members   = ["serviceAccount:${yandex_iam_service_account.k8s_sa.id}"]
}

resource "yandex_resourcemanager_folder_iam_binding" "kms_access" {
  folder_id = var.folder_id
  role      = "kms.keys.encrypterDecrypter"
  members   = ["serviceAccount:${yandex_iam_service_account.k8s_sa.id}"]
}

# 8. Кластер Kubernetes
resource "yandex_kubernetes_cluster" "regional_cluster" {
  name        = "regional-k8s-cluster"
  description = "Regional Kubernetes cluster"
  network_id  = yandex_vpc_network.network.id

  master {
    regional {
      region = "ru-central1"
      dynamic "location" {
        for_each = yandex_vpc_subnet.public_subnets
        content {
          zone      = location.value.zone
          subnet_id = location.value.id
        }
      }
    }
    version   = "1.31"
    public_ip = true

    maintenance_policy {
      auto_upgrade = true
      maintenance_window {
        start_time = "03:00"
        duration   = "3h"
      }
    }
  }

  service_account_id      = yandex_iam_service_account.k8s_sa.id
  node_service_account_id = yandex_iam_service_account.k8s_sa.id
  kms_provider {
    key_id = yandex_kms_symmetric_key.bucket_key.id
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_binding.editor,
    yandex_resourcemanager_folder_iam_binding.k8s_agent,
    yandex_resourcemanager_folder_iam_binding.vpc_admin,
    yandex_resourcemanager_folder_iam_binding.kms_access
  ]
}

# 9. Группы узлов Kubernetes
resource "yandex_kubernetes_node_group" "node_groups" {
  for_each = {
    a = 0
    b = 1
    d = 2 
  }

  cluster_id = yandex_kubernetes_cluster.regional_cluster.id
  name       = "autoscaling-node-group-${each.key}"

  instance_template {
    platform_id = "standard-v2"
    resources {
      cores  = 2
      memory = 4
    }

    boot_disk {
      type = "network-ssd"
      size = 64
    }

    network_interface {
      subnet_ids = [yandex_vpc_subnet.public_subnets[each.value].id]
      nat        = true
    }
  }

  scale_policy {
    auto_scale {
      min     = 1
      max     = 2
      initial = 1
    }
  }

  allocation_policy {
    location {
      zone = yandex_vpc_subnet.public_subnets[each.value].zone
    }
  }

  depends_on = [yandex_kubernetes_cluster.regional_cluster]
}

# 10. Настройка kubectl
provider "local" {}

resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  content         = templatefile("${path.module}/kubeconfig.tpl", {
    endpoint       = yandex_kubernetes_cluster.regional_cluster.master[0].external_v4_endpoint
    cluster_ca     = base64encode(yandex_kubernetes_cluster.regional_cluster.master[0].cluster_ca_certificate)
    k8s_cluster_id = yandex_kubernetes_cluster.regional_cluster.id
  })
  file_permission = "0644"  # Права на чтение для всех, запись для владельца
}

provider "kubernetes" {
  config_path = "${path.module}/kubeconfig.yaml"
  
}

resource "time_sleep" "wait_for_cluster" {
  create_duration = "300s" # Увеличено время ожидания
  depends_on      = [yandex_kubernetes_cluster.regional_cluster]
}

# 11. Приложение phpMyAdmin
resource "kubernetes_deployment" "phpmyadmin" {
  depends_on = [
    time_sleep.wait_for_cluster,
    yandex_mdb_mysql_cluster.mysql_cluster
  ]

  metadata {
    name = "phpmyadmin"
    labels = {
      app = "phpmyadmin"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "phpmyadmin"
      }
    }

    template {
      metadata {
        labels = {
          app = "phpmyadmin"
        }
      }

      spec {
        container {
          name  = "phpmyadmin"
          image = "phpmyadmin/phpmyadmin:latest"
          port {
            container_port = 80
          }
          env {
            name  = "PMA_HOST"
            value = yandex_mdb_mysql_cluster.mysql_cluster.host.0.fqdn
          }
          env {
            name  = "PMA_PORT"
            value = "3306"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "phpmyadmin" {
  metadata {
    name = "phpmyadmin-service"
  }

  spec {
    selector = {
      app = kubernetes_deployment.phpmyadmin.metadata[0].labels.app
    }
    port {
      port        = 80
      target_port = 80
    }
    type = "LoadBalancer"
  }

  depends_on = [kubernetes_deployment.phpmyadmin]
}