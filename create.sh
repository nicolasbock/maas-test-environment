#!/bin/bash

set -u -e

SERIES=focal
NETWORK_NAME_PREFIX=maas
VM_NAME=maas-server
VCPUS=2
PROFILE=maas-profile.yaml
: ${LP_KEYNAME:=undefined}
: ${MAAS_CHANNEL:=2.7}
: ${JUJU_CHANNEL:=2.7}
: ${POSTGRESQL:=yes}

debug=0
refresh=0
console=0
sync=0
maas_deb=0

MANAGEMENT_NET=0
declare -A networks=(
    [${NETWORK_NAME_PREFIX}-oam-net]=${MANAGEMENT_NET}
    [${NETWORK_NAME_PREFIX}-admin-net]=1
    [${NETWORK_NAME_PREFIX}-internal-net]=2
    [${NETWORK_NAME_PREFIX}-public-net]=3
    [${NETWORK_NAME_PREFIX}-storage-net]=4
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

create_network() {
    local net_name=$1
    local net_subnet=$2

    if virsh net-info ${net_name}; then
        virsh net-destroy ${net_name} || :
        virsh net-undefine ${net_name} || :
    fi
    local template=maas-net-route.xml
    if [[ ${net_name} =~ oam ]]; then
        template=maas-net-nat.xml
    fi
    virsh net-define <(sed --expression "s:NAME:${net_name}:" \
        --expression "s:NETWORK4:10.0.${net_subnet}.1:" \
        --expression "s/NETWORK6/fd20::${net_subnet}:1/" \
        ${template})

    virsh net-autostart ${net_name}
    virsh net-start ${net_name}
    network_options=(
        ${network_options[@]}
        --network network=${net_name},model=virtio,address.type="pci",address.slot=$((slot_offset))
    )
    sed --expression "s:DEVICE:ens${slot_offset}:" \
        --expression "s:DHCP:false:" \
        --expression "s:ADDRESS:10.0.${net_subnet}.2/24:" \
        --expression $( (( net_subnet == ${MANAGEMENT_NET} )) \
        && echo "s:GATEWAY:10.0.${net_subnet}.1:" \
        || echo '/gateway4.*$/d') \
        --expression $( (( net_subnet == ${MANAGEMENT_NET} )) \
        && echo "s/NAMESERVERS/[10.1.0.1]/" \
        || echo '/nameservers.*$/d --expression /^.*NAMESERVERS.*/d') \
        network-config > ${tempdir}/new-interface.yaml
    yq eval-all --inplace \
        'select(fileIndex == 0) * select(fileIndex == 1)' \
        ${ci_tempdir}/network-config \
        ${tempdir}/new-interface.yaml
    slot_offset=$((slot_offset + 1))
}

while (( $# > 0 )); do
    case $1 in
        --help|-h)
            cat <<EOF
Usage:

-h | --help             This help
-s | --series           The Ubuntu series (default: ${SERIES})
-m | --maas-channel     The MAAS version (default: ${MAAS_CHANNEL}). Note, <= 2.8 requires Bionic
-j | --juju-channel     The Juju version (default: ${JUJU_CHANNEL})
-r | --refresh          Refresh cloud images
-d | --debug            Print debugging information
-c | --console          Attach to VM console after creating it
-s | --sync             Sync MAAS images (default is not to)
--maas-deb              Install MAAS from deb (not snap)

Environment Variables:

LP_KEYNAME              The launchpad key to import
EOF
            exit 0
            ;;
        --series|-s)
            shift
            SERIES=$1
            ;;
        --maas-channel|-m)
            shift
            MAAS_CHANNEL=$1
            ;;
        --juju-channel|-j)
            shift
            JUJU_CHANNEL=$1
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
        --maas-deb)
            maas_deb=1
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

if (( $(bc -l <<< "${MAAS_CHANNEL} <= 2.8") )) && [[ ${SERIES} != bionic ]]; then
    echo "MAAS channels <= 2.8 require Bionic"
    exit 1
fi

if (( $(bc -l <<< "${MAAS_CHANNEL} > 2.8") )) && [[ ${SERIES} != focal ]]; then
    echo "MAAS channels > 2.8 require Focal"
    exit 1
fi

if [[ ${refresh} = 1 ]]; then
    refresh_cloud_image
fi

