output "phpmyadmin_ip" {
  value = kubernetes_service.phpmyadmin.status.0.load_balancer.0.ingress.0.ip
}
