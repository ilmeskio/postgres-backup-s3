# ADR 001: Standardize on S3-Compatible Object Storage

- **Status:** Accepted
- **Date:** 2025-03-15

## Context
We need a durable, off-site destination for periodic PostgreSQL dumps. Our workloads run inside lightweight containers and
must integrate with common infrastructure across AWS, DigitalOcean, Backblaze, and on-prem deployments. Block storage or
local volumes add operational drag—teams would have to mount disks, size them for peak retention, and handle lifecycle
policies manually. We also need lifecycle rules, server-side encryption options, and cross-region replication without
reinventing the wheel.

## Decision
We standardize on S3-compatible object storage as the target for backups. Every environment configures the container with
`S3_BUCKET`, `S3_PREFIX`, region/endpoint details, and credentials that allow `PutObject`, `GetObject`, and `ListBucket`.
We keep the client layer generic by leaning on the AWS CLI, letting operators point the image at AWS S3, MinIO, Ceph RGW,
DigitalOcean Spaces, or any other S3-compatible API by adjusting `S3_ENDPOINT`.

## Consequences
- Backups inherit the scalability, lifecycle management, and durability guarantees of the chosen S3 provider.
- Operators must provision credentials and network access that let the container reach the object store; missing or
  mis-scoped keys will cause backups to fail fast.
- We avoid baking provider-specific SDKs into the image, keeping our surface area small, but we accept that S3 APIs remain
  the lowest common denominator—provider features beyond the API (e.g., Azure Blob tiers) are out of scope.
- Testing and documentation must continue to highlight credential requirements and the optional endpoint override so teams
  know how to target non-AWS providers.

## References
- `README.md` usage section describing S3 configuration variables.
- `src/backup.sh` which implements uploads via the AWS CLI.
