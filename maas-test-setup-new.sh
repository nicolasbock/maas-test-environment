#!/bin/bash

set -e -u -x

get_host() {
    local cidr=$1
    local host=$2
    python3 -c "import ipaddress; print(list(ipaddress.ip_network('${cidr}').hosts())[${host}])"
}

get_gateway() {
    local cidr=$1
    get_host ${cidr} 0
}

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

PROXY_ADDRESS=TEMPLATE_HTTP_PROXY
if [[ -n "$PROXY_ADDRESS" ]]; then
    PROXY=http://${PROXY_ADDRESS}:8080
else
    PROXY=
fi
DNS=172.20.0.1

if [[ -n "$PROXY" ]]; then
    snap set system proxy.http=${PROXY}
    snap set system proxy.https=${PROXY}
fi

# Fix colors in shell
sed --in-place --expression 's,^#force,force,' ~ubuntu/.bashrc
sed --in-place --expression 's,^#force,force,' /root/.bashrc

cat <<EOF >> ~ubuntu/.dircolors
DIR 38;5;75 # directory
EOF
cp ~ubuntu/.dircolors /root

if [[ -n "$PROXY_ADDRESS" ]]; then
    while ! ping -c 1 ${PROXY_ADDRESS}; do
        sleep 1
    done
fi

snap install --channel TEMPLATE_JUJU_CHANNEL --classic juju
snap install openstackclients

# Remove virsh networks to prevent MAAS from failing to start during DHCP probe.
virsh net-destroy default || echo "ignoring"
virsh net-autostart --disable default || echo "ignoring"

apt-add-repository --yes ppa:maas/TEMPLATE_MAAS_CHANNEL
apt-get update

