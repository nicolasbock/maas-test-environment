#!/bin/bash

set -u -e -x

: ${sync:=0}

while (( $# > 0 )); do
    case $1 in
        --sync)
            shift
            sync=$1
            ;;
        *)
            echo "unknown option $1"
            ;;
    esac
    shift
done

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

export DEBIAN_FRONTEND=noninteractive

# Delete default libvirt network
virsh net-destroy default 2>/dev/null || true
virsh net-undefine default 2>/dev/null || true

# Setup maas host as gateway
#
# https://maas.io/tutorials/create-kvm-pods-with-maas#5-routing-configuration

# iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# iptables -A FORWARD -i eth0 -o br1 -m state --state RELATED,ESTABLISHED -j ACCEPT
# iptables -A FORWARD -i br1 -o eth0 -j ACCEPT
# echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf
# sysctl -p

ext1_dev=$(ip route get 1.1.1.1 | awk '{print $5}')
cat <<- EOF | tee /etc/rc.local
#!/bin/sh -e
iptables -t nat -A POSTROUTING -o $ext1_dev -j MASQUERADE  # change to SNAT since static address used?
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

cat <<- EOF| tee /etc/sysctl.d/80-canonical.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p /etc/sysctl.d/80-canonical.conf

# Fix colors in shell
sed --in-place --expression 's,^#force,force,' ~ubuntu/.bashrc
sed --in-place --expression 's,^#force,force,' /root/.bashrc

cat <<EOF > ~ubuntu/.dircolors
DIR 38;5;75 # directory
EOF
cp ~ubuntu/.dircolors /root

mkdir -p ~ubuntu/juju

cat <<- 'EOF' > ~ubuntu/juju/bootstrap.sh
#!/bin/bash -eux
declare -a model_config=()
declare -a model_defaults=(
    'image-stream=released'
    'default-series=focal'
    'apt-http-proxy=http://10.0.0.2:8000'
)
for d in ${model_defaults[@]}; do
    model_config+=( "--config $d" )
done
juju bootstrap mymaas --no-gui --constraints "tags=juju" \
    --constraints "mem=2G" ${model_config[@]} os_controller --debug
juju model-defaults ${model_defaults[@]}
EOF
chmod -R +x ~ubuntu/juju

cat <<- EOF > ~ubuntu/.ssh/config
Host *
    User ubuntu
    IdentitiesOnly yes
    StrictHostKeyChecking no
    IdentityFile ~/.local/share/juju/ssh/juju_id_rsa

Host 192.168.0.200
    IdentityFile ~/.ssh/id_rsa

Host 10.*.*.*
    IdentityFile ~/testkey.priv

EOF
chown -R ubuntu: ~ubuntu/.ssh/config

snap install --channel JUJU_CHANNEL --classic juju
snap install openstackclients

declare maas_db_password
if [[ "MAAS_CHANNEL" == 2.7 || "POSTGRESQL" == yes || "POSTGRESQL" == true ]]; then
    apt-get install --yes --no-install-recommends postgresql
    maas_db_password=ubuntu
else
    snap install --channel MAAS_CHANNEL maas-test-db
fi

if [[ "MAAS_FROM_DEB" == yes ]]; then
    maas_db_password=$(sudo grep dbc_dbpass= /etc/dbconfig-common/maas-region-controller.conf | sed -e "s:^.*'\([^']*\)':\1:")
    apt-add-repository --yes ppa:maas/MAAS_CHANNEL
    apt-get install --yes --no-install-recommends maas
else
    snap install --channel MAAS_CHANNEL maas
fi

