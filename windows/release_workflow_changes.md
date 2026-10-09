# Proposed change: attach the Windows package to a release on request

Status: proposal only. `.github/workflows/release.yml` has not been edited.
This file describes the exact change to make if and when a Windows ZIP should be
attached, and how to keep the default behavior honest.

## Current behavior

`release.yml` runs on `push` of a `v*` tag, builds the Linux binaries with
`scripts/build_linux.sh`, runs the suites, creates a **draft** release with the
Linux binaries and `SHA256SUMS.txt`, and states in the draft notes that Windows
binaries are not attached because the suites do not test them. Nothing in the
workflow signs anything; the `.asc` is added offline (`doc/release.md`).

`build.yml`'s `windows-build` job builds `cachecoind.exe` and
`cachecoin-cli.exe` and is required (a failure fails the run), but its artifact
expires after 90 days and could still be from a different commit than the tag.
Attaching an artifact that may be stale or from a different commit would
conflict with the honesty rules in `doc/release.md`.

## Design

- Keep the default: a tag push attaches no Windows files.
- Add a manual `workflow_dispatch` trigger to `release.yml` with an input
  `attach_windows` that defaults to `false`. The maintainer runs the workflow
  **from the signed tag ref** and sets it to `true`; the Windows package is then
  built inside that release run, from the same tag, and attached to the same
  draft.
- Build the `.exe` files in the release run rather than downloading the
  `build.yml` artifact: the artifact can be expired or from another run, and
  `actions/download-artifact` cannot reach across workflow runs without a run id
  and token. A same-run build keeps the Windows package bound to the tag.
- Signing stays offline. CI attaches the zip and `SHA256SUMS.windows.txt`; the
  maintainer adds `SHA256SUMS.windows.txt.asc` by hand before publishing.

## Change 1: triggers

```diff
 on:
   push:
     tags: ['v*']
+  workflow_dispatch:
+    inputs:
+      attach_windows:
+        description: Also build and attach the Windows package ZIP (default: no)
+        required: false
+        type: boolean
+        default: false
```

A tag push supplies no input, and a skipped `if` on the new job (below) means
the job never runs for `push`. `default: false` only affects manual runs; it is
the explicit gate, not a promise about tag pushes.

## Change 2: make draft creation idempotent

Without this, a manual run fails at `gh release create` because the draft from
the tag push already exists.

```diff
       - name: Create draft release
         env:
           GH_TOKEN: ${{ github.token }}
         run: |
           PATCHES_ID="$(cat "$HOME/cachecoin-build/cachecoin-v31.1/.cachecoin-patches")"
-          gh release create "${GITHUB_REF_NAME}" \
-            --draft \
-            --title "CacheCoin ${GITHUB_REF_NAME}" \
-            --notes "Draft release built by CI ..." \
-            release/*
+          gh release view "${GITHUB_REF_NAME}" >/dev/null 2>&1 || \
+            gh release create "${GITHUB_REF_NAME}" \
+              --draft \
+              --title "CacheCoin ${GITHUB_REF_NAME}" \
+              --notes "Draft release built by CI ..."
+          gh release upload "${GITHUB_REF_NAME}" release/* --clobber
```

Keep the existing notes text unchanged, including the sentence that Windows
binaries are not attached.

## Change 3: new job `windows-release`

Add after `linux-release`. It reuses the `windows-build` steps from
`build.yml`; keeping them in sync is manual, and a later refactor could move
them into a reusable script. The Tor bundle version and hash are pinned as
environment constants and must be taken from the Tor Project's signed checksum
file for the chosen release.

