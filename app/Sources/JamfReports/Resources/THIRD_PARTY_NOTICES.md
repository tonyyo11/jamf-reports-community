# Third-Party Notices

This project incorporates or invokes the following third-party software.
Each item is listed with its license, project URL, and how it is used by
this project. License text for each component is reproduced or linked
below.

---

## Bundled in the macOS app

### ZIPFoundation

- Project: https://github.com/weichsel/ZIPFoundation
- License: MIT
- Used for: pure-Swift ZIP creation for the OOXML (`.xlsx`) writer.

### swift-argument-parser

- Project: https://github.com/apple/swift-argument-parser
- Version: 1.8.2 (pinned in `app/Package.resolved`)
- License: Apache License 2.0 with Runtime Library Exception. The license text
  is at
  https://github.com/apple/swift-argument-parser/blob/1.8.2/LICENSE.txt
- Used for: parsing the arguments of the included `jamf-reports` command-line
  interface.

### IBM Plex Mono

- Project: https://github.com/IBM/plex
- Copyright: Copyright 2017 IBM Corp. All rights reserved. (as recorded in the
  font files)
- License: SIL Open Font License, Version 1.1. The full text is reproduced
  below, as the license requires for redistributed copies of the fonts.
- Used for: the app's monospaced text. The four font files (Regular, Medium,
  SemiBold, Bold) are bundled unmodified from `Resources/Fonts/`.

```
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

---

## Invoked as an external subprocess (not bundled)

### jamf-cli

- Project: https://github.com/jamf/jamf-cli
- Publisher: Jamf Software, LLC
- License: Apache License 2.0
- Used for: querying Jamf Pro, the Jamf Platform API, Jamf Protect and Jamf
  School. The binary is installed separately by the end user, from Jamf's
  package or from Homebrew, and is invoked by this project as a subprocess. It
  is not bundled, modified, or redistributed.

See `NOTICE.md` for the trademark notice covering "jamf-cli" and related
marks owned by Jamf Software, LLC.

---

## Build-time dependencies (not redistributed)

The release pipeline uses the following Apple-provided tools, which are
not part of the distributed artifact:

- `codesign`, `productsign`, `pkgbuild`, `productbuild`, `hdiutil`,
  `xcrun notarytool`, `xcrun stapler` — bundled with macOS and Xcode
  Command Line Tools.
