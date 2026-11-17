# Shelf

A small, fast audiobook player for iPhone, for local files.

- Instant play, pause and skip (back 15 s / forward 30 s)
- Import single files (`.m4b`, `.m4a`, `.mp3`, …) or a folder per book from the Files app
- Chapters from `.m4b` files, or one chapter per file for folders of MP3s
- Lock screen, Control Center and headphone controls
- Sleep timer (5–90 minutes, or end of chapter) with a fade-out
- Cover art, remembered position for every book

## How it's built

There is no Mac involved. Every push to `main` runs a GitHub Actions job on a macOS
machine that generates the Xcode project from `project.yml` (XcodeGen), builds an
unsigned app and publishes it as `Shelf.ipa` on the
[latest release](../../releases/latest).

## Installing on the iPhone (free Apple ID)

1. Install **SideStore** on the iPhone once, following the guide at https://sidestore.io.
2. Turn on **Settings → Privacy & Security → Developer Mode** (iOS asks after the first sideload).
3. On the iPhone, open this repo's latest release in Safari and download `Shelf.ipa`.
4. In SideStore, tap **+** and pick `Shelf.ipa`.

Free signing lasts 7 days. Open SideStore and refresh before it runs out (or set up a
Shortcuts automation for it). If it does lapse, refresh and the app comes back with your
books and positions intact.

To update: download the new `Shelf.ipa` and install it the same way; your library is kept.
