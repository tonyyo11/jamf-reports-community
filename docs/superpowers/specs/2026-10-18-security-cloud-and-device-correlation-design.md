# Security Cloud and device correlation — design

Status: shipped in three steps (epic #283). First `DeviceCorrelation` and the Protect screen's
"Jamf Pro match" card. Then, as the environment spec's P12 slices 1 and 2 (2.12): an existing
Security Cloud login attached as `profiles.security_cloud`, the `security-risk` collect with
rows reduced to eight scalar keys before disk, and the summary's `securityCloudDeviceCount`,
`securityCloudMatched` and `securityCloudRiskCounts`. The match is by UDID against Jamf Pro
computers and mobile devices (`externalId` is the Jamf Pro UDID lowercased, seen on an NFR
tenant); a Jamf School environment gets no match, because School devices reach Security Cloud
by management ID (below) and the reduced rows keep none. Not built: the gateway kinds, the
Security Cloud screen, the risk pill, the workbook and HTML sections and the score factor.

## What shipped

`DeviceCorrelation` joins a row from one product to a Jamf Pro computer by identifier. It uses
the Devices rule: a row joins a record when they share an identifier and no identifier both
carry differs; a name never decides. An identifier on more than 50 records is a placeholder and
joins nothing. Several fits is "ambiguous" and is not counted. Protect's `uuid` is taken to be
Jamf Pro's `udid` and `serial` is the serial. The UUID match held on one Mac in a Jamf demo
environment (see below); it is not checked on physical Macs.
The Protect screen shows how many Protect computers match, which do not, and which Jamf Pro
Macs have no Protect record.

## jamf-cli 1.31.1 surface

- `security setup` takes a separate Radar app ID and secret for each API (Risk, Device
  Lifecycle, SSE). There is no tenant URL.
- The gateway commands `dns`, `ztna`, `uem` and `device-groups` take Platform credentials plus
  `--tenant-id` or `--environment-id`.
- `security risk list` has `--external-id` and `--guid` filters. Its help documents no output
  fields.

## To settle against a tenant

Answered on the NFR tenant (2026-11-11, P12 slice 2): a risk row's fields (the eight
`reducingSecurityRisk` keeps are listed in CLAUDE.md) and `externalId`, which is the Jamf Pro
computer UDID lowercased. The rest of this list is still open.

- The fields of a risk row.
- What `externalId` and `guid` refer to (a Jamf Pro ID, a UDID, a serial, a Security Cloud ID).
- Pagination.
- Exit codes when a credential pair is missing.
- Whether an environment-level Platform profile reaches `/securitycloud`.
- Whether Protect's `uuid` equals Jamf Pro's `udid` on a physical Mac (seen on a virtual Mac only).
- Whether `externalId` and `guid` on a risk row are the UDID, the Security Cloud GUID or a Jamf Pro ID.
- Which levels the Create integration form offers (only "Platform environment" was seen).

## What a demo environment showed (2026-10-18)

A review of screenshots and exports from two Jamf demo environments, one commercial (Jamf Pro,
Protect, Security Cloud, Manager for Android, Elevate) and one education (Jamf School, Security
Cloud, Protect). Values below are shapes only. Read-only visitor accounts, one anchor Mac per
environment, so every "confirmed" is for that one device.

### Identity keys

| Product | Device key | Shape |
|---|---|---|
| Jamf Pro | `udid` | uppercase UUID |
| Jamf Pro | management ID | lowercase UUID |
| Protect | "Device ID" (alerts: "Computer UUID") | lowercase UUID |
| Security Cloud | "Unique ID" | lowercase UUID |
| Security Cloud | GUID | its own lowercase UUID; matched nothing else |
| Jamf School | `DeviceUDID` | uppercase UUID (Mac), `8hex-16hex` (iOS) |
| Jamf School | `ManagementID` | lowercase UUID |

- Confirmed on the commercial anchor Mac: Jamf Pro `udid` lowercased equals Protect "Device ID"
  and Security Cloud "Unique ID". Case-fold every identifier before comparing.
  `DeviceInventoryRecord.identifier(_:)` already trims and lowercases, so no code change.
- Confirmed in the education environment: Security Cloud's user field is
  `uem_<customerId>_<School management ID>`. The suffix equals the School management ID for
  every Mac checked. The School `DeviceUDID` and serial do not appear in Security Cloud at all.
  A School join therefore keys on management ID, which `DeviceCorrelation` already carries as an
  identifier; the Security Cloud reader must split that string.
- Serial is not safe: Protect and Jamf Pro both hold blank serials on virtual Macs and on some
  physical ones, and Protect has records with no serial and a UUID for a name.
- Names and hostnames never decide a join. Names repeat (the same display name on several
  records, the same person on several Security Cloud rows) and one Pro export family carries
  only names to link its two halves.
- Plan change: the correlation keys are `udid` and management ID, plus serial as the weak
  fallback `DeviceIdentifier` already ranks. Nothing keys on name, hostname or user.

### Security risk without a tenant

Jamf Pro stores the Security Cloud device risk in a computer extension attribute named
`wandera_device_risk` (value seen: `HIGH`, matching the "High" pill in Security Cloud). That is
available today from `ea-results`, with no Security Cloud credential.

- Plan change: ship the risk pill and filter from this EA first. Adopt it through Adopt EAs
  (custom EA, text tab); no new collect kind.
