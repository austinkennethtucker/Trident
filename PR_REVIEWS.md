# Deep Dive Review: PRs #75 - #80

This document contains a comprehensive review of the current open pull requests in the repository, identifying architectural strengths, potential bugs, and performance bottlenecks.

## 🥞 macOS Autofill & Browser Sockets Stack (#77, #78, #79, #80)

### Strengths
- **Security:** `AutofillStore` correctly avoids caching secrets in memory and pipes passwords via `stdin` to `pass-cli` to avoid exposing them in the process argument list.
- **Resilience:** The POSIX-level socket dead-file cleanup in `BrowserSocketServer` (`connect` expecting `ECONNREFUSED`) is robust.
- **Concurrency:** PR #77 successfully introduces `DispatchGroup` to asynchronously drain `stdout` and `stderr` pipes, preventing deadlocks when `pass-cli` returns large JSON payloads.

### Findings & Bugs

#### 1. 🚨 Critical: Multi-user Socket Permission Conflict (PR #78)
- **Location:** `macos/Sources/Features/Browser/BrowserSocketServer.swift`
- **Issue:** The UNIX socket directory is hardcoded to `/tmp/trident`. The first user to launch the app will own this directory. Subsequent users on the same machine will be denied write access, causing the browser socket server to fail to start.
- **Recommendation:** Scope the directory to the user, e.g., `/tmp/trident-\(getuid())`.

#### 2. 🐌 Performance: Slow CLI Discovery (PR #80)
- **Location:** `macos/Sources/Features/Browser/Autofill/AutofillStore.swift` (`discoverCLI()`)
- **Issue:** The function executes `/bin/zsh -l -c "which pass-cli"` *before* checking the hardcoded `candidates` (like `/opt/homebrew/bin/pass-cli`). A login shell (`-l`) sources `.zprofile`, `.zshrc`, etc., which can take hundreds of milliseconds or even seconds.
- **Recommendation:** Check the `candidates` array using `FileManager.default.isExecutableFile` first. Only fall back to the slow login-shell lookup if the fast paths fail.

#### 3. 🏎️ Race Condition: Redundant Autofill Refreshes (PR #77 / #80)
- **Location:** `macos/Sources/Features/Browser/Autofill/AutofillStore.swift` (`refreshIndex()`)
- **Issue:** The `refreshIndex()` function is `async` but lacks a re-entrancy guard. If multiple browser tabs navigate simultaneously while the index is stale, each tab will trigger its own `refreshIndex()` call. Since it awaits subprocesses, multiple concurrent `pass-cli vault list` operations will spawn.
- **Recommendation:** Introduce a `private var refreshTask: Task<Void, Never>?` to coalesce concurrent refresh requests.

#### 4. 📋 UX: Dangling TOTP Clear Timers (PR #77)
- **Location:** `macos/Sources/Features/Browser/Autofill/BrowserAutofillController.swift`
- **Issue:** The 30-second TOTP clipboard clear timer runs as a `DispatchWorkItem`. If the user closes the tab before the 30 seconds elapse, the timer still fires. While PR #77's `shouldClearTOTPPasteboard` safely prevents clearing unrelated clipboard data, it would be cleaner to cancel `totpClearTimer` in the controller's `deinit`.

## 🪟 GTK Popup Refactor (#75)

### Strengths
- **Data Structures:** Moving from parallel arrays to `NamedProfile` and `WindowEntry` structures eliminates fragile index-matching and reduces the risk of out-of-bounds panics.
- **CWD Inheritance:** Walking the GTK toplevels to find the focused surface's working directory is a solid solution for popup CWD inheritance.

### Findings & Bugs

#### 5. 🧹 Memory Management: WindowEntry Leak
- **Location:** `src/apprt/gtk/PopupManager.zig`
- **Issue:** When a popup window is destroyed via `destroyWindow`, the GTK window is destroyed, but the `WindowEntry` remains in the `self.windows` list with an empty/stale `weak_ref`. Over a long session with many uniquely named popups, this list will grow indefinitely.
- **Recommendation:** Consider removing the entry from the list or reusing dead entries when a new popup is created.

## 🛠️ Release Automation (#76)

### Strengths
- **Regex Targeting:** The Python script accurately targets the exact fields needed for Homebrew cask updates without requiring a full Ruby parser.
- **Validation:** Strong unit tests cover the stable vs. dev (no_check) SHA configurations.

### Findings
- **Status:** The PR looks solid and ready for merge. No critical issues found.
