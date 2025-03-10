#!/bin/bash

set -eo pipefail

OPTION=${1:-'create_offlineversion'} ## create_offlineversion  create_componentsversion

KUBESPRAY_TAG=${KUBESPRAY_TAG:-"v2.19.0"} ## env from github action
KUBEAN_TAG=${KUBEAN_TAG:-"v0.1.0"} ## env from github action

CURRENT_DIR=$(cd $(dirname $0); pwd) ## artifacts dir
CURRENT_DATE=$(date +%Y%m%d)

ARTIFACTS_TEMPLATE_DIR=artifacts/template/
KUBEAN_OFFLINE_VERSION_TEMPLATE=${ARTIFACTS_TEMPLATE_DIR}/kubeanofflineversion.template.yml
KUBEAN_COMPONENTS_VERSION_TEMPLATE=${ARTIFACTS_TEMPLATE_DIR}/kubeancomponentsversion.template.yml

CHARTS_TEMPLATE_DIR=charts/kubean/templates
OFFLINE_PACKAGE_DIR=${KUBEAN_TAG}
KUBEAN_OFFLINE_VERSION_CR=${OFFLINE_PACKAGE_DIR}/kubeanofflineversion.cr.yaml
KUBEAN_COMPONENTS_VERSION_CR=${CHARTS_TEMPLATE_DIR}/kubeancomponentsversion.cr.yaml

KUBESPRAY_DIR=kubespray
KUBESPRAY_OFFLINE_DIR=${KUBESPRAY_DIR}/contrib/offline
VERSION_VARS_YML=${KUBESPRAY_OFFLINE_DIR}/version.yml


function check_dependencies() {
  if ! which yq; then
    echo "need yq (https://github.com/mikefarah/yq)."
    exit 1
  fi
  if [ ! -d ${KUBESPRAY_DIR} ]; then
		echo "${KUBESPRAY_DIR} git repo should exist."
    exit 1
	fi
}

function extract_etcd_version() {
  kube_version=${1} ## v1.23.1
  IFS='.'
  read -ra arr <<< "${kube_version}"
  major="${arr[0]}.${arr[1]}"
  version=$(yq ".etcd_supported_versions.\"${major}\"" kubespray/roles/download/defaults/main.yml)
  echo "$version"
}

function extract_version() {
  version_name="${1}"   ## cni_version
  dir=${2:-"download"} ## kubespray-defaults  or download
  version=$(yq ".${version_name}" kubespray/roles/"${dir}"/defaults/main.*ml)
  echo "$version"
}

function extract_version_range() {
  range_path="${1}"   ## .cni_binary_checksums.amd64
  dir=${2:-"download"} ## kubespray-defaults  or download
  version=$(yq "${range_path} | keys" kubespray/roles/"${dir}"/defaults/main.*ml --output-format json)
  version=$(echo $version | tr -d '\n \r') ## ["v1","v2"]
  echo "${version}"
}

function update_offline_version_cr() {
  index=$1 ## start with zero
  name=$2  ## cni containerd ...
  version_val=$3
  if [ $(yq ".spec.items[$index].name" $KUBEAN_OFFLINE_VERSION_CR) != "${name}" ]; then
    echo "error param $index $name"
    exit 1
  fi
  version_val=${version_val} yq -i ".spec.items[$index].versionRange[0]=strenv(version_val)" $KUBEAN_OFFLINE_VERSION_CR
}

function create_offline_version_cr() {
  cni_version=$(extract_version "cni_version")
  containerd_version=$(extract_version "containerd_version")
  kube_version=$(extract_version "kube_version" "kubespray-defaults")
  calico_version=$(extract_version "calico_version")
  cilium_version=$(extract_version "cilium_version")
  etcd_version=$(extract_etcd_version "$kube_version")

  mkdir -p $OFFLINE_PACKAGE_DIR
  cp $KUBEAN_OFFLINE_VERSION_TEMPLATE $KUBEAN_OFFLINE_VERSION_CR
  CR_NAME=offlineversion-${CURRENT_DATE} yq -i '.metadata.name=strenv(CR_NAME)' $KUBEAN_OFFLINE_VERSION_CR
  KUBESPRAY_TAG=${KUBESPRAY_TAG} yq -i '.spec.kubespray=strenv(KUBESPRAY_TAG)' $KUBEAN_OFFLINE_VERSION_CR

  update_offline_version_cr "0" "cni" "$cni_version"
  update_offline_version_cr "1" "containerd" "$containerd_version"
  update_offline_version_cr "2" "kube" "$kube_version"
  update_offline_version_cr "3" "calico" "$calico_version"
  update_offline_version_cr "4" "cilium" "$cilium_version"
  update_offline_version_cr "5" "etcd" "$etcd_version"
}

function update_components_version_cr() {
  index=$1 ## start with zero
  name=$2  ## cni containerd ...
  default_version_val=$3
  version_range=$4
  if [ $(yq ".spec.items[$index].name" $KUBEAN_COMPONENTS_VERSION_CR) != "${name}" ]; then
    echo "error param $index $name"
    exit 1
  fi

  yq -i ".spec.items[$index].defaultVersion=\"${default_version_val}\"" $KUBEAN_COMPONENTS_VERSION_CR
  yq -i ".spec.items[$index].versionRange |=  ${version_range}" $KUBEAN_COMPONENTS_VERSION_CR ## update string array
}

function create_components_version_cr() {
  cni_version_default=$(extract_version "cni_version")
  cni_version_range=$(extract_version_range ".cni_binary_checksums.amd64")

  containerd_version_default=$(extract_version "containerd_version")
  containerd_version_range=$(extract_version_range ".containerd_archive_checksums.amd64")

  kube_version_default=$(extract_version "kube_version" "kubespray-defaults")
  kube_version_range=$(extract_version_range ".kubelet_checksums.amd64")

  calico_version_default=$(extract_version "calico_version")
  calico_version_range=$(extract_version_range ".calico_crds_archive_checksums")

  cilium_version_default=$(extract_version "cilium_version")
  cilium_version_range="[]" ## anything

  etcd_version_default=$(extract_etcd_version "$kube_version_default")
  etcd_version_range=$(extract_version_range ".etcd_binary_checksums.amd64")

  cp $KUBEAN_COMPONENTS_VERSION_TEMPLATE $KUBEAN_COMPONENTS_VERSION_CR
  KUBESPRAY_TAG=${KUBESPRAY_TAG} yq -i '.spec.kubespray=strenv(KUBESPRAY_TAG)' $KUBEAN_COMPONENTS_VERSION_CR
  KUBEAN_TAG=${KUBEAN_TAG} yq -i '.spec.kubean=strenv(KUBEAN_TAG)' $KUBEAN_COMPONENTS_VERSION_CR

  update_components_version_cr 0 cni "${cni_version_default}" "${cni_version_range}"
  update_components_version_cr 1 containerd "${containerd_version_default}" "${containerd_version_range}"
  update_components_version_cr 2 kube "${kube_version_default}" "${kube_version_range}"
  update_components_version_cr 3 calico "${calico_version_default}" "${calico_version_range}"
  update_components_version_cr 4 cilium "${cilium_version_default}" "${cilium_version_range}"
  update_components_version_cr 5 etcd "${etcd_version_default}" "${etcd_version_range}"
}

case $OPTION in
create_offlineversion)
  check_dependencies
  create_offline_version_cr
  ;;

create_componentsversion)
  check_dependencies
  create_components_version_cr
  ;;

*)
  echo -n "unknown operator"
  ;;
esac
