# Conch privacy policy

Last updated 2026-10-28.

Conch does not collect, transmit or sell any data to its developers. There are
no analytics, no crash reporting services and no accounts.

## On your device

Hosts, snippets, settings and known host keys are stored in the app's private
storage with iOS file protection. Passwords, private keys and the vault key
are stored in the iOS Keychain and are not synced through iCloud Keychain.

## Connections you make

The app connects only to SSH servers you configure and, if you enable it, to a
sync server you run yourself.

## Sync

Sync is optional and off by default. Data is encrypted on your device with
AES-256-GCM before it is sent. The sync server stores ciphertext and cannot
read your hosts, passwords or keys. Private keys are only included if you turn
on sync for that identity.

## Clipboard

The app reads the clipboard only when you tap Paste. Remote programs can write
to the clipboard (OSC 52) but cannot read it.

## Contact

Open an issue on the project's GitHub repository.
