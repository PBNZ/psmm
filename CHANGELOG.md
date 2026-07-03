# Changelog

All notable changes to psmm. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [0.1.0] — Unreleased (private-testing candidate)

First release as a proper module — everything below is relative to the
original `$PROFILE` drop-in block.

### Added
- (populated as the build progresses)

### Changed
- Packaged as the `psmm` module with an explicit public surface:
  `Show-PSModuleManager` (alias `psmm`), `Invoke-PSMMStartup`,
  `Get-PSMMConfigPath`.

### Compatibility
- Existing `psmm-config.json` files work unchanged.
