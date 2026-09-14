# Permissions & Access

JamfReports only reads from Jamf. This page lists what each kind of connection needs,
report area by report area, and how to create each credential with no more access than
that.

## Which connection you need

| Connection | Reaches | Credential comes from | Access is limited by |
|---|---|---|---|
| Jamf Pro, direct | One Jamf Pro instance's Jamf Pro API and Classic API. The only choice for an on-premises server. | Jamf Pro: **Settings > System > API roles and clients** | The privileges on the client's API role |
| Jamf Platform API | Through Jamf's gateway: the Jamf Pro and Classic APIs of the Jamf Pro tenant in the integration's environment, plus Compliance Benchmarks, blueprint status and DDM status | Jamf Account: **Integrations** | The integration's scope level and permissions |
| Jamf Protect | Protect overview, alerts, computers, insights and plans | Jamf Protect console: **API Clients** | The role assigned to the API client |
| Jamf School | School overview, devices, device groups, users, classes, apps, profiles, locations, iBeacons and DEP devices | Jamf School console: **Organization > Settings > API** | The API methods allowed for the key |

A Platform API profile does not need a second, direct Jamf Pro connection when its
environment includes your Jamf Pro tenant: the gateway serves the Jamf Pro API itself.
Jamf Protect and Jamf School are always separate connections with their own credentials,
added at onboarding's **Add products** step or later from **Data Sources**.

## Rules for every connection

- **Read only.** Nothing in JamfReports creates, changes or deletes anything in Jamf. Never
  add a create, update, delete, execute or destructive permission to make a report section
  fill in.
