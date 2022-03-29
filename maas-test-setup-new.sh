#!/bin/bash

set -e -u -x

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

PROXY_ADDRESS=squid-deb-proxy.virtual
PROXY=http://${PROXY_ADDRESS}:8080
DNS=172.20.0.1

snap set system proxy.http=${PROXY}
snap set system proxy.https=${PROXY}

# Fix colors in shell
sed --in-place --expression 's,^#force,force,' ~ubuntu/.bashrc
sed --in-place --expression 's,^#force,force,' /root/.bashrc

cat <<EOF >> ~ubuntu/.dircolors
DIR 38;5;75 # directory
EOF
cp ~ubuntu/.dircolors /root

while ! ping -c 1 ${PROXY_ADDRESS}; do
    sleep 1
done

snap install --channel JUJU_CHANNEL --classic juju
snap install openstackclients

# Remove virsh networks to prevent MAAS from failing to start during DHCP probe.
virsh net-destroy default || echo "ignoring"
virsh net-autostart --disable default || echo "ignoring"

apt-add-repository --yes ppa:maas/MAAS_CHANNEL
apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends maas
maas_db_password=$(sudo grep dbc_dbpass= /etc/dbconfig-common/maas-region-controller.conf | sed -e "s:^.*'\([^']*\)':\1:")
if [[ -z ${maas_db_password} ]]; then
    echo "Could not get MAAS password"
fi

if ! maas admin account list-authorisation-tokens; then
    maas createadmin \
        --username ubuntu \
        --password ubuntu \
        --email maastest@virtual \
        $([[ "LP_KEYNAME" != undefined ]] && echo "--ssh-import lp:LP_KEYNAME")
fi

maas apikey --username ubuntu > /root/ubuntu-api-key
apikey=$(maas apikey --username ubuntu)

mkdir -p ~ubuntu/juju

cat <<- EOF > ~ubuntu/juju/bootstrap.sh
#!/bin/bash -eux

declare -a model_config=()
declare -a model_defaults=(
    image-stream=released
    default-series=DEFAULT_SERIES
    no-proxy=127.0.0.1,localhost,::1,172.18.0.0/16
    apt-http-proxy=${PROXY}
    apt-https-proxy=${PROXY}
    snap-http-proxy=${PROXY}
    snap-https-proxy=${PROXY}
    juju-http-proxy=${PROXY}
    juju-https-proxy=${PROXY}
)

for d in \${model_defaults[@]}; do
    model_config+=( "--config \$d" )
done

juju bootstrap mymaas --no-gui --constraints "tags=juju" \
    --constraints "mem=2G" \${model_config[@]} os_controller \
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
maas admin maas set-config name=http_proxy value=${PROXY}
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

while ! maas admin maas set-config name=commissioning_distro_series value=DEFAULT_SERIES; do
    sleep 10
done
while ! maas admin maas set-config name=default_distro_series value=DEFAULT_SERIES; do
    sleep 10
done

declare -a fabric_names=( FABRIC_NAMES )

for fabric in "${fabric_names[@]}"; do
    maas admin spaces create name="${fabric}"
done

readarray -t fabrics < <(maas admin fabrics read | jq '.[].id')
for fabric in "${fabrics[@]}"; do
    maas admin fabric update "${fabric}" name="${fabric_names[${fabric}]}"
    maas admin vlan update "${fabric}" 0 space="${fabric_names[${fabric}]}"
done

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
    subnet_gateway=${subnet_cidr/.0\/24/.1}
    subnet_abc=${subnet_cidr/.0\/24/}

    maas admin subnet update "${subnet_id}" gateway_ip=${subnet_gateway}
    maas admin subnet update "${subnet_id}" dns_servers=${DNS}

    maas admin ipranges create type=reserved subnet="${subnet_id}" \
        comment="Infra (gateway, MAAS node, etc)" \
        start_ip=${subnet_abc}.1 end_ip=${subnet_abc}.2 \
        gateway_ip=$gw dns_servers=${DNS}

    maas admin ipranges create type=dynamic subnet="${subnet_id}" \
        comment="Enlisting, commissioning, etc" \
        start_ip=${subnet_abc}.3 end_ip=${subnet_abc}.200
done

primary=$(maas admin rack-controllers read | jq -r .[].system_id)
fabric=$(maas admin subnets read | jq ".[] | select(.cidr == \"${cidr}\") \
    | .vlan.fabric" | tr -d '"')
maas admin vlan update "${fabric}" 0 dhcp_on=true \
    primary_rack="${primary}"

# Copy ssh keys to MAAS controller so that it can talk to the libvirt daemon on
# the hypervisor.
declare ssh_root_dir
if [[ "MAAS_FROM_DEB" == yes ]]; then
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
