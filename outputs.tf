# output "Network_Load_Balancer_Address" {
#   value = yandex_lb_network_load_balancer.nlb.listener.*.external_address_spec[0].*.address
#   description = "Адрес сетевого балансировщика"
# } 


# output "Application_Load_Balancer_Address" {
#   value = yandex_alb_load_balancer.application-balancer.listener.*.endpoint[0].*.address[0].*.external_ipv4_address
#   description = "Адрес L7-балансировщика"
# }

output "phpmyadmin_ip" {
  value = kubernetes_service.phpmyadmin.status.0.load_balancer.0.ingress.0.ip
}

output "kubeconfig" {
  value     = "Kubeconfig file generated: ${local_file.kubeconfig.filename}"
  sensitive = true
}