#!/bin/bash

set -u -e

debug=0

memory=1024
disk=8
declare -a networks=(
  maas-oam-net
)

while (( $# > 0 )); do
  case $1 in
    -h|--help)
      cat <<EOF
Usage:

-h | --help     This help
     --debug    Print debugging information
-n | --name     The name of the machine (libvirt ID)
-m | --memory   The memory size in MiB
-d | --disk     The disk size in GiB
-i | --network  A network name to connect to in addition to
                the maas-oam-net. This option can be used
                multiple times.
EOF
      exit
      ;;
    --debug)
      debug=1
      ;;
    -n|--name)
      shift
      if (( $# <= 0 )); then
        echo "missing machine name"
        exit 1
      fi
      vm_id=$1
      ;;
    -m|--memory)
      shift
      if (( $# <= 0 )); then
        echo "missing memory size"
        exit 1
      fi
      memory=$1
      ;;
    -d|--disk)
      shift
      if (( $# <= 0 )); then
        echo "missing disk size"
        exit 1
      fi
      disk=$1
      ;;
    -i|--network)
      shift
      if (( $# <= 0 )); then
        echo "missing network name"
        exit 1
      fi
      networks=( ${networks[@]} $1 )
      ;;
    *)
      echo "unknown command line argument"
      exit 1
      ;;
  esac
  shift
done

if ! [[ -v vm_id ]]; then
  echo "missing machine name"
  exit 1
fi

if (( debug = 1 )); then
  set -x
  PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

VIRSH_IP=$(ip route show default | awk '{print $3}')

virt-install \
  --connect qemu+ssh://VIRSH_USER@${VIRSH_IP}/system \
  --name ${vm_id} \
  --memory ${memory} \
  --disk size=8 \
  --network network=maas-oam-net \
  --network network=maas-admin-net \
  --boot network \
  --noautoconsole

ip=$(virsh --connect qemu+ssh://VIRSH_USER@${VIRSH_IP}/system \
  domifaddr maas-server | grep ipv4 | awk '{print $4}' | awk -F/ '{print $1}')
mac=$(xmllint --xpath "//source[@network='maas-oam-net']/../mac/@address" \
  <(virsh --connect qemu+ssh://VIRSH_USER@${VIRSH_IP}/system dumpxml ${vm_id}) \
  | awk -F= '{print $2}' | tr --delete '"')

maas admin machines create \
  architecture=amd64 \
  mac_addresses=${mac} \
  power_type=virsh \
  power_parameters_power_id=${vm_id} \
  power_parameters_power_address=qemu+ssh://VIRSH_USER@${VIRSH_IP}/system
