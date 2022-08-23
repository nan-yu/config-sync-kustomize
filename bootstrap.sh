#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

while getopts p:n:l: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        n) CLUSTER_NAME=${OPTARG};;
        l) CLUSTER_LOCATION=${OPTARG};;
    esac
done

echo "::Variable set::"
echo "PROJECT_ID: ${PROJECT_ID}"
echo "CLUSTER_NAME: ${CLUSTER_NAME}"
echo "CLUSTER_LOCATION: ${CLUSTER_LOCATION}"

gcloud services enable \
   --project=${PROJECT_ID} \
   container.googleapis.com \
   gkeconnect.googleapis.com \
   gkehub.googleapis.com \
   cloudresourcemanager.googleapis.com \
   iam.googleapis.com \
   sourcerepo.googleapis.com \
   anthosconfigmanagement.googleapis.com

gcloud beta container --project ${PROJECT_ID} clusters create-auto ${CLUSTER_NAME} \
--region ${CLUSTER_LOCATION} \
--release-channel "rapid" 

gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${CLUSTER_LOCATION} --project ${PROJECT_ID}
gcloud container fleet memberships register ${CLUSTER_NAME} --project ${PROJECT_ID}\
  --gke-cluster=${CLUSTER_LOCATION}/${CLUSTER_NAME} \
  --enable-workload-identity

REPO=config-sync-repo
gcloud source repos create 

gcloud iam service-accounts add-iam-policy-binding \
   --role roles/iam.workloadIdentityUser \
   --member "serviceAccount:${PROJECT_ID}.svc.id.goog[config-management-system/root-reconciler]" \
   acm-service-account@PROJECT_ID.iam.gserviceaccount.com

## Install Config Sync
cat <<EOF > tmp/config-sync.yaml
applySpecVersion: 1
spec:
  configSync:
    enabled: true
    sourceFormat: "unstructured"
    syncRepo: ${REPO}
    syncBranch: "main"
    secretType: "gcpserviceaccount"
    gcpServiceAccountEmail: "acm-service-account@${PROJECT_ID}.iam.gserviceaccount.com"
    policyDir: "/"
    preventDrift: true
  policyController:
    enabled: true
EOF

gcloud alpha container fleet config-management apply \
  --membership=${CLUSTER_NAME} \
  --config=tmp/config-sync.yaml \
  --project=${PROJECT_ID} -q

cat <<EOF > ${REPO}/cluster-registry/${CLUSTER_NAME}.yaml
kind: Cluster
apiVersion: clusterregistry.k8s.io/v1alpha1
metadata:
  name: ${CLUSTER_NAME}
  labels:
    environment: "prod"
    location: "${CLUSTER_LOCATION}"
EOF

cd ${REPO}
git git push --set-upstream upstream main
git add . && git commit -m "Added ${CLUSTER_NAME} to the cluster registry folder." && git push

echo "${CLUSTER_NAME} has been deployed and added to the Fleet."