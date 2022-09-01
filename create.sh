#!/bin/bash

set -u -e

NETWORK_NAME_PREFIX=maas
VM_NAME=maas-server
VCPUS=2
PROFILE=maas-profile.yaml

series=focal
debug=0
refresh=0
console=0
sync=0
: ${http_proxy:=}
maas_deb=1
maas_channel=2.7
juju_channel=2.9
lp_keyname=undefined
postgresql=1

MANAGEMENT_NET=172.18.0.0/24
declare -A networks=(
    [${NETWORK_NAME_PREFIX}-oam-net]=${MANAGEMENT_NET}
    [${NETWORK_NAME_PREFIX}-admin-net]=172.18.1.0/24
    [${NETWORK_NAME_PREFIX}-internal-net]=172.18.2.0/24
    [${NETWORK_NAME_PREFIX}-public-net]=172.18.3.0/24
    [${NETWORK_NAME_PREFIX}-storage-net]=172.18.4.0/24
)

upload_volume() {
    local size
    local imagefile=$1
    local imagename
    local format=qcow2

    imagename=$(basename $1)

    if (( $# > 1 )); then
        format=$2
    fi

    if virsh vol-info ${imagename} default; then
        virsh vol-delete ${imagename} default
    fi

    size=$(stat --dereference --format %s ${imagefile})
    virsh vol-create-as default ${imagename} ${size} --format ${format}
    virsh vol-upload --pool default ${imagename} ${imagefile}
}

refresh_cloud_image() {
    echo "Refreshing image mirror"
    local KEYRING_FILE=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
    local IMAGE_SRC=https://images.maas.io/ephemeral-v3/stable
    local IMAGE_DIR=/var/www/html/maas/images/ephemeral-v3/stable
    local series

    sudo sstream-mirror \
        --keyring=$KEYRING_FILE \
        $IMAGE_SRC \
        $IMAGE_DIR \
        'arch=amd64' \
        'release~(precise|trusty|xenial|bionic|focal)' \
        --max=1 --progress
    sudo sstream-mirror \
        --keyring=$KEYRING_FILE \
        $IMAGE_SRC \
        $IMAGE_DIR \
        'os~(grub*|pxelinux)' \
        --max=1 --progress

    echo "Refreshing cloud images"
    for series in bionic focal; do
        image=${series}-server-cloudimg-amd64.img
        wget --show-progress --continue --timestamping \
            https://cloud-images.ubuntu.com/${series}/current/${image}

        if ! virsh vol-path ${image} default; then
            upload_volume ${image}
            continue
        fi

        new_md5sum=$(md5sum ${image} | awk '{print $1}')
        old_md5sum=$(sudo md5sum "$(virsh vol-path ${image} default)" | awk '{print $1}')

        if [[ ${new_md5sum} != ${old_md5sum} ]]; then
            echo "Updating image ${image}"
            upload_volume ${image}
        fi
    done
}

get_netmask() {
    local cidr=$1
    python3 -c "import ipaddress; print(ipaddress.ip_network('${cidr}').netmask)"
}

get_prefix() {
    local cidr=$1
    python3 -c "import ipaddress; print(ipaddress.ip_network('${cidr}').prefixlen)"
}

get_network() {
    local cidr=$1
    python3 -c "import ipaddress; print(ipaddress.ip_network('${cidr}').network_address)"
}

get_host() {
    local cidr=$1
    local host=$2
    python3 -c "import ipaddress; print(list(ipaddress.ip_network('${cidr}').hosts())[${host}])"
}

get_gateway() {
    local cidr=$1
    get_host ${cidr} 0
}

create_network() {
    local net_name=$1
    local net_cidr=$2
    local mac_address

    mac_address=52:54:00:00:$(printf "%02x" $((slot_offset))):00

    if virsh net-info ${net_name}; then
        virsh net-destroy ${net_name} || :
        virsh net-undefine ${net_name} || :
    fi
    local template=maas-net-route.xml
    if [[ ${net_name} =~ oam ]]; then
        template=maas-net-nat.xml
    fi
    virsh net-define <(sed --expression "s:NAME:${net_name}:" \
        --expression "s/NETMASK/$(get_netmask ${net_cidr})/" \
        --expression "s/NETWORK4/$(get_gateway ${net_cidr})/" \
        ${template})

    virsh net-autostart ${net_name}
    virsh net-start ${net_name}
    network_options=(
        ${network_options[@]}
        --network network=${net_name},model=virtio,address.type="pci",address.slot=$((slot_offset)),mac.address=${mac_address}
    )
    sed --expression "s:DEVICE:ens${slot_offset}:" \
        --expression "s:DHCP:false:" \
        --expression "s/MACADDRESS/${mac_address}/" \
        --expression "s:ADDRESS:$(get_host ${net_cidr} 1)/$(get_prefix ${net_cidr}):" \
        --expression $( [[ ${net_cidr} == ${MANAGEMENT_NET} ]] \
        && echo "s:SUBNET_GATEWAY:$(get_gateway ${net_cidr}):" \
        || echo '/gateway4.*$/d') \
        --expression $( [[ ${net_cidr} == ${MANAGEMENT_NET} ]] \
        && echo "s/NAMESERVERS/[172.18.0.1]/" \
        || echo '/nameservers.*$/d --expression /^.*NAMESERVERS.*/d') \
        --expression "s:DEFAULT_GATEWAY:172.18.0.1:" \
        network-config.yaml > "${tempdir}"/new-interface.yaml
    yq eval-all --inplace \
        'select(fileIndex == 0) * select(fileIndex == 1)' \
        "${ci_tempdir}"/network-config \
        "${tempdir}"/new-interface.yaml
    slot_offset=$((slot_offset + 1))
}

while (( $# > 0 )); do
    case $1 in
        --help|-h)
            cat <<EOF
Usage:

-h | --help          This help
-s | --series        The Ubuntu series (default: ${series})
-r | --refresh       Refresh cloud images
-d | --debug         Print debugging information
-c | --console       Attach to VM console after creating it
-s | --sync          Sync MAAS images (default is not to)
-m | --maas-channel  The MAAS channel (default: ${maas_channel})
-j | --juju-channel  The juju channel (default: ${juju_channel})
-k | --lp-keyname    The launchpad key name to import (default: ${lp_keyname})
-p | --postgresql    Use postgresql package instead of maas-test-db (default: ${postgresql})
--maas-deb           Install MAAS from deb (not snap)
--http_proxy PROXY   The http proxy (Can also be set via http_proxy environment variable)
EOF
            exit 0
            ;;
        --series|-s)
            shift
            series=$1
            ;;
        --refresh|-r)
            refresh=1
            ;;
        --debug|-d)
            debug=1
            ;;
        --console|-c)
            console=1
            ;;
        --sync|-s)
            sync=1
            ;;
        --maas-channel|-m)
            shift
            maas_channel=$1
            ;;
        --juju-channel|-j)
            shift
            juju_channel=$1
            ;;
        --lp-keyname|-k)
            shift
            lp_keyname=$1
            ;;
        --postgresql)
            postgresql=1
            ;;
        --no-postgresql)
            postgresql=0
            ;;
        --maas-deb)
            maas_deb=1
            ;;
        --no-maas-deb)
            maas_deb=0
            ;;
        --http_proxy)
            shift
            http_proxy=$1
            ;;
        *)
            echo "unknown command line argument $1"
            exit 1
            ;;
    esac
    shift
