# k8s-db-backup Helm Chart

Helm chart for deploying a Kubernetes database backup solution supporting PostgreSQL, MySQL, and MongoDB with S3-compatible storage.

## Introduction

The k8s-db-backup Helm chart provides a simple way to deploy a backup solution for your Kubernetes databases. It supports various database types, including PostgreSQL, MySQL, and MongoDB, and allows you to back up your data to S3-compatible storage.

## Prerequisites
- Kubernetes 1.23+
- Helm 3.8+ 
- PV provisioner support in the underlying infrastructure
- S3-compatible storage account (AWS S3, Cloudflare R2, MinIO, etc.)

## Adding the Helm repository
To use the chart, first add the Helm repository:
```sh
helm repo add debjoti https://charts.debjotimallick.store/
```

## Installing the chart
To install the chart with the release name `my-backups`, first modify the `values.yaml` file to set your S3 credentials and database instances to back up. Then run the following command:

```sh
helm install my-backups -f values.yaml debjoti/k8s-db-backup
```

## Uninstalling the chart
To uninstall/delete the `my-backups` deployment:
```sh
helm uninstall my-backups
```
This will delete all the Kubernetes components associated with the chart and delete the release.

## Configurations

| Parameter                        | Description                                         | Default |
| -------------------------------- | --------------------------------------------------- | ------- |
| `s3.endpoint`                    | S3-compatible endpoint URL                          | `""`    |
| `s3.accessKey`                   | S3 access key                                       | `""`    |
| `s3.secretKey`                   | S3 secret key                                       | `""`    |
| `mongodb.enabled`                | Enable MongoDB backups                              | `false` |
| `mongodb.schedule`               | Cron schedule for MongoDB backups                   | `""`    |
| `mongodb.bucketName`             | S3 bucket name for MongoDB backups                  | `""`    |
| `mongodb.instances`              | List of MongoDB instances to back up                | `[]`    |
| `mongodb.instances[].hostname`   | MongoDB instance hostname or service name           | `""`    |
| `mongodb.instances[].namespace`  | Namespace of the MongoDB instance                   | `""`    |
| `mongodb.instances[].port`       | MongoDB instance port (Optional)                    | `27017` |
| `postgres.enabled`               | Enable PostgreSQL backups                           | `true`  |
| `postgres.schedule`              | Cron schedule for PostgreSQL backups                | `""`    |
| `postgres.bucketName`            | S3 bucket name for PostgreSQL backups               | `""`    |
| `postgres.instances`             | List of PostgreSQL instances to back up             | `[]`    |
| `postgres.instances[].hostname`  | PostgreSQL instance hostname or service name        | `""`    |
| `postgres.instances[].namespace` | Namespace of the PostgreSQL instance                | `""`    |
| `postgres.instances[].port`      | PostgreSQL instance port (Optional)                 | `5432`  |
| `postgres.instances[].databases` | List of databases to backup (`*` for all databases) | `["*"]` |
| `mysql.enabled`                  | Enable MySQL backups                                | `true`  |
| `mysql.schedule`                 | Cron schedule for MySQL backups                     | `""`    |
| `mysql.bucketName`               | S3 bucket name for MySQL backups                    | `""`    |
| `mysql.instances`                | List of MySQL instances to back up                  | `[]`    |
| `mysql.instances[].hostname`     | MySQL instance hostname or service name             | `""`    |
| `mysql.instances[].namespace`    | Namespace of the MySQL instance                     | `""`    |
| `mysql.instances[].port`         | MySQL instance port (Optional)                      | `3306`  |
| `mysql.instances[].databases`    | List of databases to backup (`*` for all databases) | `["*"]` |
| `persistence.storageClass`       | Storage class for PVC                               | `""`    |
| `persistence.size`               | Size of PVC for storing backups                     | `10Gi`  |

### Quick start examples
- PostgreSQL (enable backups for all DBs):
```yaml
postgresql:
  enabled: true
  schedule: "0 2 * * *"
  bucketName: "my-postgres-backups"
  instances:
    - hostname: postgresql-main
      namespace: prod
      databases: ["*"]
      port: 5432
```

- MySQL (enable backups for specific DBs):
```yaml
mysql:
  enabled: true
  schedule: "0 3 * * *"
  bucketName: "my-mysql-backups"
  instances:
    - hostname: mysql-main
      namespace: prod
      databases: ["db1", "db2"]
      port: 3306
```

### Restore procedures (high-level)
1. Locate backup object in S3 (bucket and prefix per job).
2. Download backup file to a restore host or a restore pod.
3. For PostgreSQL: use pg_restore/psql to restore the dump.
4. For MySQL: use mysql client to import the SQL file.
5. For MongoDB: use mongorestore against the target instance.