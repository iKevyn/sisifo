<p align="center"><img src="assets/icon-1024.png" width="140" alt="Sísifo"></p>

<p align="center"><b>English</b> · <a href="README.pt-BR.md">Português</a></p>

<h1 align="center">Sísifo</h1>

<p align="center">Your WhatsApp work groups, read and summarized. What people ask of you becomes a task; everything else you just get the gist of.</p>

---

Sísifo is a Mac app that reads your WhatsApp and uses Claude (your own subscription, through Claude Code) to:

- **Pull tasks out of conversations**: who asked, what, by when, and whether someone on your team already handled it.
- **Summarize unread chats** in one line and suggest a reply in your own writing style.
- **Split Work from Personal**: groups where your team talks become Work.
- **Reply without opening WhatsApp**, with a real chat inside the app.
- **Send a task to Claude Code** in one click, with the conversation context included.

Everything runs on your Mac. Messages live in `~/Library/Application Support/Sisifo` and only go to Claude when they are being summarized.

The app is available in **English** and **Portuguese** (choose on the first screen or later in the app menu).

## Install

1. Download `Sisifo.dmg` from [Releases](../../releases) and drag the app to Applications.
2. The first time, right-click the app and choose **Open** (it is not signed by Apple yet).
3. Follow the setup: connect Claude, scan the WhatsApp QR code, pick your team.

**Requires:** macOS 26 on an Apple Silicon Mac, and [Claude Code](https://claude.com/claude-code) installed.

## Updates

Sísifo checks GitHub Releases once a day. When there is a new version it shows **Update available** in the app menu; one click downloads it, replaces the app and reopens it. Your data stays where it is.

## A note about WhatsApp

The connection uses [Baileys](https://github.com/WhiskeySockets/Baileys), which works like WhatsApp Web but **is not official**. WhatsApp may limit or ban accounts that use apps like this. Use it at your own risk, and preferably in moderation.

## How it works

```
Sisifo.app
├── Swift app (window, menu bar, first-run setup, updater)
├── bundled Node
├── bridge/          WhatsApp bridge (Baileys) → local SQLite, 127.0.0.1:47851
├── server/          tasks and unread summaries, calls `claude -p`, 127.0.0.1:47852
└── server-privado/  chats and sending, 127.0.0.1:47853
```

Nothing listens outside `127.0.0.1`. The bridge requires a token stored only on your Mac.

## Build from source

```sh
git clone https://github.com/iKevyn/sisifo && cd sisifo
./build.sh            # build/Sisifo.app
./build.sh --install  # copy to /Applications
./build.sh --dmg      # build/Sisifo.dmg
```

Requires Xcode (Swift 6) and Node 22.5+ (Node is copied into the app).

## License

MIT. See [LICENSE](LICENSE).
