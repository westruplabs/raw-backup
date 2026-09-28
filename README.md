# raw-backup

Verified, incremental backup of folders to USB drives on macOS. Plug in a drive and the backup starts by itself; every copied file is checked with SHA-256 against the original. Think of it as a small, free alternative to ChronoSync's "copy + verify" for external drives.

## Features

1. **Starts automatically** when a configured drive is mounted (launchd `StartOnMount`). Other drives are ignored.
2. **Multiple jobs** – back up several folders, to one or several drives. Each job is *source folder → drive → folder on the drive*.
3. **Copies only new and changed files** – compares size and modification time with the copy on the drive.
4. **Verifies every copied file** – the SHA-256 of original and copy must match, otherwise the file is copied again. Files are written under a temporary name and renamed only when complete, so pulling the drive never leaves half-written files.
5. **Keeps checksums on the drive** (`.raw-backup/jobs/<folder>/manifest.sha256`).
6. **Full check every 30 days** – reads back the entire copy and compares it with the stored checksums. Damaged files are copied again from the original.
7. **Progress bar** with percentage, speed and time remaining. In the background you get notifications at 25, 50 and 75 % (for jobs over 2 GB), and `--status` shows progress at any time.
8. **Notifications** when a backup is done or something went wrong. Log in `~/Library/Logs/raw-backup.log`.

The script **never deletes** anything on the drives. Files you delete from a source folder stay on the drive.

## Installation

```bash
git clone https://github.com/westruplabs/raw-backup.git
cd raw-backup
./install.sh
```

The installer asks for your first job (folder, drive, folder on the drive). Add more jobs later in the config file (see below).

Then, with the drive plugged in, try it without copying anything:

```bash
~/Library/Scripts/raw-backup.sh --dry-run
```

### macOS permission (important)

macOS blocks background scripts from writing to external drives until you allow it. If you get the notification *"Cannot write to …"* or the log says `Operation not permitted`:

**System Settings → Privacy & Security → Full Disk Access** → `+` → press `⌘⇧G`, type `/bin/bash` → add it and switch it on.

Then eject the drive and plug it in again. (This gives bash scripts full disk access in general – it is the standard solution for launchd scripts, but worth knowing.)

## Configuration

Everything lives in `~/.config/raw-backup.conf`. Updating the script never overwrites it.

```bash
JOBS='
~/WORK/Raw          | USB_1TB   | Raw
~/Documents/Work    | USB_1TB   | Work
~/WORK/Raw          | BACKUP_2  | Raw
'
```

One job per line: **source folder | drive name | folder on the drive**.

- **Drive name** is the name shown in Finder (the folder name under `/Volumes`).
- **Folder on the drive** can be left out – it then gets the source folder's name. Use `.` for the top level of the drive.
- Several folders can go to the same drive, and the same folder can go to several drives. When a drive is plugged in, all of its jobs run one after another.
- Lines starting with `#` are ignored.

Check your jobs and which drives are connected:

```bash
~/Library/Scripts/raw-backup.sh --list
```

Other settings:

| Setting | Default | |
|---|---|---|
| `FULL_VERIFY_DAYS` | `30` | Full check every N days per job, `0` = off |
| `EJECT_WHEN_DONE` | `false` | Eject the drive when all its jobs succeeded |
| `NOTIFY` | `true` | macOS notifications |

## Usage

| Command | What it does |
|---|---|
| `raw-backup.sh` | Run every job whose drive is mounted (this runs automatically) |
| `raw-backup.sh --dry-run` | Show what would be copied |
| `raw-backup.sh --verify-all` | Full check of the copies now, repairing damaged files |
| `raw-backup.sh --status` | Show progress of a running backup |
| `raw-backup.sh --list` | Show configured jobs and whether their drives are mounted |

The script is installed in `~/Library/Scripts/`. Run in Terminal, it shows a live progress line:

```
[Raw → USB_1TB] Copying [##########---------------]  41%  84.2 GB of 205.0 GB  96.3 MB/s  about 21 min left  (1203/2950 files)
```

## Good to know

- **Wait for the "done" notification** before pulling the drive. If you pull it mid-run, the run stops safely and continues next time.
- **The check right after copying** may in some cases read the copy from the macOS memory cache rather than from the drive. The periodic full check runs right after the drive is plugged in and reads from the drive itself – that is the one that catches damage that happens on the drive over time.
- **The full check takes time** – roughly as long as reading the whole copy (500 GB on a cheap USB stick can take an hour or more).
- **Drives are recognised by name.** Two drives with the same name are treated as the same drive.
- **One USB drive is not a complete backup.** Drives fail and get lost. Keep at least one more copy elsewhere (NAS or cloud).
- Works with drives formatted as APFS, Mac OS Extended and exFAT. NTFS drives are read-only on macOS.
- Upgrading from the first version: an old single-folder config (`SRC`, `VOLUME_NAME`, `DEST_SUBDIR`) keeps working, and existing checksums on the drive are moved automatically.

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
