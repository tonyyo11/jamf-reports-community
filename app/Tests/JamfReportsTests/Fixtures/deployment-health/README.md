# Deployment health fixtures

- `app-installers-deployments-list.json`: the keys and JSON types `pro app-installers-deployments list --output json` printed on a Jamf Cloud test server (jamf-cli 1.38.0). Names, IDs, versions and counts are made up.
- `patch-policies-list.json`: synthetic rows with the 11 keys and JSON types `pro patch-policies list --output json` printed on Jamf's public test server (jamf-cli 1.38.0), the same keys a production server returned. Includes a failing row, a disabled row and a row with nothing in scope.
- `app-installers-not-found.json`: the error envelope shape for exit 4 with the error name `not_found`, which an on-premises server (no App Installers) answers.

No value in these files comes from a production server.
