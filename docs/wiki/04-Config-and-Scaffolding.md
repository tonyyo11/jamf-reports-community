# Config and Scaffolding

## Purpose

`config.yaml` is the bridge between your Jamf data shape and the generic report logic.

The Python code should stay organization-agnostic. Your environment-specific details live
in config.

## Start With Scaffold

Run:

```bash
python3 jamf-reports-community.py scaffold --csv inventory.csv
```

This creates a starter `config.yaml` by matching CSV headers to the tool's logical field
names.

## Always Review The Scaffold Output

Scaffold is a starting point, not a final answer.

Common things to review:

- `manager` should be a real manager field, not Jamf's `Managed` status
- `secure_boot` should map to the Secure Boot column, not an external boot control column
- `bootstrap_token` should usually map to the escrowed state, not merely allowed
- `disk_percent_full` should be a percentage column, not free space in MB

Use:

```bash
python3 jamf-reports-community.py check --config config.yaml --csv inventory.csv
```

## Core Sections

### `columns`

Maps logical fields to exact CSV header names.

### `security_agents`

Use this when you have EAs that describe agent state such as CrowdStrike, SentinelOne,
Splunk, or Tanium.

`connected_value` is matched as a case-insensitive substring.

### `compliance`

Use this when you have a failures count EA and a failures list EA.

The list field should be pipe-delimited.

### `custom_eas`

Use this to create extra workbook tabs without editing Python.

Supported types:

- `boolean`
- `percentage`
- `version`
- `text`
- `date`

This is one of the main extension surfaces for the community project. If you need richer
EA visualization later, start by proving the data shape in config before changing Python.

## Suggested Working Style

For each tenant or export shape:

1. Scaffold once
2. Review the column mappings
3. Add your security agents
4. Add compliance if present
5. Add custom EA sheets only where there is a reporting need
6. Reuse that config for future runs

If you start from jamf-cli instead of a Jamf export, use `inventory-csv` first so you can
still take advantage of scaffold and config review.

## Keep Config Stable

Avoid changing export headers constantly. Stable CSV shapes make reporting more reliable
and historical comparisons more useful.

If you have separate use cases, maintain separate configs rather than one overloaded file.
