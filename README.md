<h1 align="center" id="title">Kubernetes Database Backup</h1>

<p align="center"><img src="https://socialify.git.ci/DebjotiMallick/kubernetes-database-backup/image?description=1&language=1&name=1&owner=1&theme=Light" alt="project-image"></p>

<p id="description">A simple reliable database backup solution for Kubernetes and OpenShift.</p>

## Introduction

This Helm chart deploys a Kubernetes-native solution for backing up databases such as PostgreSQL, MySQL, and MongoDB to S3-compatible storage. It leverages Kubernetes CronJobs to schedule regular backups and stores them in a specified S3 bucket. 

## Prerequisites
- Kubernetes 1.23+
- Helm 3.8+ 
- PV provisioner support in the underlying infrastructure
- S3-compatible storage account (AWS S3, Cloudflare R2, MinIO, etc.)

## Features
- Supports PostgreSQL, MySQL, and MongoDB databases.
- Configurable backup schedules using Cron expressions.
- Stores backups in S3-compatible storage.
- Easy to configure and deploy using Helm.
- Supports multiple database instances and databases per instance.
- Retention policy for old backups.

## Installation
```sh
helm repo add debjoti https://charts.debjotimallick.store/
helm install my-backups -f values.yaml debjoti/k8s-db-backup
```

For detailed installation instructions, refer to the [Installation Guide](https://github.com/DebjotiMallick/kubernetes-database-backup/blob/main/charts/README.md)

Artifacts are stored in Artifact Hub: https://artifacthub.io/packages/helm/debjoti-mallick/k8s-db-backup

Give a star if you find this project useful! ⭐