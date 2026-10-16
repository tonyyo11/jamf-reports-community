# Permissions & Access

JamfReports only reads from Jamf. This page lists what each kind of connection needs,
report area by report area, and how to create each credential with no more access than
that.

## Which connection you need

| Connection | Reaches | Credential comes from | Access is limited by |
|---|---|---|---|
| Jamf Pro, direct | One Jamf Pro instance's Jamf Pro API and Classic API. The only choice for an on-premises server. | Jamf Pro: **Settings > System > API roles and clients** | The privileges on the client's API role |
| Jamf Platform API (recommended for Jamf Cloud) | Through Jamf's gateway: the Jamf Pro and Classic APIs of the Jamf Pro tenant in the integration's environment, plus Compliance Benchmarks, blueprint status and DDM status | Jamf Account: **Integrations** | The integration's scope level and permissions |
| Jamf Protect | Protect overview, alerts, computers, insights and plans | Jamf Protect console: **API Clients** | The role assigned to the API client |
| Jamf School | School overview, devices, device groups, users, classes, apps, profiles, locations, iBeacons and DEP devices | Jamf School console: **Organization > Settings > API** | The API methods allowed for the key |

Create the Jamf Account integration at the **environment** level. A tenant-level integration
is legacy, and an organization-level one reaches only Jamf Account, so Jamf Reports will not
set it up and a collect on one stops with a message saying so.