- The `security-risk` collect kind stays planned, but is no longer on the critical path.
- The EA value is Security Cloud's own enum (Secured, Low, Medium, High were seen in Security
  Cloud). Show the text as written; do not map it to a number.

### One environment, several product tenants

One Jamf Account platform environment holds the Pro, Protect, Security Cloud and Manager for
Android tenants, each with its own tenant ID, and the environment has a separate ID again. This
fits one jamf-cli profile per environment.

- Plan change: the `Connection` record lists the products found in the environment (Pro,
  Protect, Security Cloud, School, Android), not only the profile. The Security Cloud gateway
  commands then use the same environment profile as Protect.
- In the education environment the Security Cloud tenant was not in the environment: it sat in
  "unassigned tenants". An environment-level credential would reach School only. The Security
  Cloud screen must say "not part of this environment" rather than "no data".
- Platform API clients were seen at the "Platform environment" level only; organization and
  tenant levels were not shown. No Platform permission is named for Security Cloud or Protect
  device risk (device listing is the single "Inventory > Devices" permission), so a read-only
  credential cannot be scoped to risk data from that catalog.
- UEM Connect links Security Cloud to the MDM. On the Jamf Pro side it is an API client with a
  dedicated role. On the School side it is a School API key. Sync counts (synced, removed,
  errored) show in Security Cloud only.

### Out of scope

- Elevate has its own device set (separate fleet, no join to Jamf Pro). Its only device keys
  are serial and uppercase UDID. Not planned.
- AI Visibility identifies devices by hostname only and shows aggregates (counts per product,
  launcher and command). There is no device record to join. Not planned.
- Manager for Android devices have serial, IMEI and an Android identifier, with no UDID. Not
  planned.

### Data-quality notes the app must handle

- Virtual Macs: blank serials are common. A blank is "no identifier", never a placeholder
  value. Placeholder cap (50 records) stays.
- Protect-only records: no serial, a UUID as the name, OS version `null.null.null`. Count them
  as "no identifier", not as "not in Jamf Pro".
- The Jamf Pro Insights export has one row per device and smart-group membership. Only the
  first row carries the device; the rest are blank except the group. Collapse before counting.
- The mobile Insights export has a header that is one column off from its data after the
  fifth column. Read by position with a corrected header, or do not read it. The `Device ID`
  columns in mobile exports are blank.
- The School CSV is semicolon-delimited with ISO 8601 UTC dates. Pro CSV dates have no zone.
  `1970-01-01 00:00:00` means "never".
- OS versions appear as `26.5` and `26.5.0`: normalise with `OSVersionName` before counting.
- Product counts do not reconcile (a Protect fleet larger than the Jamf Pro Macs it matches,
  duplicate per-user Security Cloud rows, a School row count that includes a placeholder).
  Show each product's own count and the match counts, never a total across products.
- Three compliance views of one Mac disagree (Protect rules, the Jamf Pro benchmark EA lists,
  and the Jamf Pro failed-count EA). The risk pill must not be blended with compliance.
- Security Cloud shows the same person on several Mac rows. A per-user count is not a
  per-device count.
- Freshness differs by source (Protect OS version and last-seen can lag Jamf Pro). Show each
  source's date.

### Not confirmed

- Security Cloud's device detail page was not captured, so GUID and Unique ID come from the
  maintainer, not from a screenshot.
- Protect "Device ID" as the UDID on a physical Mac, and School Mac UDID as Protect "Device ID".
- What a live `security risk list` row returns, and what `externalId` refers to.
- Whether the education School CLI row carries UDID and management ID.

## Planned config and collect

The config is the environment spec's `profiles.security_cloud` slot (its section 3.1), pinned
like `profiles.platform`. The `security:` block first planned here was never added:

```yaml
security:        # not read; replaced by profiles.security_cloud
  enabled: false
  profile: ""
```

`security-risk` shipped as planned (refresh tier, `security risk list`). The gateway kinds
below are the P12 gateway half and are not built.

Collect kinds: `security-risk` (refresh tier); `security-device-groups`, `security-dns`,
`security-ztna-apps`, `security-ztna-gateways`, `security-uem-connectors` (inventory tier).
The allow-list is fixed and read-only. The app never runs risk override, device-lifecycle
purge, stream, status update, verification trigger or any gateway write. A 404 lands an empty
snapshot; a 429 is a rate limit, not a failure of the data.

## Correlation sources to add

Each joins the same way and is added with its first caller, not before.

| Source | First caller |
|---|---|
| `mobile-devices-list` | risk pill on Mobile Fleet |
| School devices | none: a UDID or serial join would read near 0 of N, and the management-ID join needs the `uem_` user field the reduced rows drop (a decision for Tony) |
| `platform-devices` | none planned |

## Surfaces

- A risk pill and filter on Computers, first from the `wandera_device_risk` EA (no tenant
  needed; seen on a computer record only), later from `security-risk`, which also feeds Mobile Fleet.
- A Security Cloud screen.
- A workbook sheet and an HTML report group, with counts only.
- An optional `security_cloud_risk` score factor, never in the default list.

## Redaction

- Phone numbers are redacted wherever they could appear.
- `security-risk` is treated as a device snapshot: it carries device identifiers.
- ZTNA IPsec fields are never shown.

## Out of scope

Writes of any kind to Security Cloud.