if [[ TEMPLATE_MAAS_FROM_DEB == yes ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends maas
    maas_db_password=$(sudo grep dbc_dbpass= /etc/dbconfig-common/maas-region-controller.conf | sed -e "s:^.*'\([^']*\)':\1:")
else
    echo "I do not know how to install MAAS"
    exit 1
fi

if [[ -z ${maas_db_password} ]]; then
    echo "Could not get MAAS password"
fi

if ! maas admin account list-authorisation-tokens; then
    maas createadmin \
        --username ubuntu \
        --password ubuntu \
        --email maastest@virtual \
        $([[ "TEMPLATE_LP_KEYNAME" != undefined ]] && echo "--ssh-import lp:TEMPLATE_LP_KEYNAME")
fi

maas apikey --username ubuntu > /root/ubuntu-api-key
apikey=$(maas apikey --username ubuntu)

mkdir -p ~ubuntu/juju

cat <<- EOF > ~ubuntu/juju/bootstrap.sh
#!/bin/bash -eux

declare -a model_config=()

if [[ -n "$PROXY" ]]; then
    declare -a model_defaults=(
        image-stream=released
        default-series=TEMPLATE_DEFAULT_SERIES
        no-proxy=127.0.0.1,localhost,::1,172.18.0.0/16
        apt-http-proxy=${PROXY}
        apt-https-proxy=${PROXY}
        snap-http-proxy=${PROXY}
        snap-https-proxy=${PROXY}
        juju-http-proxy=${PROXY}
        juju-https-proxy=${PROXY}
    )
else
    declare -a model_defaults=(
        image-stream=released
        default-series=TEMPLATE_DEFAULT_SERIES
        no-proxy=127.0.0.1,localhost,::1,172.18.0.0/16
    )
fi

for d in \${model_defaults[@]}; do
    model_config+=( "--config \$d" )
done

juju bootstrap mymaas --no-gui --constraints "tags=juju" \
    --constraints "mem=2G" \${model_config[@]} os-controller \
    --debug
juju model-defaults \${model_defaults[@]}
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

Host 172.18.*.*
    IdentityFile ~/testkey.priv
EOF
chown -R ubuntu: ~ubuntu/.ssh/config

cat << 'EOF' > ~ubuntu/juju/gencloud.sh
#!/bin/bash -eux

cat << __EOF__ > /tmp/mymaas_cloud.txt
clouds:
  mymaas:
    type: maas
    auth-types: [ oauth1 ]
    endpoint: http://172.18.0.2:5240/MAAS/

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
chmod +x ~ubuntu/juju/gencloud.sh

sed --expression "s,__API_KEY__,${apikey}," --in-place ~ubuntu/juju/gencloud.sh

chown -R ubuntu: ~ubuntu/juju

while true; do
    maas login admin http://127.0.0.1:5240/MAAS $apikey && break
    sleep 1
done

maas admin maas set-config name=maas_name value=maaslab
maas admin maas set-config name=upstream_dns value=${DNS}
maas admin maas set-config name=dnssec_validation value=yes
if [[ -n "$PROXY" ]]; then
    maas admin maas set-config name=http_proxy value=${PROXY}
fi
maas admin maas set-config name=ntp_server value=ntp.ubuntu.com
maas admin maas set-config name=curtin_verbose value=true
maas admin maas set-config name=remote_syslog value=localhost
maas admin maas set-config name=completed_intro value=true
maas admin domain update 0 name=testmaas.virtual

maas admin boot-sources create \
    url=http://images.virtual:8000/maas/images/ephemeral-v3/stable \
    keyring_filename=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
maas admin boot-source delete 1

for series in focal bionic; do
    maas admin boot-source-selections create 2 os="ubuntu" release="${series}" \
        arches="amd64" subarches="*" labels="*" || :
done

while ! maas admin maas set-config name=commissioning_distro_series value=TEMPLATE_DEFAULT_SERIES; do
    sleep 10
done
while ! maas admin maas set-config name=default_distro_series value=TEMPLATE_DEFAULT_SERIES; do
    sleep 10
done

declare -a fabric_names=( TEMPLATE_FABRIC_NAMES )
declare -a fabric_cidrs=( TEMPLATE_FABRIC_CIDRS )
declare -A fabrics=()
declare oam_network_name

if (( ${#fabric_names[@]} != ${#fabric_cidrs[@]} )); then
    echo "Fabric names and CIDRs do not match"
    exit 1
fi

for i in $(seq 0 $(( ${#fabric_names[@]} - 1 ))); do
    fabrics[${fabric_names[${i}]}]=${fabric_cidrs[${i}]}
    fabric_name=${fabric_names[${i}]}
    fabric_cidr=${fabric_cidrs[${i}]}
    if [[ ${fabric_name} =~ oam ]]; then
        oam_network_name=${fabric_name}
    fi
    space_id=$(maas admin spaces create name="${fabric_name}" | jq '.id')
    fabric_id=''
    while [[ -z "$fabric_id" ]]; do
        fabric_id=$(maas admin spaces read | jq --arg cidr ${fabric_cidr} '.[].subnets[] | select(.cidr == $cidr) | .vlan.fabric_id')
    done
    maas admin fabric update "${fabric_id}" name="${fabric_name}"
    maas admin vlan update "${fabric_id}" 0 space="${fabric_name}"
done

default_gateway=$(get_host ${fabrics[${oam_network_name}]} 1)

ab=172.18
gw=${ab}.0.1
cidr=${ab}.0.0/24
subnet_id=$(maas admin subnets read | jq -r ".[] | select(.cidr==\"${cidr}\").id")

readarray -t subnet_ids < <(maas admin subnets read | jq -r '.[] | "\(.id) \(.cidr) \(.space)"')

for line in "${subnet_ids[@]}"; do
    read -a subnet -r <<<"${line}"
    subnet_id=${subnet[0]}
    subnet_cidr=${subnet[1]}
    subnet_space=${subnet[2]}

    subnet_gateway=$(get_gateway ${subnet_cidr})

    maas admin subnet update "${subnet_id}" gateway_ip=${subnet_gateway}
    maas admin subnet update "${subnet_id}" dns_servers=${DNS}

    maas admin ipranges create \
        type=reserved \
        subnet="${subnet_id}" \
        comment="Infra (gateway, MAAS node, etc)" \
        start_ip=$(get_host ${subnet_cidr} 1) \
        end_ip=$(get_host ${subnet_cidr} 10) \
        gateway_ip=${default_gateway} \
        dns_servers=${DNS}

    maas admin ipranges create \
        type=dynamic \
        subnet="${subnet_id}" \
        comment="Enlisting, commissioning, etc" \
        start_ip=$(get_host ${subnet_cidr} 11) \
        end_ip=$(get_host ${subnet_cidr} 200)
done

primary=$(maas admin rack-controllers read | jq -r .[].system_id)
fabric=$(maas admin subnets read | jq ".[] | select(.cidr == \"${fabrics[${oam_network_name}]}\") \
    | .vlan.fabric" | tr -d '"')
maas admin vlan update "${fabric}" 0 dhcp_on=true \
    primary_rack="${primary}"

# Copy ssh keys to MAAS controller so that it can talk to the libvirt daemon on
# the hypervisor.
declare ssh_root_dir
if [[ "TEMPLATE_MAAS_FROM_DEB" == yes ]]; then
    ssh_root_dir=/var/lib/maas/.ssh
else
    ssh_root_dir=/var/snap/maas/current/root/.ssh
fi
mkdir --mode 0700 --parents ${ssh_root_dir}
cp --verbose /root/.ssh/id_rsa{,.pub} ${ssh_root_dir}
chown --recursive maas: ${ssh_root_dir}

maas admin node-scripts create \
    name=99-snap-proxy \
    type=commissioning \
    script@=/root/99-commissioning-snap-proxy.sh
