#!/bin/bash

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export REGION=us-central1
export ZONE=us-central1-a

echo "Enabling required services..."

gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudapis.googleapis.com \
  alloydb.googleapis.com \
  datamigration.googleapis.com \
  servicenetworking.googleapis.com \
  --project=$PROJECT_ID

echo "Adding service account to project IAM policy..."

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/compute.admin

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/iam.serviceAccountUser

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/iam.serviceAccountTokenCreator

echo "Importing Oracle DB image..."

gcloud compute images import oracle-db \
    --source-file=gs://derrickwong-storage/oracle-db.vmdk \
    --guest-environment \
    --zone=$ZONE \
    --async

echo "Importing WAS Cafe image..."

gcloud compute images import was-cafe \
    --source-file=gs://derrickwong-storage/was-cafe.vmdk \
    --guest-environment \
    --zone=$ZONE \
    --async

echo "Creating GKE Autopilot cluster..."

gcloud beta container --project ${PROJECT_ID} clusters create-auto "autopilot-cluster-1" \
    --region ${REGION} \
    --release-channel "regular" \
    --network "projects/${PROJECT_ID}/global/networks/default" \
    --subnetwork "projects/${PROJECT_ID}/regions/${REGION}/subnetworks/default" \
    --cluster-ipv4-cidr "/17" \
    --binauthz-evaluation-mode=DISABLED \
    --async

echo "Creating Artifact Registry repository..."

gcloud artifacts repositories create container \
    --repository-format=docker \
    --location=us-central1 \
    --description="Container repository"

echo "Creating default IP range..."

gcloud compute addresses create default-ip-range \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=16 \
    --network=default

echo "Connecting VPC peering..."

gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=default-ip-range \
    --network=default

echo "Creating AlloyDB cluster..."

gcloud beta alloydb clusters create alloydb1 \
    --region=$REGION \
    --password=postgres \
    --allocated-ip-range-name=default-ip-range \
    --network=projects/${PROJECT_ID}/global/networks/default 

echo "Creating AlloyDB primary instance..."

gcloud beta alloydb instances create primary --cluster=alloydb1 --region=$REGION \
    --instance-type=PRIMARY --cpu-count=2 --async

echo "Creating firewall rule for WAS..."

gcloud compute firewall-rules create allow-was \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:9060,tcp:9080 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=was

# Check if WAS Cafe image imported successfully
while true; do
  IMAGE_STATUS=$(gcloud compute images describe was-cafe --format="value(status)")
  if [[ "${IMAGE_STATUS}" == "READY" ]]; then
    echo "WAS Cafe image imported successfully."
    gcloud compute instances create was-cafe \
        --image=was-cafe \
        --zone=$ZONE \
        --machine-type=e2-medium \
        --tags=was \
        --async
    break
  else
    echo "Waiting for WAS Cafe image to import..."
    sleep 10
  fi
done

# Check if Oracle DB image imported successfully
while true; do
  IMAGE_STATUS=$(gcloud compute images describe oracle-db --format="value(status)")
  if [[ "${IMAGE_STATUS}" == "READY" ]]; then
    echo "Oracle DB image imported successfully."
    gcloud compute instances create oracle-db \
        --image=oracle-db \
        --zone=$ZONE \
        --machine-type=e2-medium \
        --async
    break
  else
    echo "Waiting for Oracle DB image to import..."
    sleep 10
  fi
done


# Check if Oracle DB instance is ready
while true; do
  INSTANCE_STATUS=$(gcloud compute instances describe oracle-db --format="value(status)" --zone=$ZONE)
  if [[ "${INSTANCE_STATUS}" == "RUNNING" ]]; then
    echo "Oracle DB instance is ready."
    mkdir ~/.ssh
    ssh-keygen -t rsa -f ~/.ssh/google_compute_engine -C $(whoami)@cs-$PROJECT_NUMBER-default -b 2048 -q -N ""
    gcloud compute ssh oracle-db --zone=$ZONE --command "sudo sed -i -e 's/ oracle-db / oracle-db.us-central1-a.c.m2c-demo.internal oracle-db /g' /etc/hosts && sudo systemctl daemon-reload && sudo systemctl enable oracle-xe-21c && sudo systemctl start oracle-xe-21c"
    break
  else
    echo "Waiting for Oracle DB instance to be ready..."
    sleep 10
  fi
done

# Check if WAS instance is ready
while true; do
  INSTANCE_STATUS=$(gcloud compute instances describe was-cafe --format="value(status)" --zone=$ZONE)
  if [[ "${INSTANCE_STATUS}" == "RUNNING" ]]; then
    echo "WAS instance is ready."
    EXTERNAL_IP=$(gcloud compute instances describe was-cafe --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    echo "\nAccess WAS instance at http://${EXTERNAL_IP}:9080/websphere-cafe"
    break
  else
    echo "Waiting for WAS instance to be ready..."
    sleep 10
  fi
done