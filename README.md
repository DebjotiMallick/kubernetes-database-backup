# Automated Database Backup System

Automation Database Backup Engine, which takes periodical database dump and push it to COS repository buckets

## Releases:
| Version | Features                                                                                                                  |
| ------- | ------------------------------------------------------------------------------------------------------------------------- |
| 3.3.2   | Updated mc client                                                                                                         |
| 3.3.1   | Updated kubectl version to latest (1.32)                                                                                  |
| 3.3     | Major updates include ubuntu 24.04 base image, postgresql-client 16, milvus backup 0.5.2, COS update strategy change etc. |
| 3.2     | Added telnet, ssh, netstat, ping commands                                                                                 |
| 3.1     | Added UAT milvus certificate                                                                                              |
| 3.0     | Minor fix                                                                                                                 |
| 2.9     | Added IBM Root CA certificate                                                                                             |
| 2.8     | Added MinIO client                                                                                                        |
| 2.7     | Added milvus backup tool                                                                                                  |
| 2.6     | Added bc & sendgrid for cert-renewal script                                                                               |
| 2.5     | Added weaviate-ts-client                                                                                                  |
| 2.4     | Updated nodejs version to 20.x                                                                                            |
| 2.3     | Added postgresql client version 15 and oc client                                                                          |
| 2.2     | Updated mongodb org tools                                                                                                 |

# Database Backup System

## Overview
This system automates the backup of multiple databases and stores them securely in designated object storage buckets. The backups are categorized based on the database type and environment (Dev, UAT, Prod).

## Backup Storage Mapping
| Database   | Dev Backup Bucket         | UAT Backup Bucket         | Prod Backup Bucket         |
| ---------- | ------------------------- | ------------------------- | -------------------------- |
| MongoDB    | `roks-dev-mongodbbackup`  | `roks-uat-mongodbbackup`  | `roks-prod-mongodbbackup`  |
| PostgreSQL | `roks-dev-postgresbackup` | `roks-uat-postgresbackup` | `roks-prod-postgresbackup` |
| MySQL      | `roks-dev-mysqlbackup`    | `roks-uat-mysqlbackup`    | `roks-prod-mysqlbackup`    |
| Milvus     | `roks-dev-milvusbackup`   | `roks-uat-milvusbackup`   | `roks-prod-milvusbackup`   |
| MariaDB    | `roks-dev-mariadbbackup`  | `roks-uat-mariadbbackup`  | `roks-prod-mariadbbackup`  |

## Features
- Automated scheduled backups
- Secure storage in environment-specific object storage buckets
- Supports multiple database types (MongoDB, PostgreSQL, MySQL, Milvus, MariaDB)
- Configurable retention policies
- Logs and monitoring for backup verification

## Backup Process
1. The backup system connects to each database instance and performs a dump/export.
2. The backup file is compressed and stored securely.
3. The file is uploaded to the designated bucket for the corresponding environment.
4. The system logs the backup details and verifies integrity.

## Setup and Configuration
1. **Database Credentials:** Ensure database connection details are set in environment variables or a secure configuration file.
2. **Object Storage Access:** Ensure proper IAM roles or API keys are configured for uploading backups.
3. **Scheduling:** Use a cron job or Kubernetes CronJob to trigger backups at the desired frequency.

## Monitoring and Logs
- Backup logs are stored in `/var/logs/db-backups.log`
- Cloud storage logs can be monitored to verify uploads
- Alerts can be configured for failed backups using monitoring tools

## Restore Process
1. Download the required backup from the storage bucket.
2. Extract and restore using the appropriate database restore command:
   - **MongoDB:** `mongorestore -u root -p <password> --authenticationDatabase admin --gzip --archive=backup.gz`
   - **PostgreSQL:** `gzip -dk backup_file.gz | psql -U postgres -f backup_file`
   - **MySQL:** `gzip -dk backup_file.gz | mysql -u root -p<password> < backup_file`
   - **Milvus:** Use Milvus restore APIs
   - **MariaDB:** `gzip -dk backup_file.gz | mysql -u root -p<password> < backup_file`

## Future Enhancements
- Incremental backups for better efficiency
- Integration with a centralized backup management dashboard
- Automated restore testing for backup integrity verification

---
**Maintained by:** SRE Team

