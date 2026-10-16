# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0] - 2026-10-16
### Added
- A "Migrate SFTP settings to file transports" button on the configuration page. It creates one Koha file transport per distinct SFTP connection, points the jobs at it and saves the configuration.
- The configuration is checked when it is saved. Invalid YAML, an output that is not a patron import column, a transformer that is not defined in koha-conf.xml, a file transport, patron category or library that does not exist, a column name that is not in the configured header and other mistakes are listed with their line numbers, and the configuration is only stored once they are fixed or "Save anyway" is ticked.
- The nightly run lists the same configuration problems at the top of its output before importing.

## [0.0.1] - 2022-12-02
### Added
- Initial commit!