# Create admin creds and login
if [[ "MAAS_CHANNEL" == 2.7 || "POSTGRESQL" == yes ]]; then
    if [[ "MAAS_FROM_DEB" != yes ]]; then
        sudo -u postgres psql -c "create user \"maas\" with encrypted password 'ubuntu'"
        sudo -u postgres createdb --owner maas maasdb
        cat <<EOF | sudo -u postgres tee --append /etc/postgresql/*/main/pg_hba.conf
host    maasdb          maas            0/0                     md5
EOF
        maas init --mode region+rack \
            --maas-url http://localhost:5240/MAAS \
            --database-host localhost \
            --database-pass ${maas_db_password} \
            --database-user maas \
            --database-name maasdb
    fi
else
    maas init region+rack \
        --maas-url http://localhost:5240/MAAS \
        --database-uri maas-test-db:///
fi
maas createadmin \
    --username ubuntu \
    --password ubuntu \
    --email maastest@ubuntu.com \
    $([[ "LP_KEYNAME" != undefined ]] && echo "--ssh-import lp:LP_KEYNAME")

maas apikey --username ubuntu > /root/ubuntu-api-key
apikey=`maas apikey --username ubuntu`
while true; do
    maas login admin http://127.0.0.1:5240/MAAS $apikey && break
    sleep 1
done

cat << 'EOF' > ~ubuntu/juju/gencloud.sh
#!/bin/bash -eux
cat << __EOF__ > /tmp/mymaas_cloud.txt
clouds:
  mymaas:
    type: maas
    auth-types: [ oauth1 ]
    endpoint: http://10.0.0.2:5240/MAAS/

__EOF__
cat << __EOF__ > /tmp/mymaas_credentials.txt
credentials:
  mymaas:
    ubuntu:
      auth-type: oauth1
      maas-oauth: __API_KEY__

__EOF__
juju add-cloud mymaas /tmp/mymaas_cloud.txt || \
    juju update-cloud mymaas --client -f /tmp/mymaas_cloud.txt
juju add-credential mymaas -f /tmp/mymaas_credentials.txt || \
    juju update-credential mymaas --client -f /tmp/mymaas_credentials.txt

/home/ubuntu/juju/bootstrap.sh
EOF

sed --expression "s,__API_KEY__,${apikey}," --in-place ~ubuntu/juju/gencloud.sh
chmod +x ~ubuntu/juju/gencloud.sh

chown -R ubuntu: ~ubuntu/juju

while ! sudo --login --user ubuntu -- \
    git clone https://git.launchpad.net/stsstack-bundles; do
    rm -rf stsstack-bundles
    sleep 1
done

# Set upstream dns (ensuring dns-sec compat)
maas admin maas set-config name=upstream_dns value=1.1.1.1
maas admin maas set-config name=dnssec_validation value=no
maas admin maas set-config name=maas_name value=maaslab
maas admin maas set-config name=curtin_verbose value=true
maas admin maas set-config name=ntp_server value=ntp.ubuntu.com
maas admin maas set-config name=remote_syslog value=localhost

# Sync distros
maas admin boot-sources create \
    url=http://10.0.0.1:8000/maas/images/ephemeral-v3/stable \
    keyring_filename=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
maas admin boot-source delete 1

maas admin boot-source-selections create 2 os="ubuntu" release="xenial" \
    arches="amd64" subarches="*" labels="*" || :
maas admin boot-source-selections create 2 os="ubuntu" release="bionic" \
    arches="amd64" subarches="*" labels="*" || :
maas admin boot-source-selections create 2 os="ubuntu" release="focal" \
    arches="amd64" subarches="*" labels="*" || :

maas admin boot-sources read

if (( sync == 1 )); then
    while true; do
        if maas admin boot-resources read | jq -e '.[] | select(.name == "ubuntu/xenial" and .type == "Synced")'; then
            break
        fi
        sleep 10
    done

    while true; do
        if maas admin boot-resources read | jq -e '.[] | select(.name == "ubuntu/bionic" and .type == "Synced")'; then
            break
        fi
        sleep 10
    done

    while true; do
        if maas admin boot-resources read | jq -e '.[] | select(.name == "ubuntu/focal" and .type == "Synced")'; then
            break
        fi
        sleep 10
    done

    maas admin maas set-config name=commissioning_distro_series value=focal
    maas admin maas set-config name=default_distro_series value=focal
fi

# Setup networking
maas admin spaces create name=oam
maas admin spaces create name=admin
maas admin spaces create name=internal
maas admin spaces create name=public
maas admin spaces create name=external
maas admin spaces create name=k8s

# Default all to oam (then change below)
read -a fabrics<<<`maas admin fabrics read | jq .[].id`
for fabric in ${fabrics[@]}; do
    maas admin vlan update $fabric 0 space=oam
done

ab=10.0
gw=${ab}.0.2
dns=${ab}.0.2  # <- MUST BE SET TO MAAS HOST IP
cidr=${ab}.0.0/24
subnet_id=`maas admin subnets read | jq -r ".[] | select(.cidr==\"${cidr}\").id"`
maas admin subnet update $subnet_id gateway_ip=$gw
maas admin subnet update $subnet_id dns_servers=$dns

maas admin ipranges create type=reserved subnet="$subnet_id" \
    comment="Infra (maas node etc)" \
    start_ip=${ab}.0.1 end_ip=${ab}.0.2 \
    gateway_ip=$gw dns_servers=$dns

maas admin ipranges create type=dynamic subnet="$subnet_id" \
    comment="Enlisting, commissioning etc" \
    start_ip=${ab}.0.3 end_ip=${ab}.0.100

primary=`maas admin rack-controllers read | jq .[].system_id | tr -d '"'`
fabric=$(maas admin subnets read | jq ".[] | select(.cidr == \"${cidr}\") | .vlan.fabric" | tr -d '"')
maas admin vlan update ${fabric} 0 dhcp_on=true \
    primary_rack=$primary

declare -A cidrs=(
    [admin]=24
    [public]=24
    [internal]=24
    [external]=24
    [k8s]=24
)

declare -A dhcp=(
    [admin]=true
    [public]=true
    [internal]=true
    [external]=false
    [k8s]=true
)

declare -A spaces=(
    [admin]=1
    [public]=2
    [internal]=3
    [external]=4
    [k8s]=5
)

for space in ${!spaces[@]}; do
    abc=10.0.${spaces[$space]}
    gw=${abc}.2
    dns=10.0.0.2  # <- MUST BE SET TO MAAS HOST IP
    cidr=${abc}.0/${cidrs[$space]}
    subnet_id=`maas admin subnets read | jq -r ".[] | select(.cidr==\"${cidr}\").id"`
    fabric_id=`maas admin subnet read $subnet_id | jq .vlan.fabric_id`
    maas admin subnet update $subnet_id gateway_ip=$gw
    maas admin subnet update $subnet_id dns_servers=$dns

    if [[ space == external ]]; then
        maas admin ipranges create type=reserved subnet="$subnet_id" \
            comment="Floating IPs" \
            start_ip=${abc}.200 end_ip=${abc}.254
    fi

    primary=`maas admin rack-controllers read | jq .[].system_id | tr -d '"'`
    maas admin vlan update $fabric_id 0 space=$space \
        primary_rack=$primary
done

maas admin domain update 0 name=mylab.home

# skip intro
maas admin maas set-config name=completed_intro value=true

declare ssh_root_dir
if [[ "MAAS_FROM_DEB" != yes ]]; then
    ssh_root_dir=/var/snap/maas/current/root/.ssh
else
    ssh_root_dir=/var/lib/maas/.ssh
fi
mkdir -m 0700 -p ${ssh_root_dir}
cp --verbose /root/.ssh/id_rsa{,.pub} ${ssh_root_dir}

if [[ "MAAS_FROM_DEB" == yes ]]; then
    chown --recursive maas: ${ssh_root_dir}
fi

# Add KVM host
# VIRSH_IP=$(ip route show default | awk '{print $3}')
# maas admin vm-hosts create \
    #   type=virsh \
    #   power_address=qemu+ssh://VIRSH_USER@${VIRSH_IP}/system

echo "Done."