done

if [[ ${debug} = 1 ]]; then
    echo "setting debug output"
    set -x
    PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

if [[ ${refresh} = 1 ]]; then
    refresh_cloud_image
    exit 0
fi

if (( $(bc -l <<< "${maas_channel} <= 2.8") )) && [[ ${series} != bionic ]]; then
    echo "MAAS channels <= 2.8 require Bionic"
    exit 1
fi

if (( $(bc -l <<< "${maas_channel} > 2.8") )) && [[ ${series} != focal ]]; then
    echo "MAAS channels > 2.8 require Focal"
    exit 1
fi

echo "Purging existing MAAS server"
if virsh dominfo ${VM_NAME}; then
    virsh destroy ${VM_NAME} || :
    virsh undefine ${VM_NAME}
fi

# If using jq or yq from snaps this cannot be in the regular place (/tmp) since
# snaps don't have access to this folder.
ci_tempdir=$(TMPDIR=${PWD} mktemp --directory)
tempdir=$(TMPDIR=${PWD} mktemp --directory)

echo "Configuring networks"

readarray -t existing_networks < <(virsh net-list --name | grep ${NETWORK_NAME_PREFIX})
for network in ${existing_networks[@]}; do
    virsh net-destroy ${network}
    virsh net-undefine ${network}
done

declare -a network_options
slot_offset=3
cat > "${ci_tempdir}"/network-config <<<ethernets:
for network in ${!networks[@]}; do
    create_network ${network} ${networks[${network}]}
done

echo "network-config:"
cat "${ci_tempdir}"/network-config

if ! ssh-keygen -l -f ~/.ssh/id_rsa_maas-test; then
    ssh-keygen -N '' -f ~/.ssh/id_rsa_maas-test
fi
if ! grep --quiet "$(cat ~/.ssh/id_rsa_maas-test.pub)" ~/.ssh/authorized_keys; then
    cat ~/.ssh/id_rsa_maas-test.pub >> ~/.ssh/authorized_keys
fi

