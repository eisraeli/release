#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

dir=${HOME}/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

KUBECONFIG=${HOME}/secret-kube/kubeconfig-infra-cluster openshift-install --dir="${dir}" create manifests &
wait "$!"

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)

TF_LOG=debug KUBECONFIG=${HOME}/secret-kube/kubeconfig-infra-cluster openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e

sed '
  s/password: .*/password: REDACTED/;
  s/X-Auth-Token.*/X-Auth-Token REDACTED/;
  s/UserData:.*,/UserData: REDACTED,/;
  ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"

cp \
    -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig" \
    "${dir}/auth/kubeadmin-password" \
    "${dir}/metadata.json"
exit "$ret"
