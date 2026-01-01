# Cilium

## UniFi BGP

```sh
router bgp 65001
  no bgp ebgp-requires-policy
  neighbor k8s peer-group
  neighbor k8s remote-as 65010
  neighbor 192.168.1.20 peer-group k8s
  neighbor 192.168.1.21 peer-group k8s
  neighbor 192.168.2.22 peer-group k8s
!
  address-family ipv4 unicast
    neighbor k8s activate
    neighbor k8s soft-reconfiguration inbound
    neighbor k8s prefix-list k8s-services in
  exit-address-family
!
ip prefix-list k8s-services seq 10 permit 192.168.1.0/24 le 32
```
