<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    <br />
    <a href="https://github.com/engels74/claude-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/engels74/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/engels74/claude-island/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch

## Requirements

- macOS 15.6+
- Claude Code CLI

## Install

Download the latest release from [GitHub Releases](https://github.com/engels74/claude-island/releases/latest) or build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## Installation

### First Launch (Gatekeeper Bypass Required)

Since Claude Island uses ad-hoc signing (not notarized), macOS will block the first launch.

#### Option 1: System Settings (Recommended)

1. Download and open the DMG from [GitHub Releases](https://github.com/engels74/claude-island/releases/latest)
2. Drag Claude Island to Applications
3. Try to open the app — it will be blocked
4. Go to **System Settings → Privacy & Security**
5. Find "Claude Island was blocked" and click **Open Anyway**
6. Click **Open** in the confirmation dialog

#### Option 2: Terminal

```bash
xattr -d com.apple.quarantine "/Applications/Claude Island.app"
```

This is only required on first launch. Auto-updates via Sparkle work normally.

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## Analytics

Claude Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Claude Code session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