```yaml
  windows-release:
    # Manual only. Tag pushes never set the input, so this job is skipped by
    # default and the draft notes stay correct.
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.attach_windows }}
    needs: linux-release
    runs-on: windows-2022
    permissions:
      contents: write
    defaults:
      run:
        shell: msys2 {0}
    env:
      TOR_EXPERT_URL: https://dist.torproject.org/torbrowser/<tor-version>/tor-expert-bundle-windows-x86_64-<tor-version>.tar.gz
      TOR_EXPERT_SHA256: <sha256-from-torproject-signed-sums>
    steps:
      - name: Refuse to run outside a version tag
        run: |
          case "$GITHUB_REF_NAME" in
            v[0-9]*) ;;
            *) echo "dispatch this workflow from the signed vX.Y.Z tag"; exit 1 ;;
          esac
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          persist-credentials: false
      - uses: msys2/setup-msys2@ec48f7c5447b3140e2b088413ae3a55687bccb6e
        with:
          msystem: MINGW64
          update: true
          install: >-
            git make mingw-w64-x86_64-toolchain
            mingw-w64-x86_64-cmake mingw-w64-x86_64-boost
            mingw-w64-x86_64-libevent mingw-w64-x86_64-sqlite3
            mingw-w64-x86_64-zeromq python
      # Copy the "Clone pinned sources", "Apply CacheCoin patches in order",
      # "Build RandomX + node", "Rename the executables", "Set the product
      # name and icon on the executables", "Assert the product metadata took
      # effect" and "Assert static runtime and test the packaged folder with a
      # clean PATH" steps from build.yml verbatim. They produce release/bin
      # with the statically linked executables and SHA256SUMS.txt; nothing is
      # stripped or collected separately.
      - name: Fetch and verify the Tor Expert Bundle
        run: |
          curl -fsSLo tor.tar.gz "$TOR_EXPERT_URL"
          echo "$TOR_EXPERT_SHA256  tor.tar.gz" | sha256sum -c -
          mkdir -p tor-expert
          # The Expert Bundle has tor/, data/ and docs/ at the top level; keep
          # that layout and pass the extraction root to build_package.sh, which
          # understands the bundle layout.
          tar -xzf tor.tar.gz -C tor-expert
          test -f tor-expert/tor/tor.exe
          test -f tor-expert/docs/tor.txt
      - name: Verify the Tor bundle against the pin
        # Downloads the pinned archive from windows/TOR-PIN.txt, checks its
        # sha256, and compares every file with the extracted bundle.
        run: |
          bash "$GITHUB_WORKSPACE/windows/verify_tor_bundle.sh" \
            --tor-dir "$GITHUB_WORKSPACE/tor-expert"
      - name: Assemble the package
        run: |
          mkdir -p "$GITHUB_WORKSPACE/win-release"
          # --gui-dir must point at a directory containing CacheCoin.exe produced
          # by the GUI build; omit the flag to ship a package without the window.
          if [ -n "${{ inputs.attach_windows }}" ] && [ ! -f "$GITHUB_WORKSPACE/gui/CacheCoin.exe" ]; then
            echo "gui/CacheCoin.exe is missing; drop --gui-dir to ship without the window"
            exit 1
          fi
          bash "$GITHUB_WORKSPACE/windows/build_package.sh" \
            --bin-dir "$GITHUB_WORKSPACE/release/bin" \
            --tor-dir "$GITHUB_WORKSPACE/tor-expert" \
            --gui-dir "$GITHUB_WORKSPACE/gui" \
            --version "${GITHUB_REF_NAME#v}" \
            --out "$GITHUB_WORKSPACE/win-release"
      - name: Check the patch fingerprint against the tag
        run: |
          FP="$(cat patches/*.patch | sha256sum | cut -d' ' -f1)"
          grep -q "\"patch_fingerprint\": \"$FP\"" \
            win-release/CacheCoin-Windows-*/version.json
      - name: Attach the package to the draft release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release view "${GITHUB_REF_NAME}" >/dev/null 2>&1 || \
            gh release create "${GITHUB_REF_NAME}" --draft \
              --title "CacheCoin ${GITHUB_REF_NAME}"
          gh release upload "${GITHUB_REF_NAME}" \
            win-release/CacheCoin-Windows-*.zip \
            win-release/CacheCoin-Windows-*/SHA256SUMS.windows.txt \
            --clobber
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
        with:
          name: cachecoin-windows-package
          path: win-release/
```

Notes:

- `--version "${GITHUB_REF_NAME#v}"` strips the leading `v`, matching the
  `x.y.z` requirement of `build_package.sh`.
- The job requires `windows/launcher/CacheCoin.ps1`, the entry-point `.cmd` files and
  `windows/docs/` to be committed; `build_package.sh` fails otherwise. Without
  `--gui-dir` the package has no `CacheCoin App.cmd`/`CacheCoin.exe`, which the
  shipped docs describe.
- The zip is attached unsigned. `SHA256SUMS.windows.txt.asc` is not produced
  here and must be added offline before publishing.
- The `if` uses `github.event_name` as well as the input so the job cannot run
  for non-dispatch events even if `inputs` were ever populated there.

