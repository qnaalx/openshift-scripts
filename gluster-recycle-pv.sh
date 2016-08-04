#!/bin/bash
# Script to recycle OpenShift Gluster persistent volumes.
# Capabilities include:
# * Recycle a specific PV (-p)
# * Recycle all PVs in failed state (-a)


# Define environment
## Gluster
gluster_node_ip=

## Temporary mount point for gluster volumes
temp_mount=/mnt/gluster

## Counter for the n parameter (do not change)
i=0


# Check prerequisites
## Check if executed as root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root. Aborting."
  exit 1
fi

## Check if executed on OSE master
if ! systemctl status atomic-openshift-master >/dev/null 2>&1; then
  echo "ERROR: This script must be run on an OpenShift master. Aborting."
  exit 1
fi

## FIXME: Is this a good idea? Maybe just abort and output command to execute manually.
## Check if executed as OSE system:admin
if [[ "$(oc whoami)" != "system:admin" ]]; then
  echo "Logging in as user system:admin..."
  echo "oc login -u system:admin > /dev/null"
fi


# Define functions
showsyntax() {
  echo "Syntax: $0 -a|-p GLUSTER_PV_NAME"
  echo "  -a :  Recycle all Gluster PVs in failed state."
}


# Get parameters
while getopts ":ap:" opt; do
  case $opt in
    a)
      # Get all PVs in failed state
      persistent_volumes=($(oc get pv --no-headers | grep -i failed | awk '{print $1}'))

      # Exit if there are no PVs to recycle
      if [ ${#persistent_volumes[@]} -eq 0 ] ; then
        echo "INFO: No PVs in failed state. Exiting."
        exit 0
      fi
      ;;
    p)
      # Get specified PVs (multiple are possible)
      requested_pv=$OPTARG

      # Check if the pv really exists
      if ! oc get pv "$requested_pv" >/dev/null 2>&1; then
        echo "ERROR: Provided PV \"$requested_pv\" does not exist." >&2
        exit 1
      fi

      # Add to pv array
      persistent_volumes[$i]=$requested_pv
      i=$((i+1))
      ;;
    \?)
      echo "ERROR: Invalid option -$OPTARG." >&2
      showsyntax
      exit 1
      ;;
    :)
      echo "ERROR: Option -$OPTARG requires an argument." >&2
      showsyntax
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))

if [ -z $persistent_volumes ]; then
  echo "ERROR: Either choose to recycle all PVs (-a) or specify one (-p)." >&2
  showsyntax
  exit 1
fi


# Get confirmation
echo -e "\nPVs to recycle:"
printf '%s\n' "${persistent_volumes[@]}"

echo -e "\nAll data on these PVs will be erased.\nDo you wish to continue?"
select yn in "Yes" "No"; do
  case $yn in
    Yes) break;;
    No)  exit;;
  esac
done


# Recycle procedure for every single PV
for persistent_volume in "${persistent_volumes[@]}"; do

  # Get size of existing PV
  OIFS="$IFS"
  IFS=';'
  pv_info=($(oc get pv "$persistent_volume" -o template --template='{{.spec.capacity.storage}};{{.spec.glusterfs.path}};{{.spec.glusterfs.endpoints}}' 2>/dev/null))
  pv_size=${pv_info[0]}
  pv_path=${pv_info[1]}
  pv_ep=${pv_info[2]}
  IFS="$OIFS"
 
  # Delete PV in OpenShift
  oc delete pv "$persistent_volume"
 
  # Mount GlusterFS volume
  mkdir $temp_mount
  mount -t glusterfs ${gluster_node_ip}:${persistent_volume} $temp_mount
 
  # Delete GlusterFS volume content
  rm -rf ${temp_mount:?}/*

  # Unmount GlusterFS volume
  umount $temp_mount
 
  # Recreate PV in OpenShift
  cat <<-EOF | oc create -f -
{
    "kind": "PersistentVolume",
    "apiVersion": "v1",
    "metadata": {
        "name": "${persistent_volume}",
    },
    "spec": {
        "capacity": {
            "storage": "${pv_size}"
        },
        "glusterfs": {
            "endpoints": "${pv_ep}",
            "path": "${pv_path}"
        },
        "accessModes": [
            "ReadWriteOnce",
            "ReadWriteMany"
        ],
        "persistentVolumeReclaimPolicy": "Recycle"
    },
}
EOF

done

