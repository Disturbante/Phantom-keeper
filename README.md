# 👻 phantom.sh

Phantom-keeper is a project inspired by [@hacktheclown](https://www.youtube.com/@hacktheclown)'s YouTube video where he showcases a technique to hide a file in Linux by deleting it while keeping a file descriptor (FD) open — making the file completely invisible to the filesystem while still very much alive on disk.

---

## How it works

On Linux, a file is only truly deleted when two conditions are both met:

| Condition | Meaning |
|---|---|
| **Hard link count = 0** | No directory entry points to the inode |
| **Open FD count = 0** | No process has the file open |

`phantom.sh` exploits the gap between these two conditions. When you *hide* a file:

1. A dedicated background process (`phantom-keeper`) opens and holds an FD to the file
2. The file is `unlink()`ed — it vanishes from the directory tree, invisible to `ls`, `find`, and most forensic tools
3. The inode (and all its data) lives on in memory and on disk, accessible via `/proc/<pid>/fd/<n>`

To *unhide* it, the script re-links the inode back into the filesystem using `ln /proc/<pid>/fd/<n> /original/path`, then kills the keeper process.

```
hide               unhide
─────              ───────
file.txt  ──►  [inode, FD held by phantom-keeper]  ──►  file.txt
   link=1           link=0, FDs=1                          link=1
```

---

## Features

- **Hide** any regular file — it disappears from the filesystem instantly
- **Unhide** — restore it to its exact original path
- **Search** for hidden files managed by phantom, or scan the entire system for any deleted-but-open file (`--all`)
- **List** all currently managed hidden files with their keeper PID and status
- Keeper process survives terminal logout (`setsid`)
- State tracked in a simple TSV database (`~/.phantom_db`)

---

## Requirements

- Linux (tested on Debian/Ubuntu)
- `bash` ≥ 4
- `python3` (used for the keeper process)
- Root recommended for `search --all`

---

## Usage

```bash
chmod +x phantom.sh

# Hide a file
./phantom.sh hide /path/to/secret.txt

# Verify it's gone
ls /path/to/secret.txt
# ls: cannot access '/path/to/secret.txt': No such file or directory

# List managed hidden files
./phantom.sh list

# Search for your hidden files
./phantom.sh search

# Search for ALL deleted-but-open files system-wide (requires root)
sudo ./phantom.sh search --all

# Restore the file to its original path
./phantom.sh unhide secret.txt
```

---

## Commands

| Command | Description |
|---|---|
| `hide <file>` | Unlink a file while keeping its inode alive via a keeper process |
| `unhide <name>` | Re-link the file back to its original path and kill the keeper |
| `search [--all]` | Find phantom-managed files; `--all` also shows any unlinked-but-open file on the system |
| `list` | Show all managed hidden files with PID, FD, and original path |

---

## Environment

| Variable | Default | Description |
|---|---|---|
| `PHANTOM_DB` | `~/.phantom_db` | Path to the state database |

---

## The "deleted but alive" trick in the wild

This technique is not new — it appears in:

- **Malware** dropping payloads that vanish from disk immediately after execution
- **CTF challenges** involving forensic analysis of live systems
- **Legitimate use cases** like in-memory secret passing between processes

The `search --all` mode is useful for **forensics**: it walks `/proc/*/fd/*` and flags every symlink the kernel has marked as `(deleted)`, showing which process is holding the ghost file open and how large it is on disk — handy for hunting malware using this exact trick.

---

## Caveats

- The file's data persists on disk until the keeper dies; if the system reboots or the keeper is killed externally without unhiding first, the file is **permanently lost**.
- `search --all` requires root to read other users' `/proc/<pid>/fd/` entries.
- Only regular files are supported (not directories or special files).
- The keeper process (`phantom-keeper`) is visible in `ps`/`top` — this is stealth at the filesystem level, not the process level.

---

## Credits

Inspired by [@hacktheclown](https://www.youtube.com/@hacktheclown) — go watch the [video](https://www.youtube.com/watch?v=AYW8aHo-WT0).
