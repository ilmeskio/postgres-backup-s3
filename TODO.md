# Next Milestone

- [ ] Publish the freshly tagged images to our registry and verify another project can pull them. This includes auditing the GitHub Actions secrets, wiring in the registry credentials, and dry-running the release workflow before we announce availability.
  - [x] Populate `DOCKERHUB_USERNAME` in the repository secrets (`gh secret set DOCKERHUB_USERNAME` or via the web UI).
  - [x] Populate `DOCKERHUB_TOKEN` with a Docker Hub access token that can push `ilmeskio/postgres-backup-s3`.
  - [x] Trigger the **Publish Images** workflow with a disposable `version_tag` to confirm the credentials succeed before tagging a release.
