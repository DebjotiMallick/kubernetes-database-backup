# k8s-db-backup Helm Chart

Helm chart for deploying Kubernetes Database Backup automation tool to Kubernetes/OpenShift.

# Introduction

## Prerequisites
- Kubernetes 1.23+
- Helm 3.8+ 
- PV provisioner support in the underlying infrastructure
- S3-compatible storage account (AWS S3, Cloudflare R2, MinIO, etc.)

## Installing the chart
Download the default values.yaml and update required parameters.

Add the repo in local:
```sh
helm repo add debjoti https://charts.debjotimallick.store/
```

Install the chart using the modified values
```sh
helm install my-backups -f my-values.yaml debjoti/k8s-db-backup
```