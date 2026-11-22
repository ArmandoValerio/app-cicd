terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
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

variable "redis_chart_version" {
  description = "Versión del chart Helm de Bitnami Redis."
  type        = string
  default     = "20.1.7"
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "helm" {
  kubernetes {
    config_path = pathexpand(var.kubeconfig_path)
  }
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

resource "helm_release" "redis" {
  name       = "redis"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "redis"
  version    = var.redis_chart_version
  namespace  = kubernetes_namespace_v1.release.metadata[0].name

  atomic  = true
  wait    = true
  timeout = 300

  values = [
    yamlencode({
      architecture = "standalone"
      auth = {
        # Aislado por NetworkPolicy intra-namespace para evitar credenciales estáticas en IaC
        enabled = false
      }
      master = {
        persistence = {
          enabled = false
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "250m"
            memory = "256Mi"
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.release,
    kubernetes_network_policy_v1.release_isolation,
  ]
}

output "namespace" {
  description = "Namespace de Kubernetes provisionado para release."
  value       = kubernetes_namespace_v1.release.metadata[0].name
}

output "redis_service_host" {
  description = "FQDN interno del servicio Redis en modo standalone."
  value       = "redis-master.${kubernetes_namespace_v1.release.metadata[0].name}.svc.cluster.local"
}