sed \
    --expression "s:LP_KEYNAME:${lp_keyname}:g" \
    --expression "s:POSTGRESQL:$( ((postgresql == 1)) && echo "yes" ):g" \
    --expression "s:MAAS_CHANNEL:${maas_channel}:g" \
    --expression "s:JUJU_CHANNEL:${juju_channel}:g" \
    --expression "s:VIRSH_USER:${USER}:g" \
    --expression "s:MAAS_FROM_DEB:$( ((maas_deb == 1)) && echo "yes"):" \
    --expression "s:FABRIC_NAMES:${!networks[*]}:" \
    --expression "s:FABRIC_CIDRS:${networks[*]}:" \
    --expression "s:DEFAULT_SERIES:${series}:" \
    maas-test-setup-new.sh > "${tempdir}"/maas-test-setup.sh
sed \
    --expression "s:VIRSH_USER:${USER}:g" \
    add-machine.sh > "${tempdir}"/add-machine.sh
sed \
    --expression "s:SSH_PUBLIC_KEY:$(cat ~/.ssh/id_rsa.pub):" \
    meta-data > "${ci_tempdir}"/meta-data
if [[ -f ~/.vimrc ]]; then
    cp ~/.vimrc "${tempdir}"
else
    touch "${tempdir}"/.vimrc
fi

apt_proxy=
snap_http_proxy=
snap_https_proxy=
if [[ -n ${http_proxy} ]]; then
    apt_proxy="apt:\\n  http_proxy: ${http_proxy}"
    snap_http_proxy="snap set system proxy.http=${http_proxy}"
    snap_https_proxy="snap set system proxy.https=${http_proxy}"
fi

awk -v http_proxy="${snap_http_proxy}" \
    -v https_proxy="${snap_https_proxy}" \
    '{ gsub(/SNAP_HTTP_PROXY/, http_proxy); gsub(/SNAP_HTTPS_PROXY/, https_proxy) } { print($0) }' \
    commissioning-snap-proxy.sh \
    > ${tempdir}/commissioning-snap-proxy.sh

snap set system proxy.http=http://squid-deb-proxy.virtual:8080
snap set system proxy.https=http://squid-deb-proxy.virtual:8080

sed \
    --expression "s:MAAS_SSH_PRIVATE_KEY:$(base64 --wrap 0 ~/.ssh/id_rsa_maas-test):" \
    --expression "s:MAAS_SSH_PUBLIC_KEY:$(base64 --wrap 0 ~/.ssh/id_rsa_maas-test.pub):" \
    --expression "s:SSH_PUBLIC_KEY:$(cat ~/.ssh/id_rsa.pub):" \
    --expression "s:SETUP_SCRIPT:$(base64 --wrap 0 ${tempdir}/maas-test-setup.sh):" \
    --expression "s:ADD_MACHINE_SCRIPT:$(base64 --wrap 0 ${tempdir}/add-machine.sh):" \
    --expression "s:VIMRC:$(base64 --wrap 0 ${tempdir}/.vimrc):" \
    --expression "s:COMMISSIONING_SNAP_PROXY:$(base64 --wrap 0 ${tempdir}/commissioning-snap-proxy.sh):" \
    --expression "s:SYNC:${sync}:" \
    user-data |
    awk -v p="${apt_proxy}" '{ gsub(/APT_PROXY_SETTING/, p) } { print($0) }' \
    > "${ci_tempdir}"/user-data

echo "Creating config drive"
genisoimage -r -V cidata -o ${VM_NAME}-config-drive.iso "${ci_tempdir}"
upload_volume ${VM_NAME}-config-drive.iso

echo "Creating maas disk"
image=${series}-server-cloudimg-amd64.img
virsh vol-download --pool default ${image} "${tempdir}"/${VM_NAME}.qcow2
qemu-img resize "${tempdir}"/${VM_NAME}.qcow2 40G
upload_volume "${tempdir}"/${VM_NAME}.qcow2

ssh-keygen -R $(get_host ${MANAGEMENT_NET} 1)

virt-install --name ${VM_NAME} \
    --memory $(( 6 * 1024 )) \
    --cpu host-passthrough,cache.mode=passthrough \
    --vcpus maxvcpus=${VCPUS} \
    --disk vol=default/${VM_NAME}.qcow2,bus=virtio,sparse=true \
    --disk vol=default/${VM_NAME}-config-drive.iso,bus=virtio,format=raw \
    --boot hd,bootmenu.enable=on \
    --install no_install=true \
    --noautoconsole \
    --os-variant detect=on,name=ubuntu${series} \
    ${network_options[@]}

if (( console == 1 )); then
    virsh console ${VM_NAME}
fi

# Deleting tempdirs
rm -rf "${ci_tempdir}"
rm -rf "${tempdir}"

MAAS_IP=$(get_host ${MANAGEMENT_NET} 1)
echo "MAAS server can be reached at ${MAAS_IP}"
echo "    http://${MAAS_IP}:5240/MAAS"
echo "You can check the installation progress by running"
echo "    virsh console ${VM_NAME}"
