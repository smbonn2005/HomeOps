# Cilium

## UniFi BGP

```sh
router bgp 65001
  bgp router-id 192.168.1.1
  no bgp ebgp-requires-policy

  neighbor k8s peer-group
  neighbor k8s remote-as 65010
  neighbor k8s activate
  neighbor k8s soft-reconfiguration inbound

  neighbor 192.168.1.20 peer-group k8s
  neighbor 192.168.1.21 peer-group k8s
  neighbor 192.168.1.22 peer-group k8s

  address-family ipv4 unicast
    neighbor k8s next-hop-self
```