A Platform API profile does not need a second, direct Jamf Pro connection when its
environment includes your Jamf Pro tenant: the gateway serves the Jamf Pro API itself. This
is [jamf-cli's own recommendation](https://github.com/Jamf-Concepts/jamf-cli/wiki#getting-started) for Jamf Cloud. The gateway is
Jamf Cloud only, so an on-premises or GovCloud server keeps the direct connection. jamf-cli
refuses a few dozen Jamf Pro and Classic commands on a gateway profile (device actions among
them, exit 8); Jamf Reports runs none of them, but keep a direct profile for your own use of
those commands. Jamf Reports collects one profile per fleet: when the direct profile reaches
the same Jamf Pro as the gateway profile, setup keeps the gateway profile as the workspace
and leaves the direct one out of collects and consolidated reports (tick it to collect it
anyway; Config Doctor names a pair that already has two workspaces).
Jamf Protect is a separate connection with its own credentials, added at onboarding's
**Add products** step or later from **Data Sources**. Jamf School has its own workspace and
credentials.

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

### Before you start

- **Your Jamf Pro is hosted by Jamf Cloud.** The gateway does not reach an on-premises or
  GovCloud server; use a direct Jamf Pro connection for those.
- **Your Jamf Pro tenant is in a platform environment.** An environment is a group of
  tenants (Jamf Pro or Jamf School, and optionally Jamf Protect and Jamf Security Cloud) in
  Jamf Account. If your tenant is in no environment, contact Jamf Support.
- **The environment can be picked.** An environment you created yourself appears in the
  integration's scope picker only when Jamf can tell its region:
  - It must hold an MDM, Jamf Pro or Jamf School.
  - Every tenant in it except Jamf Security Cloud must be in the same region.
  - After creating or editing an environment, allow up to 15 minutes before it appears.

1. Sign in to [Jamf Account](https://account.jamf.com) with the **Administrator** role, or a
   custom role with **Integrations** privileges. After a custom role is assigned, sign out
   of Jamf Account and back in before it takes effect.
2. Choose **Integrations**, then **Create integration**. Name it for its purpose, for
   example "JamfReports — production (read only)".
3. Set the scope level to **Platform environment**. See [Scope levels](#scope-levels).
4. Select the environment that holds the Jamf Pro instance this profile reports on. A Jamf
   Account can list test, production, beta and other environments, and one integration can
   apply to several of them. A jamf-cli profile holds one environment ID, so reporting on
   several takes one profile per environment, each with the same client ID and secret
   (**Data Sources → Connection → Add environments**, which registers each profile and
   checks its ID). Every extra environment widens what a leaked
   secret could reach, so select only the ones you report on.
5. Grant **Read** for the report areas you want, from
   [Permissions by report area](#permissions-by-report-area). Nothing else.
6. Save, then copy the client ID and client secret. Jamf shows the secret once;
   regenerating it is the only way to get a new one.
7. Copy the environment ID: open the integration and click the environment pill in its
   **Integration details** panel. It is not the tenant ID and not the client ID.
8. Note the date. Integrations are valid for six months.

Then connect it in the app, at onboarding's **Authenticate** step or with **Data Sources →
Connection health → Update credentials…** for an existing profile. When the integration
covers several environments, **Data Sources → Connection → Add environments** adds the others
with the same client ID and secret, and **Update credentials for all** applies a rotated secret
to every profile in one step:

- **Region:** United States, Europe or Asia-Pacific, which is the gateway
  `https://us.api.jamfcloud.com`, `https://eu.api.jamfcloud.com` or
  `https://apac.api.jamfcloud.com`. Update credentials shows a stored gateway URL that is
  none of the three as **Other** and keeps it until you pick a region. Pick the region your
  environment is in: a gateway token works only in the region that issued it.
- **Scope:** Environment, with the environment ID from step 7.
- **Client ID** and **client secret** from step 6.

Environment scope needs jamf-cli 1.28 or later.

## Check the scope ID

The gateway issues a token before it reads the scope header, so a correct client ID and
secret with a mistyped environment ID still get a token. Onboarding's **Validate** step and
**Update credentials…** therefore check the ID itself, with a request that needs no
permission:

- **Accepted:** a Jamf Pro tenant answered, and setup continues.
- **Rejected:** the gateway does not know the ID, or it is the wrong kind for the
  integration's scope level. Setup stops and says where the right ID is.
- **No Jamf Pro:** the ID is valid but no Jamf Pro tenant answers behind it, including an
  environment that holds no tenant. That environment's MDM is probably Jamf School, which
  Jamf Reports reads with a School API key, so setup offers **Set up Jamf School** (or
  **Add Jamf School workspace** in the sidebar's workspace menu) and no way to continue with
  this profile. If it should be Jamf Pro, check that the ID is for the environment that
  holds your Jamf Pro tenant.
- **Missing permission:** the gateway did not reject the ID but refused the request with a
  permission error (HTTP 403). The check's own request needs no permission, and the gateway
  answers the same 403 for a request it does not route, so this points at the integration or
  the environment as a whole: the integration holds none of the Jamf Pro permissions for this
  environment, or no Jamf Pro answers behind the ID. Setup names the permission when jamf-cli does and offers
  **Continue without validating**; anything that needs the missing access will not collect.
  Grant the permissions in [Permissions by report area](#permissions-by-report-area) on the
  integration in Jamf Account and check again with **Update credentials…**. **Add
  environments** does not add an ID in this state.
- **Undecided:** the answer was not conclusive, and setup offers **Continue without
  validating**.

Profiles set up before 2.8.1 were saved without that check. To check one by hand:

```bash
jamf-cli -p <profile> pro jamf-pro-version list --output json | head -c 300
```

On jamf-cli before 1.29 the command is `pro jamf-pro-versions list`. The request needs no
permission, so the answer is about the ID and credentials alone:

| Result | Meaning |
|---|---|
| A `version` value | The ID is accepted and a Jamf Pro tenant answered. |
| Exit 4, `resource not found (HTTP 404)` | The gateway does not know this environment ID. The usual cause is a tenant ID pasted into the environment field. If the ID is right, confirm the environment includes your Jamf Pro instance. |
| Exit 5, message contains `OWNERSHIP_FORBIDDEN` | The ID is the wrong kind for the integration's scope level, or belongs to another organization. |
| Exit 5, any other message | The gateway accepted the ID but refused the request. Check that the integration has the Jamf Pro permissions in [Permissions by report area](#permissions-by-report-area), and that the ID is for the environment that holds your Jamf Pro tenant. |
| Exit 3 | The credentials were refused. Check the client ID and secret. |

On a direct Jamf Pro profile the same command is a quick connection test.

## Scope levels

A Jamf Account integration is created at one level, and its credential works with that
level alone.

| Level | In the app | What JamfReports can collect |
|---|---|---|
| **Platform environment** (use this; jamf-cli recommends it) | Scope: Environment, with the environment ID | The Jamf Pro and Classic API sources of the environment's Jamf Pro tenant, plus Compliance Benchmarks, blueprint status and DDM status |
| **Tenant** (legacy) | Scope: Tenant (legacy), with the tenant ID | The Jamf Pro and Classic API sources of that one tenant, plus DDM status. Jamf Account does not let a tenant-level integration read Compliance Benchmarks or blueprint status, so the app skips both on such a profile and says so in Run History and on the Compliance Benchmarks screen. |
| **Organization** | Not offered | Nothing. This level reaches Jamf Account administration only, so the app does not offer it. A profile that names neither an environment nor a tenant ID is listed at setup with that reason and not selected, Config Doctor fails its workspace, and a collect stops at one `[error]` line. Create an environment-level integration instead. |

## Permissions by report area

Every permission below is **Read**. Jamf Pro privilege names are as the API role editor
lists them in Jamf Pro 11.32; Jamf's
[Classic API privilege reference](https://developer.jamf.com/jamf-pro/docs/classic-api-minimum-required-privileges-and-endpoint-mapping)
uses older names for a few (for example *Mobile Device Configuration Profiles* for *iOS
Configuration Profiles*). Jamf Account permissions are written as *Section > Permission*,
the names Jamf's
[permissions map](https://developer.jamf.com/platform-api/reference/jamf-pro-permissions-map)
uses (updated 2026-09-03), which the permission picker follows; the map also gives each one's
slug, such as `devices:read`, which jamf-cli's 403 hint shows in parentheses. The data source
names are the ones Run History and the health strip use.

| Report area | Data sources | Jamf Pro API role (direct) | Jamf Account integration (Platform API) |
|---|---|---|---|
| Fleet inventory and security | `security`, `inventory-summary`, `device-compliance`, `computers`, `software-installs`, `duplicate-serials` | Read Computers | Inventory > Devices |
| Mobile devices | `mobile-devices-list` | Read Mobile Devices | Inventory > Devices |
| Patch management | `patch-status`, `patch-device-failures`, `patch-release-dates` | Read Patch Management Software Titles; Read Patch Policies; Read Computers; Read Mobile Devices | App lifecycle management > Patch titles; App lifecycle management > Patch policies; Inventory > Devices |
| Software updates | `update-status`, `update-device-failures` | Read Managed Software Updates; Read Computers; Read Mobile Devices | Deployment > Software updates; Inventory > Devices |
| Policies | `policy-status`, `policies` | Read Policies | Deployment > Policies |
| Configuration profiles and apps | `profile-status`, `app-status`, `classic-macos-profiles`, `classic-ios-profiles` | Read macOS Configuration Profiles; Read iOS Configuration Profiles; Read Mac Applications; Read Mobile Device Applications; View MDM command information in Jamf Pro API; Read Computers; Read Mobile Devices | Deployment > Configuration profiles; App lifecycle management > Apps; Device actions > Device actions; Inventory > Devices |
| Extension attributes and mSCP compliance bands | `computer-extension-attributes`, `ea-results` | Read Computer Extension Attributes; Read Computers | Inventory > Device extension attributes; Inventory > Devices |
| Groups, searches and organization | `groups`, `smart-computer-groups`, `classic-computer-groups`, `classic-mobile-device-groups`, `advanced-mobile-device-searches`, `sites`, `buildings`, `departments`, `categories`, `scripts`, `packages`, `device-enrollment-instances` | Read Smart Computer Groups; Read Static Computer Groups; Read Smart Mobile Device Groups; Read Static Mobile Device Groups; Read Advanced Mobile Device Searches; Read Sites; Read Buildings; Read Departments; Read Categories; Read Self Service; Read Scripts; Read Packages; Read Device Enrollment Program Instances | Inventory > Device groups; Inventory > Advanced device searches; Organizational context > Sites; Organizational context > Buildings; Organizational context > Departments; Organizational context > Categories; Global settings > Self Service configuration; Deployment > Scripts; Deployment > Packages; Infrastructure > Automated Device Enrollment connection |
| DDM and MDM command health (weekly device scan) | `ddm-device-status`, `mdm-command-health` | Read Computers; Read Mobile Devices | Inventory > Devices; Inventory > Device history |
| Health Audit | `audit` | Read Policies; Read Categories; Read Self Service; Read Smart Computer Groups; Read Static Computer Groups; Read Device Enrollment Program Instances; Read Computer PreStage Enrollments; View MDM command information in Jamf Pro API; Read Computers | Deployment > Policies; Organizational context > Categories; Global settings > Self Service configuration; Inventory > Device groups; Infrastructure > Automated Device Enrollment connection; Enrollment > PreStage enrollments; Device actions > Device actions; Inventory > Devices; for its platform checks, Deployment > Blueprints; Compliance > Compliance Benchmarks; Deployment > Declarations reporting |
| Group hygiene (Health Audit, on demand) | `group-tools-analyze` | Read Smart Computer Groups; Read Static Computer Groups; Read Policies; Read macOS Configuration Profiles; Read Patch Policies; Read Patch Management Software Titles; Read Restricted Software; Read eBooks; Read Computer PreStage Enrollments | Inventory > Device groups; Deployment > Policies; Deployment > Configuration profiles; App lifecycle management > Patch policies; App lifecycle management > Patch titles; App lifecycle management > Restricted software; App lifecycle management > eBooks; Enrollment > PreStage enrollments |
| Device lookup (live, not stored) | — | Read Computers; View MDM command information in Jamf Pro API | Inventory > Devices; Inventory > Device history; Device actions > Device actions |
| Compliance Benchmarks, blueprint status, DDM status | `compliance-devices`, `compliance-rules`, `blueprint-status`, `ddm-status` | Not available on a direct connection | Compliance > Compliance Benchmarks (`compliance-benchmarks:read`); Deployment > Blueprints (`blueprints:read`, see below); Deployment > Declarations reporting (`declarations:read`); Inventory > Devices (`devices:read`) — environment level (DDM status also answers at tenant level) |

Why *Read Self Service* is on the list: Jamf Pro requires it, alongside *Read Categories*,
to list categories. Patch management reads computers and mobile devices only to fill the
serial, OS and user columns of failing devices; without them those columns are blank.

**Blueprints.** The Blueprints API reference requires `blueprints:read` for blueprint status,
and Jamf's permissions map files it as *Deployment > Blueprints*. In October 2026 a user found
no Blueprints entry in an environment-level integration's picker
([#288](https://github.com/tonyyo11/jamf-reports-community/issues/288)). If yours has none,
leave it out: only the `blueprint-status` source fails, Run History names `blueprints:read`,
and every other source still collects. The Health Audit skips its blueprint checks, and DDM
status and Group hygiene read blueprints only to name them or to count a group a blueprint
uses, so they carry on without it. Group hygiene can then list a group that only a blueprint
or benchmark uses as unused.

**The `overview` source** checks about 40 settings and inventory objects in one pass. It
shows N/A for any line the credential cannot read and keeps the rest. The areas above cover
its main lines; grant more only to fill a specific line you need.

**jamf-cli's dashboard** (jamf-cli 1.31.0 or later, for the HTML report) reads the same
inventory, groups, patch titles and audit checks as the areas above and, on a Platform API
profile, blueprints and benchmarks. A section the credential cannot read is left out of the
page, which says so at the top; the rest of the page still lands.

**Backups** (optional) read every object type they export. A type the credential cannot
read is listed in the backup's `_failures` file and the rest is kept, so a read-limited
credential produces a partial backup rather than none.

## Jamf Protect and Jamf School

**Jamf Protect.** Create an API client under **API Clients** in the Jamf Protect console and
assign it the most restrictive role that can read computers, alerts, insights and plans.
Jamf's current documentation and the app's form place the page at **Administrative > API
Clients**, with the **Read Only** role or a custom role; jamf-cli's setup guide still says
**Settings > API Clients**. Connect it with the Protect URL, client ID and client secret. It
is not covered by your Jamf Account integration. **Data Sources > Additional Products >
Disconnect** turns Protect off in the workspace and leaves the jamf-cli profile, which
`jamf-cli config remove-profile <name>` removes.

**Jamf School.** Generate an API key at **Organization > Settings > API**, and find the
Network ID at **Devices > Enroll Device(s)**. Each School API key is limited to the API
methods chosen for it: allow only what the School data sources above need, and nothing that
changes data. Connect it from **Connect Jamf School** on the Welcome screen.

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
- **A 403 on one Jamf Pro source that stays after you grant the permission it names** — Jamf's
  [Platform API fundamentals](https://developer.jamf.com/platform-api/reference/platform-api-fundamentals#scope-levels)
  says an environment-level token carries no tenant ID, so a Jamf Pro endpoint that reads its
  context from one answers 403 and needs a tenant-level integration. Jamf does not list which
  endpoints those are.

In the app, the health strip and Run History's warning line name the cause and carry
jamf-cli's hint, and the explanation of exit 5 names both the Jamf Pro API role and the Jamf
Account integration. A source that fails for a missing permission or a rejected ID is not
retried every hour: fix the grant, then choose **Collect now**. To see the full output, run
the failing command in Terminal and keep it short:

```bash
jamf-cli -p <profile> pro scripts list --output json | head -c 1500
```

## Shared workspaces

Every Mac collecting into a shared workspace must have a jamf-cli profile with the name the
workspace's `config.yaml` uses, connected the same way. See
[Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations#shared-workspace-several-macs-one-history).

## Moving an existing integration

If scripts or other tools already reach Jamf Pro with an API client, Jamf recommends moving
them to the gateway; its
[Getting started](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api)
guide links the steps. The Jamf Pro and Classic APIs keep working without it. An integration
made during the Platform API beta does not move: the beta gateway is retired and its
credentials are revoked, so create a new integration. To change an integration's
environments or permissions later, see Jamf Account's
[Creating or Editing Integrations](https://learn.jamf.com/r/en-US/jamf-account-documentation/Creating_or_Editing_Integrations);
the secret is not shown again after an edit. Jamf Account names permissions by capability;
Jamf's permissions map lists the Jamf Pro privilege each one replaces, and [Permissions by report area](#permissions-by-report-area)
gives both for every source the app collects.

## Further reading

- [Getting started with Platform API](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api):
  integrations, scope levels, regions and tokens.
- [Platform API fundamentals](https://developer.jamf.com/platform-api/reference/platform-api-fundamentals):
  scope levels, capability permissions and how to read a 403.
- [Jamf Pro permissions map](https://developer.jamf.com/platform-api/reference/jamf-pro-permissions-map):
  every capability, its section in Jamf Account, and the Jamf Pro privilege it replaces.
- [Platform API reference](https://developer.jamf.com/platform-api/): every endpoint and the
  permission it needs.
- [Jamf Pro 11.32.0 release notes: Platform APIs and Platform API Gateway general availability](https://learn.jamf.com/r/en-US/jamf-pro-release-notes-11.32.0/Platform_APIs_and_Platform_API_Gateway_General_Availability).
- [Jamf Platform services and capabilities](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Jamf_Platform_Services_and_Capabilities):
  Blueprints, Compliance Benchmarks, AI Governance and the Platform APIs.
- [Jamf Pro API developer resources](https://developer.jamf.com/jamf-pro/docs/jamf-pro-api-developer-resources):
  API clients and roles, privileges, Swagger and Postman.
- [jamf-cli wiki](https://github.com/Jamf-Concepts/jamf-cli/wiki#getting-started): profiles,
  scope levels and commands.

## Known gaps

The HTML report has no Platform API sections yet. Compliance Benchmarks, blueprint status
and DDM status appear on the app's screens and in the workbook's Compliance Rules,
Compliance Devices, Blueprint Status and DDM Status sheets.
