# Setup

The virtual machines use `libvirt` including `libvirt` networking. The networks
are all within the `172.16.0.0/12` private address block.

## Virtual Bridge

In order to facilitate a fixed IP address for the apache2 web server and the
squid caching instance we configure a virtual bridge using netplan:

    $ cat /etc/netplan/10-virtual-bridge.yaml 
    network:
      version: 2
      renderer: NetworkManager
      bridges:
        virtual-br:
          addresses:
            - 172.20.0.1/24
            - 172.20.0.2/24
            - 172.20.0.3/24

## BIND9

We define a `virtual` zone:

    $ cat /etc/bind/named.conf.options
    options {
            directory "/var/cache/bind";

            // If there is a firewall between you and nameservers you want
            // to talk to, you may need to fix the firewall to allow multiple
            // ports to talk.  See http://www.kb.cert.org/vuls/id/800113

            // If your ISP provided one or more IP addresses for stable 
            // nameservers, you probably want to use them as forwarders.  
            // Uncomment the following block, and insert the addresses replacing 
            // the all-0's placeholder.

            forwarders {
                    1.1.1.1;
                    1.0.0.1;
                    2606:4700:4700::1111;
                    2606:4700:4700::1001;
                    8.8.8.8;
                    8.8.4.4;
                    2001:4860:4860::8888;
                    2001:4860:4860::8844;
            };

            //========================================================================
            // If BIND logs error messages about the root key being expired,
            // you will need to update your keys.  See https://www.isc.org/bind-keys
            //========================================================================
            dnssec-validation auto;

            listen-on { 172.20.0.1; };
            //listen-on-v6 { any; };
    };

    $ cat /etc/bind/named.conf.default-zones 
    zone "virtual" {
            type master;
            file "/etc/bind/db.virtual";
    };

    zone "0.1.10.in-addr.arpa" {
            type master;
            file "/etc/bind/db.0.1.10";
    };

    $ cat /etc/bind/db.virtual 
    ;
    ; BIND data for containers
    ;
    $TTL    2400
    $ORIGIN virtual.
    @       IN      SOA     virtual. (
                                    zone-admin.virtual.     ; address of responsible party
                                    2022010404              ; serial number
                                    3600                    ; refresh period
                                    600                     ; retry period
                                    604800                  ; expire time
                                    1800 )                  ; minimum TTL
                    IN      NS      ns.virtual.
    ns              IN      A       172.20.0.1
    squid-deb-proxy IN      A       172.20.0.2
    images          IN      A       172.20.0.3

    $ cat /etc/bind/db.0.20.172 
    ;
    ; BIND data for reverse virtual zone
    ;
    $TTL    2400
    $ORIGIN 0.20.172.in-addr.arpa.
    @       IN      SOA     virtual. (
                                    zone-admin.virtual.     ; address of responsible party
                                    2022010404      ; serial
                                    21600           ; refresh period
                                    3600            ; retry period
                                    604800          ; expire time
                                    2400 )          ; minimum TTL

            IN      NS      ns.virtual.
    1       IN      PTR     ns.virtual.
    2       IN      PTR     squid-deb-proxy.virtual.
    3       IN      PTR     images.virtual.

## `systemd-resolved`

    $ cat /etc/systemd/resolved.conf
    [Resolve]
    DNS=172.20.0.1

## `apache2` server images

We use apache to serve server images:

    $ cat /etc/apache2/ports.conf 
    # Listen to inbound connections from the MAAS server
    Listen 172.20.0.3:8000

## `squid-deb-proxy`

We use `squid-deb-proxy` to cache packages:

    $ cat /etc/squid-deb-proxy/squid-deb-proxy.conf
    # This file contains domains that are not cached.
    acl nocache_domains dstdomain "/etc/squid-deb-proxy/nocache.acl.d/nocache-dstdomain.acl"
    acl nocache_cidrs dst "/etc/squid-deb-proxy/nocache.acl.d/nocache-dst.acl"
    # allow connects to ports for http, https
    acl Safe_ports port 80 443
    # allow connects to MAAS
    acl Safe_ports port 5240
    # allow connects to apache
    acl Safe_ports port 8000
    http_access allow nocache_domains nocache_cidrs

    $ cat /etc/squid-deb-proxy/nocache.acl.d/nocache-dstdomain.acl
    .virtual

    $ cat /etc/squid-deb-proxy/nocache.acl.d/nocache-dst.acl
    172.18.0.0/16

# This file contains domains that are not cached.
acl nocache_domains dstdomain "/etc/squid-deb-proxy/nocache.acl.d/nocache-dstdomain.acl"
acl nocache_cidrs dst "/etc/squid-deb-proxy/nocache.acl.d/nocache-dst.acl"

    $ cat /etc/squid-deb-proxy/mirror-dstdomain.acl.d/10-default 
    api.snapcraft.io
    .charmhub.io
    cloud-images.ubuntu.com
    dl.google.com
    esm.ubuntu.com
    images.maas.io
    ppa.launchpad.net
    prerelease.keybase.io
    .snapcraftcontent.com
    storage.googleapis.com
    streams.canonical.com

## Firewall (`iptables`) setup:

We need to add the following rules to forward traffic to the caches:

    $ iptables --append INPUT --protocol tcp --match state --state new --source 172.20.0.0/8 --destination 172.20.0.0/24 --jump LOG --log-prefix "MAAS: "
    $ iptables --append INPUT --protocol tcp --match state --state new --source 172.20.0.0/8 --destination 172.20.0.0/24 --jump ACCEPT

## `libvirt` networks

    `default`:
        `172.17.1.0/24`
        `df20::4:1/64`
    `maas-oam-net`:
        `172.18.0.0/24`
    `maas-admin-net`:
        `172.18.1.0/24`

The default network is configured as:

    <network>
      <name>default</name>
      <forward mode='nat'>
        <nat>
          <port start='1024' end='65535'/>
        </nat>
      </forward>
      <bridge name='virbr0' stp='on' delay='0'/>
      <dns>
        <forwarder addr='172.20.0.1'/>
      </dns>
      <ip address='172.17.1.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='172.17.1.2' end='172.17.1.250'/>
        </dhcp>
      </ip>
      <ip family='ipv6' address='fd20::4:1' prefix='64'>
      </ip>
    </network>
