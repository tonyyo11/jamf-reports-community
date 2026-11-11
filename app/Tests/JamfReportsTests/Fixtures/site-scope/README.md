# site-scope fixtures

Captured 2026-11-11 from a Jamf Pro 11.33.3 test server with jamf-cli 1.36.0, reduced to the
keys `SiteScope` reads. Two sites; 2 managed Macs and 1 managed iPad on the server.

- `limited-*`: a Jamf Pro user account with Site Access to one site (Auditor), through a
  `--auth-method token` profile. `pro overview` Fleet rows stay server-wide (2 computers,
  1 mobile device); the lists hold only that site's devices (1 computer, 0 mobile devices).
- `whole-*`: the same server through an OAuth2 API client (every site).
- `config-list-token.json`: the shape `config list -o json` prints for a token profile
  (name and URL replaced).

No names, serials, UDIDs or hosts.
