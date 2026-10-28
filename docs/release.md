# TestFlight and App Store

Builds run on GitHub Actions `macos-26` runners. Nothing is compiled locally.
The pipeline is the one PrivateGallery (`~/ios` on amy) already ships with:
XcodeGen generates the project, fastlane `beta` builds with manual signing,
uploads, waits for processing and adds the build to the internal tester group.

## One-time setup (not done yet)

These need the Apple developer account and cannot be done from this repo:

1. developer.apple.com: register App ID `pro.imnot.tube`.
2. App Store Connect: New App, iOS, bundle `pro.imnot.tube`, name "Tube SSH"
   (home screen shows "Tube"; pick another store name if taken, the bundle id
   does not change).
3. Create an App Store provisioning profile for `pro.imnot.tube` using the
   existing Apple Distribution certificate. Name it `Tube AppStore`.
4. Add repo secrets on `bad1dea/tube` (Settings, Secrets and variables,
   Actions). Values are the same as on `bad1dea/private-gallery` except the
   profile:

   | Secret | Value |
   |--------|-------|
   | ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64 | same API key as PrivateGallery |
   | DEVELOPMENT_TEAM | same team id |
   | DIST_CERT_P12_BASE64, DIST_CERT_PASSWORD | same distribution certificate |
   | DIST_PROFILE_BASE64 | `base64 -w0 Tube_AppStore.mobileprovision` |
   | PROFILE_NAME | `Tube AppStore` |

   With gh: `gh secret set DIST_PROFILE_BASE64 -R bad1dea/tube < profile.b64`.

## Each build

```sh
gh workflow run ios-build.yml --ref main     # optional compile check, unsigned
gh workflow run testflight.yml --ref main
gh run watch "$(gh run list -R bad1dea/tube --workflow=testflight.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status
```

Build number = Actions run number. `asc-status.yml` and `asc-distribute.yml`
work as in PrivateGallery.

## Export compliance

Info.plist sets `ITSAppUsesNonExemptEncryption = NO`, copied from
PrivateGallery so TestFlight builds distribute without a manual answer. Tube
implements SSH (standard algorithms via swift-nio-ssh/BoringSSL) and AES-GCM
vault encryption. Before public App Store release, confirm whether this falls
under the mass-market exemption for your situation (US EAR 740.17(b)(1)) and
whether France distribution needs a declaration. If the answer is YES, change
the key and upload documentation in App Store Connect.

## App Store submission checklist

- [ ] App record, bundle id, profile, secrets (above)
- [ ] First TestFlight build installs and connects to a real host
- [ ] Privacy policy URL: host `docs/privacy.md` (e.g. GitHub Pages) and enter it
- [ ] App Privacy questionnaire: "Data Not Collected" (no analytics, no
      vendor servers; sync goes to a server the user runs)
- [ ] Export compliance answered (above)
- [ ] Screenshots: 6.9" iPhone and 13" iPad (terminal with key panel, host
      list, host editor with jump hosts)
- [ ] Description, keywords, support URL (GitHub repo), category Developer Tools
- [ ] Review notes: give the reviewer a disposable SSH host and password, and
      explain that sync needs a self-hosted server and is optional
- [ ] Age rating questionnaire (unrestricted web access: no)
- [ ] Repository public + LICENSE before claiming "open source" in the listing
