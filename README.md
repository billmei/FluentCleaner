# FluentCleaner for macOS

FluentCleaner previews old temporary files, app caches, and diagnostic reports from your macOS user account. It requires macOS 13 or later and runs on both Apple silicon and Intel Macs.

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

| Location | Files last modified | Selected by default |
| --- | --- | --- |
| Your macOS temporary directory (`getconf DARWIN_USER_TEMP_DIR`) | Over 7 days ago | Yes |
| `~/Library/Caches` | Over 30 days ago | No |
| `~/Library/Logs/DiagnosticReports` | Over 30 days ago | No |

FluentCleaner scans regular files owned by your account and skips symbolic links, hard links, and other volumes beneath the scan root. It preserves the directories themselves. Sizes in the preview describe the files’ logical sizes. Close apps before cleaning their caches, since some apps may be using files in a selected location.

FluentCleaner for macOS is based on the scan, review, and clean workflow of the original Windows project. [Windows edition documentation](README_WINDOWS.md)
