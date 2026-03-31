# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

**This is a private fork ("Trident"). Agents have full autonomy — create issues, PRs, branches, and commits freely when asked.**

**CRITICAL: ALL git pushes and PRs MUST target `austinkennethtucker/Trident` (origin). NEVER push to or create PRs against `ghostty-org/ghostty` (upstream). When using `gh pr create`, always pass `--repo austinkennethtucker/Trident`. The upstream remote is fetch-only.**

## Commands

- **Build:** `zig build`
  - On macOS, use `-Demit-macos-app=false` to skip the app bundle and speed up compilation
  - Release: `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`
- **Test (Zig):** `zig build test`
  - Prefer targeted tests: `zig build test -Dtest-filter=<test name>`
- **Quick unit test** (single file): `zig test src/path/to/file.zig`
- **Formatting (Zig):** `zig fmt .`
- **Formatting (Swift):** `swiftlint lint --strict --fix`
- **Formatting (other):** `prettier -w .`
- **macOS app:** `nu macos/build.nu` (not `zig build`)
- **macOS install:** `nu macos/install.nu` (builds Release, signs, installs to `/Applications`)
- **macOS stable DMG:** `nu macos/install.nu --dmg` (builds, signs, notarizes)
- **macOS dev DMG:** `nu macos/release-dev.nu` (patches bundle for dev channel, signs, notarizes)
- **macOS tests:** `nu macos/build.nu --action test`

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`
- C API header: `include/ghostty.h`
- Fork features: popup (`src/apprt/popup.zig`, `src/apprt/gtk/PopupManager.zig`, `macos/Sources/Features/Popup/`), vi-mode (`src/ViMode.zig`)

## Fork Workflow

- **Main branch** mirrors upstream tagged releases — never commit directly
- **All work on feature branches** merged via PRs
- **Upstream sync:** `git fetch upstream --tags --force && git merge v<version>`
- **CI:** GitHub-hosted runners, `.github/workflows/ci.yml` (Zig only — macOS app requires local Xcode 26)
- **Trident config:** `~/.config/trident/config` (separate from Ghostty)

## Gotchas

- C header field order in `include/ghostty.h` must exactly match Zig extern structs
- GTK `PopupManager.loadConfig()` must deep-copy all string fields from config
- `Allocator.free()` on Linux can't handle `[:0]const u8` — cast to `[]const u8` first
- Use `std.fmt.allocPrintSentinel(alloc, fmt, args, 0)` not `allocPrintZ`
- GTK code doesn't compile on macOS — always verify with the Linux CI runner
- Popup action dispatch uses `value.name` not `|v|` capture (comptime switch)

## Issue and PR Guidelines

- Create issues and PRs freely when asked
- Use `gh` CLI for all GitHub operations
- PRs should include separate macOS and Linux test plans
