#!/bin/bash

set -u -e

SERIES=focal
VM_NAME=maas
PROFILE=maas-profile.yaml
MAAS_CHANNEL=2.8/stable
JUJU_CHANNEL=2.8/stable
: ${LP_KEYNAME:=undefined}

debug=0
refresh=0
console=0

upload_volume() {
  local size
  local imagefile=$1
  local imagename=$(basename $1)
  local format=qcow2

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
    old_md5sum=$(sudo md5sum $(virsh vol-path ${image} default) | awk '{print $1}')

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
  virsh net-define <(sed --expression "s:NAME:${net_name}:" \
    --expression "s:NETWORK:10.${net_subnet}.0.1:" maas-net.xml)

  virsh net-autostart ${net_name}
  virsh net-start ${net_name}
  network_options=(
    ${network_options[@]}
    --network network=${net_name},model=virtio,address.type="pci",address.slot=$((slot_offset))
  )
  sed --expression "s:DEVICE:ens${slot_offset}:" \
    --expression "s:DHCP:false:" \
    --expression "s:ADDRESS:10.${net_subnet}.0.2/24:" \
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

-h | --help     This help
-s | --series   The Ubuntu series (default: ${SERIES})
-r | --refresh  Refresh cloud images
-d | --debug    Print debugging information
-c | --console  Attach to VM console after creating it
EOF
      exit 0
      ;;
    --series|-s)
      shift
      SERIES=$1
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
fi

echo "Purging existing MAAS server"
if virsh dominfo maas-server; then
  virsh destroy maas-server || :
  virsh undefine maas-server
fi

ci_tempdir=$(TMPDIR=${PWD} mktemp --directory)
tempdir=$(TMPDIR=${PWD} mktemp --directory)

echo "Configuring networks"
declare -A networks=(
  [maas-oam-net]=0
  [maas-admin-net]=1
  [maas-internal-net]=2
  [maas-public-net]=3
  [maas-external-net]=4
  [maas-k8s-net]=5
)

declare -a network_options
slot_offset=3
cat > ${ci_tempdir}/network-config <<<ethernets:
for network in ${!networks[@]}; do
  create_network ${network} ${networks[${network}]}
done

sed --expression "s:DEVICE:ens${slot_offset}:" \
  --expression "s:DHCP:true:" \
  --expression "/^.*addresses.*/d" \
  network-config > ${tempdir}/new-interface.yaml
yq eval-all --inplace \
  'select(fileIndex == 0) * select(fileIndex == 1)' \
  ${ci_tempdir}/network-config \
  ${tempdir}/new-interface.yaml
cat ${ci_tempdir}/network-config

if ! ssh-keygen -l -f ~/.ssh/id_rsa_maas-test; then
  ssh-keygen -N '' -f ~/.ssh/id_rsa_maas-test
fi
if ! grep --quiet "$(cat ~/.ssh/id_rsa_maas-test.pub)" ~/.ssh/authorized_keys; then
  cat ~/.ssh/id_rsa_maas-test.pub >> ~/.ssh/authorized_keys
fi

sed \
  --expression "s:LP_KEYNAME:${LP_KEYNAME}:" \
  --expression "s:MAAS_CHANNEL:${MAAS_CHANNEL}:" \
  --expression "s:JUJU_CHANNEL:${JUJU_CHANNEL}:" \
  --expression "s:VIRSH_USER:${USER}:" \
  maas-test-setup.sh > ${tempdir}/maas-test-setup.sh
sed \
  --expression "s:VIRSH_USER:${USER}:" \
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
  user-data > ${ci_tempdir}/user-data

echo "Creating config drive"
genisoimage -r -V cidata -o maas-server-config-drive.iso ${ci_tempdir}
upload_volume maas-server-config-drive.iso

echo "Creating maas disk"
image=${SERIES}-server-cloudimg-amd64.img
virsh vol-download --pool default ${image} ${tempdir}/maas-server.qcow2
qemu-img resize ${tempdir}/maas-server.qcow2 40G
upload_volume ${tempdir}/maas-server.qcow2

virt-install --name maas-server \
  --memory 4096 \
  --cpu host-passthrough,cache.mode=passthrough \
  --vcpus maxvcpus=2 \
  --disk vol=default/maas-server.qcow2,bus=virtio,sparse=true \
  --disk vol=default/maas-server-config-drive.iso,bus=virtio,format=raw \
  --boot hd \
  --noautoconsole \
  --os-type generic \
  ${network_options[@]} \
  --network network=default,model=virtio,address.type="pci",address.slot=$((slot_offset))

if [[ $console == 1 ]]; then
  virsh console maas-server
fi

while true; do
  MAAS_IP=$(virsh domifaddr maas-server | grep ipv4 | awk '{print $4}' | cut -d / -f 1)
  if [[ -z ${MAAS_IP} ]]; then
    sleep 1
    continue
  fi
  break
done

echo "MAAS server can be reached at ${MAAS_IP}"
echo "    http://${MAAS_IP}:5240/MAAS"
echo "You can check the installation progress by running"
echo "    virsh console maas-server"
