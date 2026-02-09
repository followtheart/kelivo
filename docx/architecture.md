# Kelivo Project Architecture Analysis & Build Guide

## 1. Architecture Overview

**Kelivo** is a cross-platform LLM chat client based on Flutter, using **Provider** for state management and supporting multiple platforms (Windows, macOS, Linux, Android, iOS).

### 1.1 Core Tech Stack

*   **Framework**: Flutter (SDK ^3.8.1)
*   **Language**: Dart
*   **State Management**: `provider` (MultiProvider pattern, managing state via `ChangeNotifier`)
*   **Local Storage**: `hive` + `hive_flutter` (Key-Value database for storing chat history, settings, etc.)
*   **Networking**: `dio` (Main request library), `http` (Auxiliary)
*   **Dependency Injection**: Provider-based DI (Registered uniformly in `main.dart`)
*   **UI Libraries**: `dynamic_color` (Material You dynamic theming), `flutter_animate` (Animations), `lucide_icons_flutter` (Icons)
*   **Special Capabilities**:
    *   **MCP (Model Context Protocol)**: Native support for MCP protocol (see `dependencies/mcp_client`)
    *   **Desktop Optimization**: `window_manager`, `tray_manager`, `desktop_drop`
    *   **Localization**: `flutter_localizations` (Supports Chinese and English)

### 1.2 Directory Structure Analysis

The project follows a hybrid **Feature-based** and **Layer-based** architecture:

```text
lib/
├── main.dart               # App Entry & Global Provider Registration
├── core/                   # Core Layer: Common services, states, models
│   ├── models/             # Data Models
│   ├── providers/          # State Management (Providers: Chat, User, Settings...)
│   └── services/           # Business Services (API, MCP, TTS, Logging)
├── desktop/                # Desktop-specific UI Logic (Windows/macOS/Linux)
│   ├── desktop_chat_page.dart
│   ├── desktop_window_controller.dart
│   └── ...
├── features/               # Business Feature Modules
│   └── home/               # Home Page & Mobile Main UI
├── shared/                 # Shared Components & Utilities
├── theme/                  # Theme Configuration (Theme Factory)
├── l10n/                   # Localization Resources (.arb files)
└── secrets/                # Secret Management (Do not commit sensitive info)

dependencies/               # Local/Private Packages
├── flutter_tts/            # Custom TTS Implementation
├── flutter-permission-handler/ # Modified Permission Handler
├── mcp_client/             # MCP Client Core Library
└── tray_manager/           # Modified Tray Manager
```

---

## 2. Build & Compile Guide

Since the project includes local dependencies and code generation steps, strictly follow these steps to compile.

### 2.1 Prerequisites

1.  **Flutter SDK**: Ensure Flutter SDK is installed (Recommended version >= 3.29.0, matching `sdk: ^3.8.1` Dart version requirement).
2.  **Platform Environment**:
    *   **Windows**: Visual Studio 2022 (with "Desktop development with C++" workload)
    *   **Android**: Android Studio & Android SDK
    *   **iOS/macOS**: Xcode & CocoaPods
    *   **Linux**: CMake, Ninja, GTK development libraries (`libgtk-3-dev`)

### 2.2 Project Initialization

Open a terminal in the project root directory and run:

```bash
# 1. Get dependencies
flutter pub get

# 2. Generate local code (Hive adapters, etc.)
# Note: This project uses build_runner and hive_generator, this step is mandatory
dart run build_runner build --delete-conflicting-outputs

# 3. Generate localization files (l10n)
# Although pubspec.yaml is configured for auto-gen, manual execution ensures correctness
flutter gen-l10n
```

### 2.3 Run in Debug Mode

```bash
# Windows
flutter run -d windows

# Android
flutter run -d android

# Run with verbose logging if specific native issues occur
flutter run -v
```

### 2.4 Build for Release

**Windows (.exe):**
```bash
flutter build windows --release
# Build artifacts location: build/windows/runner/Release/
```

**Android (.apk):**
```bash
flutter build apk --release
# Or generate App Bundle (.aab) for Google Play
flutter build appbundle --release
# Build artifacts location: build/app/outputs/flutter-apk/
```

**macOS (.app):**
```bash
flutter build macos --release
# Build artifacts location: build/macos/Build/Products/Release/
```

---

## 3. Notes

1.  **Local Dependencies**:
    The project references local packages under `dependencies/` in `pubspec.yaml`. If building in a CI/CD environment, ensure these subdirectories exist and are complete.
    ```yaml
    # Example
    mcp_client:
        path: ./dependencies/mcp_client
    ```

2.  **Desktop Window Management**:
    `lib/main.dart` contains the `_initDesktopWindow` method, which uses `window_manager` to hide the native title bar. If you encounter window anomalies on certain Linux distributions, check the logic here.

3.  **Code Generation**:
    If you modify Model classes annotated with `@HiveType`, you **must** re-run `dart run build_runner build` to update the adapters, otherwise runtime errors will occur.