- **One credential per purpose.** Don't reuse an administrator's client or an integration
  built for another tool, and don't share a credential between people. See
  [Multi-Tenant and Team Access](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations#multi-tenant-and-team-access).
- **Leave the few sections that want more than read empty.** The `overview` source reads
  local administrator password (LAPS) settings, which Jamf Pro guards with *Update Local
  Admin Password Settings* (*Device secrets > Local Admin Passwords (LAPS): Update* in Jamf
  Account). Without it those lines read N/A and the rest of the overview still lands.

## Create a Jamf Platform API integration

These steps follow Jamf's
[Getting started with Platform API](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api)
guide.

1. Sign in to [Jamf Account](https://account.jamf.com) with the **Administrator** role, or a
   custom role with **Integrations** privileges.
2. Choose **Integrations**, then **Create integration**. Name it for its purpose, for
   example "JamfReports — production (read only)".
3. Set the scope level to **Platform environment**. See [Scope levels](#scope-levels).
4. Select **only** the environment that holds the Jamf Pro instance this profile reports on.
   A Jamf Account can list test, production, beta and other environments, and one
   integration can apply to several of them. Each JamfReports profile reports on one
   environment, so every extra one only widens what a leaked secret could reach.
5. Grant **Read** for the report areas you want, from
   [Permissions by report area](#permissions-by-report-area). Nothing else.
6. Save, then copy the client ID and client secret. Jamf shows the secret once;
   regenerating it is the only way to get a new one.
7. Copy the environment ID: open the integration and click the environment pill in its
   **Integration details** panel. It is not the tenant ID and not the client ID.
8. Note the date. Integrations are valid for six months.

Then connect it in the app, at onboarding's **Authenticate** step or with **Data Sources →
Connection health → Update credentials…** for an existing profile:

- **Gateway URL:** `https://us.api.jamfcloud.com`, `https://eu.api.jamfcloud.com` or
  `https://apac.api.jamfcloud.com`, matching your region.
- **Scope:** Environment, with the environment ID from step 7.
- **Client ID** and **client secret** from step 6.

The app's Platform form still says "account.jamf.com → API Clients"; in Jamf Account the
page is **Integrations**.

## Check the scope ID

Saving a profile and onboarding's **Validate** step both leave the scope ID unchecked —
neither sends it — so a mistyped ID is saved without complaint and then fails every
collect. Check it once after setup:

```bash
jamf-cli -p <profile> pro jamf-pro-version list --output json | head -c 300
```

The request needs no permission, so the answer is about the ID and credentials alone:

| Result | Meaning |
|---|---|
| A `version` value | The ID is accepted and a Jamf Pro tenant answered. |
| Exit 4, `resource not found (HTTP 404)` | The gateway does not know this environment ID. The usual cause is a tenant ID pasted into the environment field. If the ID is right, confirm the environment includes your Jamf Pro instance. |
| Exit 5, message contains `OWNERSHIP_FORBIDDEN` | The ID is the wrong kind for the integration's scope level, or belongs to another organization. |
| Exit 3 | The credentials were refused. Check the client ID and secret. |

On a direct Jamf Pro profile the same command is a quick connection test.

## Scope levels

A Jamf Account integration is created at one level, and its credential works with that
level alone.

| Level | In the app | What JamfReports can collect |
|---|---|---|
| **Platform environment** (use this) | Scope: Environment, with the environment ID | The Jamf Pro and Classic API sources of the environment's Jamf Pro tenant, plus Compliance Benchmarks, blueprint status and DDM status |
| **Tenant** (legacy) | Scope: Tenant (legacy), with the tenant ID | The Jamf Pro and Classic API sources of that one tenant. Compliance Benchmarks, blueprint status and DDM status declare environment scope and may not answer; a 400 or 403 naming the scope level is the sign to create an environment-level integration. |
| **Organization** | Scope: Organization, no ID | Nothing. This level reaches Jamf Account administration only. |

## Permissions by report area

Every permission below is **Read**. Jamf Pro privilege names are as the API role editor
lists them in Jamf Pro 11.32; Jamf's
[Classic API privilege reference](https://developer.jamf.com/jamf-pro/docs/classic-api-minimum-required-privileges-and-endpoint-mapping)
uses older names for a few (for example *Mobile Device Configuration Profiles* for *iOS
Configuration Profiles*). Jamf Account permissions are written as *Section > Permission*,
the way its permission picker shows them. The data source names are the ones Run History
and the health strip use.

| Report area | Data sources | Jamf Pro API role (direct) | Jamf Account integration (Platform API) |
|---|---|---|---|
| Fleet inventory and security | `security`, `inventory-summary`, `device-compliance`, `computers`, `software-installs`, `duplicate-serials` | Read Computers | Inventory > Devices |
| Mobile devices | `mobile-devices-list`, `mobile-device-inventory-details` | Read Mobile Devices | Inventory > Devices |
| Patch management | `patch-status`, `patch-device-failures`, `patch-release-dates` | Read Patch Management Software Titles; Read Patch Policies | App lifecycle management > Patch titles; App lifecycle management > Patch policies |
| Software updates | `update-status`, `update-device-failures` | Read Managed Software Updates; Read Computers; Read Mobile Devices | Deployment > Software updates; Inventory > Devices |
| Policies | `policy-status`, `policies` | Read Policies; Read Computers | Deployment > Policies; Inventory > Device history; Inventory > Devices |
| Configuration profiles and apps | `profile-status`, `app-status`, `classic-macos-profiles`, `classic-ios-profiles` | Read macOS Configuration Profiles; Read iOS Configuration Profiles; Read Mac Applications; Read Mobile Device Applications; View MDM command information in Jamf Pro API; Read Computers; Read Mobile Devices | Deployment > Configuration profiles; App lifecycle management > Apps; Device actions > Device actions; Inventory > Devices |
| Extension attributes and mSCP compliance bands | `computer-extension-attributes`, `ea-results` | Read Computer Extension Attributes; Read Computers | Inventory > Device extension attributes; Inventory > Devices |
| Groups, searches and organization | `groups`, `smart-computer-groups`, `classic-computer-groups`, `classic-mobile-device-groups`, `advanced-mobile-device-searches`, `sites`, `buildings`, `departments`, `categories`, `scripts`, `packages`, `device-enrollment-instances` | Read Smart Computer Groups; Read Static Computer Groups; Read Smart Mobile Device Groups; Read Static Mobile Device Groups; Read Advanced Mobile Device Searches; Read Sites; Read Buildings; Read Departments; Read Categories; Read Self Service; Read Scripts; Read Packages; Read Device Enrollment Program Instances | Inventory > Device groups; Inventory > Advanced device searches; Organizational context > Sites; Organizational context > Buildings; Organizational context > Departments; Organizational context > Categories; Global settings > Self Service configuration; Deployment > Scripts; Deployment > Packages; Infrastructure > Automated Device Enrollment connection |
| DDM and MDM command health (weekly device scan) | `ddm-device-status`, `mdm-command-health` | Read Computers; Read Mobile Devices | Inventory > Devices; Inventory > Device history |
| Health Audit | `audit` | Read Policies; Read Categories; Read Self Service; Read Smart Computer Groups; Read Static Computer Groups; Read Device Enrollment Program Instances; Read Computer PreStage Enrollments; View MDM command information in Jamf Pro API; Read Computers | Deployment > Policies; Organizational context > Categories; Global settings > Self Service configuration; Inventory > Device groups; Infrastructure > Automated Device Enrollment connection; Enrollment > PreStage enrollments; Device actions > Device actions; Inventory > Devices |
| Group hygiene (Health Audit, on demand) | `group-tools-analyze` | Read Smart Computer Groups; Read Static Computer Groups; Read Policies; Read macOS Configuration Profiles; Read Patch Policies; Read Patch Management Software Titles; Read Restricted Software; Read eBooks; Read Computer PreStage Enrollments | Inventory > Device groups; Deployment > Policies; Deployment > Configuration profiles; App lifecycle management > Patch policies; App lifecycle management > Restricted software; App lifecycle management > eBooks; Enrollment > PreStage enrollments |
| Device lookup (live, not stored) | — | Read Computers; View MDM command information in Jamf Pro API | Inventory > Devices; Inventory > Device history; Device actions > Device actions |
| Compliance Benchmarks, blueprint status, DDM status | `compliance-devices`, `compliance-rules`, `blueprint-status`, `ddm-status` | Not available on a direct connection | Compliance > Compliance Benchmarks; Deployment > Blueprints; Deployment > Declarations reporting; Inventory > Devices — environment level only |

Why *Read Self Service* is on the list: Jamf Pro requires it, alongside *Read Categories*,
to list categories.

**The `overview` source** checks about 40 settings and inventory objects in one pass. It
shows N/A for any line the credential cannot read and keeps the rest. The areas above cover
its main lines; grant more only to fill a specific line you need.

**Backups** (optional) read every object type they export. A type the credential cannot
read is listed in the backup's `_failures` file and the rest is kept, so a read-limited
credential produces a partial backup rather than none.

## Jamf Protect and Jamf School

**Jamf Protect.** Create an API client under **API Clients** in the Jamf Protect console and
assign it the most restrictive role that can read computers, alerts, insights and plans.
Jamf's current documentation places the page at **Administrative > API Clients** and offers
the **Read Only** role or a custom role; the app's form and jamf-cli's setup guide still say
**Settings > API Clients**. Connect it with the Protect URL, client ID and client secret.

**Jamf School.** Generate an API key at **Organization > Settings > API**, and find the
Network ID at **Devices > Enroll Device(s)**. Each School API key is limited to the API
methods chosen for it: allow only what the School data sources above need, and nothing that
changes data. Connect it from **Connect Jamf School** on the Welcome screen, from **Add
products**, or from **Data Sources**.

## Reading a permission error

A 403 exits 5, and jamf-cli's hint names what was missing in the vocabulary of the
connection that refused it:

| Connection | The hint looks like | Grant it in |
|---|---|---|
| Jamf Pro, direct | `Required privilege(s): Read Scripts` | Jamf Pro, on the client's API role |
| Jamf Platform API | `grant the Jamf Platform API integration these permissions in Jamf Account: Deployment > Scripts: Read (scripts:read)` … | Jamf Account, on the integration |

Search Jamf Account's permission picker by section and name; it does not show the slug in
parentheses. When jamf-cli has no record of the requirement, the hint only says the API role
or integration lacks a permission — use the table above.

Some 403s are not about permissions:

- **`OWNERSHIP_FORBIDDEN`** — the scope ID does not match the integration's level. See
  [Check the scope ID](#check-the-scope-id).
- **`request blocked at the Jamf gateway edge (HTTP 403)`** — the gateway's CDN refused the
  request before it reached Jamf. No grant helps; retry later, and report it to Jamf Support
  if it persists.
- **A note that the gateway does not serve the endpoint, or exit 8** — the command is
  outside what a Platform API profile can reach. Use a direct Jamf Pro profile for it.

In the app, Run History shows jamf-cli's error message but not its hint, and the app's own
explanation of exit 5 always points at the Jamf Pro API role. To read the hint, run the
failing command in Terminal and keep the output short:

```bash
jamf-cli -p <profile> pro scripts list --output json | head -c 1500
```

## Shared workspaces

Every Mac collecting into a shared workspace must have a jamf-cli profile with the name the
workspace's `config.yaml` uses, connected the same way. See
[Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations#shared-workspace-several-macs-one-history).

## Known gaps

The app's Platform API setup text, its advice for permission errors, Compliance Benchmarks
collection and its HTML reports have known gaps; see
[Known Issues](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations#known-issues).
