# xcode-runner

Build and run Xcode projects from the terminal with a fast, interactive TUI.

## Features

- Discover Xcode projects and workspaces automatically
- Pick schemes and devices (simulator or physical)
- Build and run in one command
- Remember recent schemes for faster runs
- Verbose build output when you need it

## Requirements

- macOS 13 or newer
- Xcode installed (for `xcodebuild` and `xcrun`)

## Install

### Homebrew (tap-less formula URL)

```bash
brew install --formula https://raw.githubusercontent.com/thibaudse/xcode-runner/main/Formula/xcode-runner.rb
```

This installs from the `main` branch and builds from source.

### Homebrew (tap)

```bash
brew tap thibaudse/xcode-runner https://github.com/thibaudse/xcode-runner
brew install xcode-runner
```

### From source

```bash
git clone https://github.com/thibaudse/xcode-runner
cd xcode-runner
swift build -c release
./.build/release/xcode-runner --help
```

### Prebuilt release

Download the latest release from GitHub Releases, then:

```bash
chmod +x xcode-runner
mv xcode-runner /usr/local/bin/
```

## Usage

Run with interactive selection:

```bash
xcode-runner
```

Run non-interactively:

```bash
xcode-runner --project MyApp.xcodeproj --scheme MyApp --auto
```

Target a specific device:

```bash
xcode-runner --device <UDID> --verbose
```

## Options

- `-p`, `--project` : Path to the project or workspace
- `-s`, `--scheme`  : Scheme to build
- `-d`, `--device`  : Device UDID to run on
- `-a`, `--auto`    : Skip device selection and use the first available simulator
- `-v`, `--verbose` : Show detailed build output
- `--help`          : Show help
- `--version`       : Show version
