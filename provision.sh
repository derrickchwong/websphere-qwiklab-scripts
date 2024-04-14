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
    --location=$REGION \
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
    --instance-type=PRIMARY --cpu-count=2 --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED --async

echo "Creating firewall rule for WAS..."

gcloud compute firewall-rules create allow-was \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:9060,tcp:9080 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=was


echo "Creating firewall rule for Oracle..."

gcloud compute firewall-rules create allow-oracle \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:1521 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=oracle

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
        --tags=oracle \
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
    sleep 15
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
    echo "WAS instance is ready. Starting WAS..."
    sleep 15
    gcloud compute ssh was-cafe --zone=$ZONE --command "sudo /opt/IBM/WebSphere/AppServer/profiles/AppSrv01/bin/startServer.sh server1"
    echo "WAS started"
    EXTERNAL_IP=$(gcloud compute instances describe was-cafe --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    echo "Access WAS instance at http://${EXTERNAL_IP}:9080/websphere-cafe"
    break
  else
    echo "Waiting for WAS instance to be ready..."
    sleep 10
  fi
done


echo "Creating the VPC network for the Database Migration Service Private Service Connect."
gcloud compute networks create dms-psc-vpc \
--project=$PROJECT_ID \
--subnet-mode=custom

echo "Creating a subnet for the Database Migration Service Private Service Connect."
gcloud compute networks subnets create dms-psc-$REGION \
--project=$PROJECT_ID \
--range=10.0.0.0/16 --network=dms-psc-vpc \
--region=$REGION

echo "Creating a router required for the bastion to be able to install external"
# packages (for example, Dante SOCKS server):
gcloud compute routers create ex-router-$REGION \
--network dms-psc-vpc \
--project=$PROJECT_ID \
--region=$REGION

echo "Creating a NAT gateway for the bastion VM."
gcloud compute routers nats create ex-nat-$REGION \
--router=ex-router-$REGION \
--auto-allocate-nat-external-ips \
--nat-all-subnet-ip-ranges \
--enable-logging \
--project=$PROJECT_ID \
--region=$REGION

export ALLOYDB_IP=$(gcloud alloydb instances describe primary \
--cluster=alloydb1 \
--project=$PROJECT_ID \
--region=$REGION \
--format='value(ipAddress)')

echo "AlloyDB IP: "$ALLOYDB_IP

export GATEWAY=$(gcloud compute networks subnets describe default \
--project=$PROJECT_ID \
--region=$REGION  \
--format="value(gatewayAddress)")

echo "Gateway: $GATEWAY"

echo "Creating the bastion VM."
gcloud compute instances create bastion \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --network-interface subnet=dms-psc-$REGION,no-address \
    --network-interface subnet=default,no-address \
    --metadata=alloydb-ip=$ALLOYDB_IP,gateway=$GATEWAY,startup-script='#! /bin/bash

# curl the gce metadata server to get the AlloyDB IP address from metadata and assign to variable ALLOYDB_IP
export ALLOYDB_IP=$(curl -H "Metadata-Flavor: Google" \
http://metadata.google.internal/computeMetadata/v1/instance/attributes/alloydb-ip)

# curl the gce metadata server to get the Gateway IP from metadata and assign to variable GATEWAY
export GATEWAY=$(curl -H "Metadata-Flavor: Google" \
http://metadata.google.internal/computeMetadata/v1/instance/attributes/gateway)

ip route add $ALLOYDB_IP via $GATEWAY

# Install Dante SOCKS server.
apt-get install -y dante-server

# Create the Dante configuration file.
touch /etc/danted.conf

# Create a proxy.log file.
touch proxy.log

# Add the following configuration for Dante:
cat > /etc/danted.conf << EOF
logoutput: /proxy.log
user.privileged: proxy
user.unprivileged: nobody

internal: 0.0.0.0 port = 5432
external: ens5

clientmethod: none
socksmethod: none

client pass {
        from: 0.0.0.0/0
        to: 0.0.0.0/0
        log: connect error disconnect
}
client block {
        from: 0.0.0.0/0
        to: 0.0.0.0/0
        log: connect error
}
socks pass {
        from: 0.0.0.0/0
        to: 10.23.17.2/32
        protocol: tcp
        log: connect error disconnect
}
socks block {
        from: 0.0.0.0/0
        to: 0.0.0.0/0
        log: connect error
}
EOF

# Start the Dante server.
systemctl restart danted

tail -f proxy.log'

echo "Creating the target instance from the created bastion VM."
gcloud compute target-instances create bastion-ti-$REGION \
--instance=bastion \
--project=$PROJECT_ID \
--instance-zone=$ZONE \
--network=dms-psc-vpc

echo "Creating a forwarding rule for the backend service."
gcloud compute forwarding-rules create dms-psc-forwarder-$REGION \
--project=$PROJECT_ID \
--region=$REGION \
--load-balancing-scheme=internal \
--network=dms-psc-vpc \
--subnet=dms-psc-$REGION \
--ip-protocol=TCP \
--ports=all \
--target-instance=bastion-ti-$REGION \
--target-instance-zone=$ZONE

echo "Creating a TCP NAT subnet."
gcloud compute networks subnets create dms-psc-nat-$REGION-tcp \
--network=dms-psc-vpc \
--project=$PROJECT_ID \
--region=$REGION \
--range=10.1.0.0/16 \
--purpose=private-service-connect

echo "Creating a service attachment."
gcloud compute service-attachments create dms-psc-svc-att-$REGION \
--project=$PROJECT_ID \
--region=$REGION \
--producer-forwarding-rule=dms-psc-forwarder-$REGION \
--connection-preference=ACCEPT_MANUAL \
--nat-subnets=dms-psc-nat-$REGION-tcp

echo "Creating a firewall rule allowing the Private Service Connect NAT subnet."
# access the Private Service Connect subnet
gcloud compute \
--project=$PROJECT_ID firewall-rules create dms-allow-psc-tcp \
--direction=INGRESS \
--priority=1000 \
--network=dms-psc-vpc \
--action=ALLOW \
--rules=all \
--source-ranges=10.1.0.0/16 \
--enable-logging

# Print out the created service attachment.
gcloud compute service-attachments describe dms-psc-svc-att-$REGION \
--project=$PROJECT_ID \
--region=$REGION

