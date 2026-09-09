# OMNIX v3 Development Preview Release

This document records the automated development-preview packaging path.

The preview release workflow publishes only when all three exact-source CI gates are successful:

- `architecture-contract`
- `request-budget-runtime`
- `build`

The workflow downloads the exact `omnix-development-build` artifact, verifies the artifact manifest and installer SHA-256, then publishes a GitHub **pre-release** with the installer, checksum, and manifest attached.

## Fail-closed release boundaries

A development preview is never treated as a production release. The preview workflow requires:

- `ArtifactType = DEVELOPMENT_ONLY`
- `RequiredOfficePayloadPresent = true`
- `PrivacyGatewayRuntimePass = true`
- `OfficeMaintenanceAuditPass = true`
- `ProductionReleaseApproved = false`
- `RealOfficeRuntimeTested = false`
- exact installer hash match between the executable, `installer.sha256`, and `manifest.json`

Production remains blocked until the real Windows/Office evidence and trusted timestamped Authenticode requirements enforced by `tools/final-production-gate.ps1` are satisfied.

The release workflow uses the repository-scoped GitHub Actions token. No personal access token is stored in the repository or release workflow.