## Change 4: release notes when Windows is attached

The draft created by `linux-release` says Windows binaries are not attached. If
`windows-release` ran, that sentence is now false. The maintainer must replace
the draft notes with `windows/release-notes-template.md` before publishing,
filling in the zip sha256 (printed by `build_package.sh`), the patch
fingerprint, the Tor version and the signing key fingerprint. Optionally
automate the mechanical part:

```bash
# Fill a copy of the template first: publishing the raw file would ship the
# <placeholders> as the release notes.
cp windows/release-notes-template.md /tmp/notes.md   # then edit /tmp/notes.md
gh release edit "${GITHUB_REF_NAME}" --notes-file /tmp/notes.md
```

The template states, in the release itself: not reproducible; sha256 proves
transit only; GPG proves origin; SmartScreen warning expected; Windows is
outside the suites; mining is a lottery; no financial advice.

## How the default stays honest

1. `attach_windows` defaults to `false` and tag pushes have no input, so the
   default release still contains no Windows files and the existing draft note
   remains true.
2. Attaching requires two deliberate acts: dispatching the workflow from the
   tag and setting the boolean. It cannot happen silently.
3. The job refuses refs that do not look like version tags, so it cannot attach
   a package built from a branch.
4. The workflow never signs. A release that contains a Windows zip but no
   `SHA256SUMS.windows.txt.asc` is incomplete and must not be published.
5. The notes template is mandatory when attaching; publishing says the `.exe`
   files are unsigned and untested by the suites.
6. Do not flip the default or attach to tag pushes until the Windows binaries
   are covered by the automated suites; until then every default path leaves
   them off.

## Alternative considered

Add the Windows assets to `build.yml` and download the `cachecoin-windows`
artifact in `release.yml` with `gh run download`. Rejected for now: the artifact
expires and needs a run id or artifact name lookup, and it makes it possible to
publish binaries from a different commit than the tag. The Windows job is
mandatory and green now, so this alternative is workable if the run id is
recorded at tag time; it is left out only to keep the release bound to a
same-run build.

## Implemented: static SQLite and a packaged-folder test

The Windows build now links SQLite statically and the package carries no
third-party DLL. What was done and verified locally end to end:

1. `libsqlite3.dll.a` is moved aside before configuring the node build, so
   CMake resolves `/mingw64/lib/libsqlite3.a` (recorded in `CMakeCache.txt` as
   `SQLite3_LIBRARY`). No patch or consensus file is touched.
2. The build sanitizes itself: `-ffile-prefix-map`/`-fmacro-prefix-map` remove
   absolute build paths from strings, and `-Wl,-s -Wl,--no-insert-timestamp`
   strip the executables and set the PE header time to 1970-01-01.
3. The artifact step renames, brands, then asserts: for each executable, no
   name printed by `objdump -p` may exist in `/mingw64/bin`. The old "collect
   runtime DLLs" loop is gone; a regression now fails the job.
4. A clean-environment test runs the packaged folder (with `/mingw64/bin`
   removed from `PATH`) through create-wallet, get-address and one mined
   regtest block. This closes the gap where CI could find DLLs through the
   MSYS2 PATH but a user's machine could not.
5. `doc/build-windows.md` and `windows/README.md` carry the same steps, and
   `PROVENANCE.txt` no longer lists `libsqlite3-0.dll`.

Measured result: imports are `ADVAPI32, bcrypt, IPHLPAPI, KERNEL32, msvcrt,
SHELL32, WS2_32` only; the PE timestamp is 1970-01-01; the clean-PATH wallet
round-trip passes.

## Release assets and provenance (planned)

For each Windows release, attach: the ZIP, `SHA256SUMS.windows.txt` and the
detached `.asc`, the raw executables (`cachecoind.exe`, `cachecoin-cli.exe`,
`CacheCoin.exe`) so they can be hashed without unpacking, `PROVENANCE.txt`,
`TOR-PIN.txt`, and a `BUILD-INFO.txt` generated by CI with the patch
fingerprint, base pins, runner image, compiler/toolchain versions,
`SOURCE_DATE_EPOCH` if used, and the CI run URL. Before packaging, run
`windows/verify_tor_bundle.sh` against the unpacked bundle. The release notes
must state the reproducibility status as it is (see the notes template), never
more.
