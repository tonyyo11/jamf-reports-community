# Security Policy

Jamf Reports reads fleet data from Jamf Pro, Jamf School, and Jamf Protect, and many of the
organizations that run it treat that data as sensitive. Thank you for helping keep it safe.

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest release (2.10.x) | Yes |
| Current beta or release candidate | Yes |
| Older releases | No — please update and confirm the issue still occurs |

## Reporting a vulnerability

**Please do not open a public issue or Discussion for a security problem.**

Report it privately through GitHub:
[Report a vulnerability](https://github.com/tonyyo11/jamf-reports-community/security/advisories/new)
(the **Security** tab → **Report a vulnerability**).

Please include:

- The Jamf Reports version, macOS version, and jamf-cli version
- What an attacker could do, and what access they would need (for example, write access to a
  shared workspace folder, a local account on the same Mac, or control of a webhook endpoint)
- Steps to reproduce, or a proof of concept
- Any logs or files that show the problem, with hostnames, tenant and environment IDs, serial
  numbers, usernames, and webhook URLs removed

This is a community project maintained in spare time. You can expect an acknowledgment on a
best-effort basis, and a fix or advisory once the report has been confirmed.

## Scope

In scope:

- The Jamf Reports app and its included `jamf-reports` command-line tool
- Its background item and scheduled runs
- Generated reports (workbook, HTML, PDF, CSV) and what they contain
- Webhook notifications and what they send
- Redaction in diagnostic bundles, exported logs, and copied output
- Handling of shared or synced workspace folders

Out of scope (please report to the owner instead):

- jamf-cli itself: [Jamf-Concepts/jamf-cli](https://github.com/Jamf-Concepts/jamf-cli)
- Jamf Pro, Jamf School, Jamf Protect, or the Jamf Platform API: Jamf
- Issues that require an attacker who already has administrator access to the Mac

For how the app handles credentials, paths, and outbound data, see
[Security & Operational Considerations](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations).
