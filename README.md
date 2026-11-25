# Bookkeeper

**Local-first accounting.** What you hold in crypto, and where your money goes, kept on your Mac.

Bookkeeper keeps your holdings without ever touching a wallet key, reads the CSV your bank
already lets you export, and draws the answers as rings you can touch. It makes no
account, takes no fee and sends no analytics. Every price lookup goes through Tor, and
your bank lines never leave your Mac.

Made by the House of Helios. GPL-3.0.

## What it does

- **Crypto.** Name a wallet and enter what it holds; no address is ever looked up.
  Prices come from DefiLlama, logos from DefiLlama's icon service. No API key is
  needed; a free CoinGecko demo key (Settings) only helps a few long-tail tokens.
- **Spending.** Drop a bank export on the window. Common banks are known; an unknown file
  is taught once. Overlapping exports never count twice, card payments and transfers are
  kept out of spending, and a messy register line is renamed once and remembered.
- **Budget** (arriving). A plan per category, nested rings per family, leftovers that
  carry into next month, and the charges that come every month, found for you.

## Privacy, plainly

- Network lookups (prices, logos, updates) go through Tor, bundled in the app
  ([Arti](https://gitlab.torproject.org/tpo/core/arti), the Tor Project's Rust client).
  There is no direct fallback: if Tor can't connect, nothing is fetched.
- Bank data is never sent anywhere. No bank linking, no lookups, no AI categorising.
- Everything lives in `~/Library/Application Support/Bookkeeper/`, as plain files you
  can read and back up.

## Install

1. Download [`Bookkeeper.dmg`](../../releases/latest/download/Bookkeeper.dmg) and open it.
2. Drag Bookkeeper onto the Applications shortcut beside it.
3. The app is signed ad hoc, not by a paid Apple developer account, so the first open
   needs one extra step: try to open it once, then System Settings → Privacy & Security →
   **Open Anyway**. (On macOS 14, right-click the app → **Open** → **Open** also works.)

Needs macOS 14+ on Apple silicon.

Updates arrive inside the app. Each one is checked twice before it is installed: its
SHA-256 must match the release, and the release must be signed with the project's key,
whose public half is built into the app (`ReleaseFeed.swift`).

## Build from source

Needs macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
mkdir -p vendor && cp /path/to/arti vendor/arti   # Arti 2.6.0, universal; see scripts/fetch-arti.sh
xcodebuild -project Bookkeeper.xcodeproj -scheme Bookkeeper -configuration Release build
```

A Release build refuses to finish without `vendor/arti`. The core logic and its tests
live in `BookkeeperCore/` (`swift test` there).

`scripts/make-dev-app.sh` builds a separate **Bookkeeper Dev** that runs on made-up data in
`_DevData/`, so nothing real is ever needed to work on it.

## Thanks

- [Actual Budget](https://github.com/actualbudget/actual) (MIT), whose envelope rules and
  recurring-charge finder the Budget tab learned from.
- [Fluent Emoji](https://github.com/microsoft/fluentui-emoji) (MIT) for the icons.
- DefiLlama and the Tor Project.

## License

GPL-3.0 — see [LICENSE](LICENSE).
