# build-luci-package

Build LuCI packages inside the official OpenWrt SDK images and get back a directory that says exactly what was built.

## Build

    - uses: eamonxg/build-luci-package@v2
      with:
        sdk: "25.12.5"            # 24.10.4 → ipk, 25.12.5 / main → apk (decided by the SDK)
        arch: x86_64              # any package arch the SDK publishes, e.g. aarch64_cortex-a53
        packages: '[{"pkg":"luci-theme-aurora","path":"."}]'
      env:
        USIGN_KEY: ${{ secrets.USIGN_PRIVATE_KEY }}   # optional, signs ipk output
        APK_KEY:   ${{ secrets.APK_PRIVATE_KEY }}     # optional, signs apk output

Outputs `pkg_type`, `arch`, `out`. The `out/` directory holds the package files, `build-info.json`
(files, versions, arches, sha256 per package), `logs/`, and `.tools/` (apk, usign and the index scripts
from this SDK, for indexing outside the container).

## Package spec

| key   | meaning |
| ----- | ------- |
| pkg   | package name (required) |
| path  | directory on the runner holding the package (its root has the Makefile) |
| repo  | `owner/name` or git URL; requires `ref` as a 40-char sha |
| feed  | with `repo`: override this upstream feed (base, packages, luci, routing, telephony, video) with `repo@ref` and build `pkg` from it. Use this for packages that live inside a monorepo. |
| arch  | `"all"` (default, must build noarch), `"any"` (arch-specific), or a list of arches |
| langs | languages whose `luci-i18n-base-*` are installed and enabled before the build |

Exactly one of `path` / `repo`. The build fails if a package's real architecture disagrees with `arch`.

## Release

    - uses: eamonxg/build-luci-package/release@v2
      with:
        name: luci-theme-aurora
        files: out/*.apk
        body_repo: eamonxg/assets
        body_path: aurora/docs/theme/changelog/${{ github.ref_name }}.md

Publishes on tag builds, or when `release: "true"` with `release_tag`.

## Design

The feed pipeline that consumes this action, and the reasons behind its shape, are described in
openwrt-cloud's feed infra v2 design document.
