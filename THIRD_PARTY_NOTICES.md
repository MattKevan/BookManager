# Third-party notices

Unless a file or directory says otherwise, Stacks's original source code
is licensed under the MIT License. The MIT licence text is in `LICENSE`.

The following third-party components are included in the source tree or in the
application build. Their licences remain separate from Stacks's licence.

## Automerge Swift 0.7.2

- Licence: MIT
- Source: <https://github.com/automerge/automerge-swift>
- Resolved revision: `aa45d17ac92cef2b8ded63b47e65a28dc85e3418`

Automerge Swift includes a prebuilt Automerge FFI binary target. Refer to the
upstream release for the notices applicable to that binary.

## GRDB.swift 7.11.1

- Licence: MIT
- Source: <https://github.com/groue/GRDB.swift>
- Resolved revision: `b83108d10f42680d78f23fe4d4d80fc88dab3212`

## ZIPFoundation 0.9.19

- Licence: MIT
- Source: <https://github.com/weichsel/ZIPFoundation>
- Resolved revision: `02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0`

## MTPKit

- Licence: MIT
- Source: <https://github.com/5j54d93/MTPKit>
- Imported revision: `0.1.4`
- Local licence: `StacksCore/Vendored/MTPKit/LICENSE`

The vendored files contain Stacks-specific adaptations described in
`StacksCore/Vendored/MTPKit/README.md`. Those adaptations do not change
the upstream MIT licence for the copied MTPKit code.

## libmobi-swift 1.0.2 and libmobi

The Swift wrapper is dedicated to the public domain under CC0-1.0. The bundled
`libmobi` C library is licensed under the GNU Lesser General Public License,
version 3 or later (LGPL-3.0-or-later).

- Wrapper source: <https://github.com/awxkee/libmobi-swift>
- Wrapper revision: `bbe180f247527f24be18526856a35473a2ad3fe6`
- C library source: <https://github.com/bfabiszewski/libmobi>
- LGPL text: <https://www.gnu.org/licenses/lgpl-3.0.html>
- Wrapper licence text: `libmobi-swift/LICENSE.md` in the resolved Swift
  Package Manager checkout

When distributing a compiled application containing libmobi, provide the
LGPL/GPL licence texts, preserve the libmobi notices, and provide the
corresponding libmobi source and the materials needed to replace or relink the
library as required by LGPLv3. The libmobi source is obtained by Swift Package
Manager rather than vendored in this repository, so binary release packaging
must make that source available separately.

The test fixture `StacksCoreTests/MobiImport/Fixtures/fixture.mobi` comes
from the libmobi test corpus and is documented in that directory's README.

## Notices for binary releases

Binary releases must include this information, the applicable upstream
copyright notices, and the full licence texts for the included components.
The application displays the bundled version in `Stacks/Resources/Notices.md`.
