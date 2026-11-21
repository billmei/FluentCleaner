# FluentCleaner for macOS

FluentCleaner previews old temporary files, app caches, diagnostic reports, browser data, privacy traces, recent file lists, and leftover traces from uninstalled apps in your macOS user account. It requires macOS 13 or later and runs on both Apple silicon and Intel Macs.

## Build and run

Install Xcode 15 or later, or the corresponding Xcode Command Line Tools. From the repository root, run:

```sh
sh tools/build-macos.sh
open build/FluentCleaner.app
```

Run the cleanup engine tests with `swift test`.

## Clean up files

1. Select the locations you want to scan and click **Scan**. The scan lists each eligible file, its category, and its size.
2. Review the paths and click **Review Deletion…**. The confirmation shows the file count and total size.
3. Click **Delete Files** to permanently remove the listed files, or **Cancel** to keep them. Files that changed or disappeared after the scan are skipped.

| Location | Scope | Selected by default |
| --- | --- | --- |
| Your macOS temporary directory (`getconf DARWIN_USER_TEMP_DIR`) | Files last modified over 7 days ago | Yes |
| `~/Library/Caches` | Files last modified over 30 days ago | No |
| `~/Library/Logs/DiagnosticReports` | Files last modified over 30 days ago | No |
| Browser data (Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera, Firefox) | History, cookies, sessions, caches, and website storage (preserves bookmarks, passwords, and extensions) | No |
| Privacy traces (`QuarantineEventsV2`, QuickLook thumbnail cache, `~/Library/Saved Application State`, HSTS & `~/Library/HTTPStorages`) | Download history, cached document previews, saved window state, and app HTTP cookies | No |
| Recent file lists (`~/Library/Application Support/com.apple.sharedfilelist`, legacy recent-item plists) | Recently opened documents, apps, servers, and hosts (preserves Finder favorites and login items) | No |
| Uninstalled app traces (`Preferences`, `Application Support`, `Caches`, `Containers`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs`) | Reverse-DNS third-party bundle traces not matching any installed app, nested helper, plugin, or launch agent (skips `com.apple.*` and `group.*`) | No |

FluentCleaner scans regular files owned by your account and skips symbolic links, hard links, and other volumes beneath the scan root. It preserves the directories themselves. Sizes in the preview describe the files’ logical sizes. Close browsers and other apps before cleaning their data, and grant FluentCleaner Full Disk Access in System Settings if you want it to scan protected locations like `~/Library/Safari`.

FluentCleaner for macOS is based on the scan, review, and clean workflow of the original Windows project. [Windows edition documentation](README_WINDOWS.md)
