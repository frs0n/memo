# Repository Guidelines

## Project Structure & Module Organization

This repository contains the `memo` iOS app and local `msplat` engine checkout. The app project is generated from `ios/project.yml`; SwiftUI code lives in `ios/App/Sources`, with resources in `ios/App/Resources`. The `msplat` library is organized by interface: Metal/C++ core code in `msplat/core`, Python bindings in `msplat/python`, CLI code in `msplat/cli`, Swift package code in `msplat/swift/Sources/Msplat`, and tests in `msplat/swift/Tests`. Documentation lives in `docs/`; sample datasets are under `msplat/datasets`.

## Build, Test, and Development Commands

- `cd ios && xcodegen generate`: regenerate the Xcode project after changing targets, packages, or settings.
- `xcodebuild -project ios/memo.xcodeproj -scheme memo -configuration Debug build`: build the iOS app.
- `cd msplat && ./scripts/build-xcframework.sh`: rebuild `MsplatCore.xcframework` for Swift/iOS integration.
- `cd msplat/swift && swift build`: build the Swift package wrapper.
- `cd msplat/swift && swift test`: run Swift package tests.
- `cd msplat && pip install -e .`: install Python bindings in editable mode.
- `cd msplat && pytest`: run Python tests.
- `cd msplat && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`: build the C++ CLI.

## Coding Style & Naming Conventions

Use Swift 6 conventions: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` properties and methods, and small SwiftUI views split by feature directory. For native iOS work, prefer SwiftUI's built-in navigation, presentation, controls, and system styling; keep UI restrained, simple, and platform-native. Keep C++ headers in `core/include` paired with implementations in `core/src`; use existing snake_case filenames for loaders and Metal/C++ internals. Python package code should remain typed where practical and follow module names under `msplat/python/msplat`.

## Testing Guidelines

Add Swift tests to `msplat/swift/Tests` and Python tests to `msplat/tests` using `test_*.py` naming. Prefer focused tests around loaders, training configuration, and API boundary behavior. For iOS UI changes, build the `memo` scheme and verify capture/preview flows in Simulator or on device.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects such as `Add Gaussian splat training preview` and `Refactor capture flow to return recorded packages`. Follow that style: one logical change per commit, no trailing punctuation. Pull requests should summarize the user-visible change, list commands run, call out device/simulator coverage, and include screenshots or recordings for UI changes.

## Security & Configuration Tips

Do not commit local signing changes, private datasets, generated build directories, or large artifacts unless intentionally versioned. Treat `msplat` as a separate library boundary; check submodule or nested-repo status before committing root changes.
