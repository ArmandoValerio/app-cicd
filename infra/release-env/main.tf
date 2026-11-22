terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

variable "kubeconfig_path" {
  description = "Ruta al archivo kubeconfig para conectarse al clúster Kubernetes (app-cluster)."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Namespace de aislamiento para el entorno de liberación."
  type        = string
  default     = "release"
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

resource "kubernetes_namespace_v1" "release" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of"    = "app"
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "release"
      "name"                         = var.namespace
    }
  }
}

resource "kubernetes_network_policy_v1" "release_isolation" {
  metadata {
    name      = "app-release-isolation"
    namespace = kubernetes_namespace_v1.release.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of" = "app"
      "environment"               = "release"
    }
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress", "Egress"]

    # Tráfico interno entre microservicios del entorno release (API <-> Redis)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }
    }

    # Tráfico entrante desde ingress-nginx hacia la API en puerto 8000
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress-nginx"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "8000"
      }
    }

    # Scraping de métricas desde Prometheus en namespace monitoring
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "8000"
      }
    }

    # Comunicación saliente intra-namespace (p. ej. API hacia Redis 6379)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }

    # Resolución DNS contra CoreDNS en kube-system
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    # Salida hacia PostgreSQL gestionado y servicios HTTPS externos, bloqueando tráfico lateral interno
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
          ]
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }

      ports {
        protocol = "TCP"
        port     = "5432"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "redis" {
  wait_for_rollout = true

  metadata {
    name      = "redis-master"
    namespace = kubernetes_namespace_v1.release.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "redis"
      "app.kubernetes.io/instance"   = "redis-master"
      "app.kubernetes.io/part-of"    = "app"
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "release"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "redis"
        "app.kubernetes.io/instance" = "redis-master"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "redis"
          "app.kubernetes.io/instance" = "redis-master"
          "environment"                = "release"
        }
      }

      spec {
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          fs_group        = 999

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "redis"
          image = "redis:7-alpine"
          args  = ["--save", "", "--appendonly", "no"]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 999

            capabilities {
              drop = ["ALL"]
            }
          }

          port {
            name           = "redis"
            container_port = 6379
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }
        }

        volume {
          name = "redis-data"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.release,
    kubernetes_network_policy_v1.release_isolation,
  ]
}

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = "redis-master"
    namespace = kubernetes_namespace_v1.release.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "redis"
      "app.kubernetes.io/instance"   = "redis-master"
      "app.kubernetes.io/part-of"    = "app"
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "release"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name"     = "redis"
      "app.kubernetes.io/instance" = "redis-master"
    }

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment_v1.redis]
}

output "namespace" {
  description = "Namespace de Kubernetes provisionado para release."
  value       = kubernetes_namespace_v1.release.metadata[0].name
}

output "redis_service_host" {
  description = "FQDN interno del servicio Redis en modo standalone."
  value       = "redis-master.${kubernetes_namespace_v1.release.metadata[0].name}.svc.cluster.local"
}
