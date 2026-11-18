# Changelog

## Unreleased

- APFS clones are counted once. Folders full of cloned copies, such as Xcode test simulators in `~/Library/Developer/XCTestDevices`, show the space they really take instead of the sum of every copy (435 GB → 69 GB on a test machine). The status bar shows how much data clones share; a setting turns it off.
- Duplicates no longer list clones of the same file, since deleting them frees nothing.
- Fixed: folders in the inspector lists kept the hourglass icon after the scan finished.

## 1.3.0

- Folders appear in the chart as soon as they are listed and grow while their subfolders are read, instead of showing up only after a whole branch is scanned. The scan goes breadth first, six levels deep, then finishes deeper branches in one pass.
- Scanning is about twice as fast thanks to better parallelism; scan results are attached to the tree in batches several times a second.

## 1.2.0

- Cloud files are never downloaded during a scan. Placeholders from iCloud Drive and other File Provider clouds (Dropbox, Google Drive, OneDrive) are detected by their metadata: files count as zero disk space, folders that were never listed on this Mac are not opened. The status bar shows how much is stored only in the cloud.
- The process blocks materialization of cloud files, so no feature (duplicates, analyses) can trigger a download by accident.

## 1.1.0

- English interface; Russian is now a translation. The app follows the macOS language setting.
- Largest panel counts app bundles and other packages as single items and no longer lists the scanned folder itself.
- Separate hover hint for the treemap view.
- Launch arguments for scripted demos: `--open-path`, `--view`, `--tab`, `--no-save`.

## 1.0.0

First public release.

- Sunburst and treemap views with progressive parallel scanning.
- Hover path, click-to-enter, center click to go up, context menu with Finder, Quick Look, Trash and permanent delete.
- Free space on the volume; list of unreadable folders with reasons.
- Inspector panels:
  - largest items;
  - file types;
  - files not touched for a long time;
  - changes since an earlier scan;
  - developer caches;
  - duplicates;
  - deletion collector.
- Saved scans, live updates via FSEvents, administrator scan.
- Full Disk Access onboarding.