echo "Purging existing MAAS server"
if virsh dominfo ${VM_NAME}; then
    virsh destroy ${VM_NAME} || :
    virsh undefine ${VM_NAME}
fi

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
cat > ${ci_tempdir}/network-config <<<ethernets:
for network in ${!networks[@]}; do
    create_network ${network} ${networks[${network}]}
done

echo "network-config:"
cat ${ci_tempdir}/network-config

if ! ssh-keygen -l -f ~/.ssh/id_rsa_maas-test; then
    ssh-keygen -N '' -f ~/.ssh/id_rsa_maas-test
fi
if ! grep --quiet "$(cat ~/.ssh/id_rsa_maas-test.pub)" ~/.ssh/authorized_keys; then
    cat ~/.ssh/id_rsa_maas-test.pub >> ~/.ssh/authorized_keys
fi

sed \
    --expression "s:LP_KEYNAME:${LP_KEYNAME}:g" \
    --expression "s:POSTGRESQL:${POSTGRESQL}:g" \
    --expression "s:MAAS_CHANNEL:${MAAS_CHANNEL}:g" \
    --expression "s:JUJU_CHANNEL:${JUJU_CHANNEL}:g" \
    --expression "s:VIRSH_USER:${USER}:g" \
    --expression "s:MAAS_FROM_DEB:$(((maas_deb == 1)) && echo "yes"):" \
    --expression "s:FABRIC_NAMES:${!networks[*]}:" \
    --expression "s:DEFAULT_SERIES:${SERIES}:" \
    maas-test-setup-new.sh > ${tempdir}/maas-test-setup.sh
sed \
    --expression "s:VIRSH_USER:${USER}:g" \
    add-machine.sh > ${tempdir}/add-machine.sh
sed \
    --expression "s:SSH_PUBLIC_KEY:$(cat ~/.ssh/id_rsa.pub):" \
    meta-data > ${ci_tempdir}/meta-data
if [[ -f ~/.vimrc ]]; then
    cp ~/.vimrc ${tempdir}
else
    touch ${tempdir}/.vimrc
fi
sed \
    --expression "s:MAAS_SSH_PRIVATE_KEY:$(base64 --wrap 0 ~/.ssh/id_rsa_maas-test):" \
    --expression "s:MAAS_SSH_PUBLIC_KEY:$(base64 --wrap 0 ~/.ssh/id_rsa_maas-test.pub):" \
    --expression "s:SSH_PUBLIC_KEY:$(cat ~/.ssh/id_rsa.pub):" \
    --expression "s:SETUP_SCRIPT:$(base64 --wrap 0 ${tempdir}/maas-test-setup.sh):" \
    --expression "s:ADD_MACHINE_SCRIPT:$(base64 --wrap 0 ${tempdir}/add-machine.sh):" \
    --expression "s:VIMRC:$(base64 --wrap 0 ${tempdir}/.vimrc):" \
    --expression "s:SYNC:${sync}:" \
    user-data > ${ci_tempdir}/user-data

echo "Creating config drive"
genisoimage -r -V cidata -o ${VM_NAME}-config-drive.iso ${ci_tempdir}
upload_volume ${VM_NAME}-config-drive.iso

echo "Creating maas disk"
image=${SERIES}-server-cloudimg-amd64.img
virsh vol-download --pool default ${image} ${tempdir}/${VM_NAME}.qcow2
qemu-img resize ${tempdir}/${VM_NAME}.qcow2 40G
upload_volume ${tempdir}/${VM_NAME}.qcow2

ssh-keygen -R 10.0.${MANAGEMENT_NET}.2

virt-install --name ${VM_NAME} \
    --memory $(( 6 * 1024 )) \
    --cpu host-passthrough,cache.mode=passthrough \
    --vcpus maxvcpus=${VCPUS} \
    --disk vol=default/${VM_NAME}.qcow2,bus=virtio,sparse=true \
    --disk vol=default/${VM_NAME}-config-drive.iso,bus=virtio,format=raw \
    --boot hd \
    --noautoconsole \
    --os-variant detect=on,name=generic \
    ${network_options[@]}

if [[ $console == 1 ]]; then
    virsh console ${VM_NAME}
fi

MAAS_IP=10.0.${MANAGEMENT_NET}.2
echo "MAAS server can be reached at ${MAAS_IP}"
echo "    http://${MAAS_IP}:5240/MAAS"
echo "You can check the installation progress by running"
echo "    virsh console ${VM_NAME}"
