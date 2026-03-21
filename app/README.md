# Pembrook Flutter App

Cross-platform Flutter companion app for the Pembrook secure AI personal agent.

## Supported Platforms

- ✅ macOS
- ✅ Android (API 24+)
- ✅ Linux
- ✅ Windows

## Getting Started

### Prerequisites

- Flutter SDK ≥ 3.22.0
- Dart SDK ≥ 3.6.0
- An atSign provisioned at [my.atsign.com](https://my.atsign.com/dashboard)
- Running Pembrook agent (see `../README.md`)

### Installation

```bash
# Install dependencies
flutter pub get

# Run on macOS
flutter run -d macos

# Run on Android
flutter run -d android

# Run on Linux
flutter run -d linux

# Run on Windows
flutter run -d windows
```

### Configuration

On first launch, the app will prompt you to:

1. Authenticate with your atSign
2. Configure the agent atSign (e.g., `@youragent`)
3. Enable/disable streaming mode

All settings are stored locally and synced via encrypted AtKeys.

## Architecture

- **AtRpc** — Zero-trust RPC calls to the agent via encrypted atPlatform notifications
- **Multi-device sync** — Conversation history shared across all your devices
- **Real-time streaming** — Live token-by-token responses with progress indicators
- **Offline-first** — Local conversation cache with background sync

See the main [README.md](../README.md) for full documentation.
