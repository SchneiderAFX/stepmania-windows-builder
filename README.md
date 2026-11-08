# StepMania Builder

A small Windows toolkit to build [StepMania](https://github.com/stepmania/stepmania) from source and get a **clean, ready-to-play build folder**, without touching your original source and without installing Visual Studio.

- Your source code is **never modified**.
- Uses a **portable toolchain** (MSVC v143 + Windows SDK + CMake + Ninja) downloaded into this folder. Nothing is installed on your system.
- Every download is **verified** (SHA-256 + Microsoft Authenticode signatures).
- Builds are **incremental**: after the first build, only what you changed is recompiled.

## Requirements

- Windows 10/11 x64
- Windows PowerShell 5.1 (included with Windows)
- Internet access, only the first time (about 600 MB download, about 1.5 GB on disk)

## Quick start

1. **Get the toolchain** (one time):

   ```powershell
   .\setup-toolchain.ps1
   ```

   Add `-SkipDefender` to skip the Microsoft Defender scan (it can take several minutes).

2. **Put the StepMania source in `.\source`**
   The folder that contains `CMakeLists.txt`, `src`, `Themes`... can be directly in `source\` or inside one subfolder (e.g. `source\stepmania\`). A `.git` folder is not needed (it is ignored).

3. **Build**:

   ```powershell
   .\build.ps1
   ```

   or just double-click `build.bat`.

4. **Play**: the result is in `.\stepmania-MMDDYYYY\` (US date, e.g. `stepmania-11082026`). Run `Program\StepMania.exe`.

To change the game: edit the files in `.\source` and run `build.ps1` again.

## Folder layout

```
stepmania-build\
  source\                 <- YOU put/edit the StepMania source here (never modified by the builder)
  toolchain\              <- portable MSVC + SDK + CMake + Ninja (created by setup-toolchain.ps1)
  _work\                  <- internal: working copy + build objects (safe to delete, see below)
  stepmania-MMDDYYYY\     <- the clean build (output)
  build.ps1  build.bat    <- the builder
  setup-toolchain.ps1     <- downloads and verifies the toolchain
  verify-toolchain.ps1    <- checks the toolchain was not tampered with
```

## What a clean build contains

| Included | Not included |
|---|---|
| `Program\` (`StepMania.exe`, `StepMania.vdi`, DLLs) | `src`, `extern`, `CMake`, `Build`, `Installer`, `Manual`, `Utils`, `Xcode`, `icons`, `_assets` |
| `portable.ini` (portable mode: `Save`, `Cache`, `Logs` live inside the folder) | Files in the repo root (`CMakeLists.txt`, `.git*`, `README.md`...) |
| `Announcers`, `BackgroundEffects`, `BackgroundTransitions`, `BGAnimations`, `Characters`, `Courses`, `Data`, `Docs`, `NoteSkins`, `Scripts`, `Songs`, `Themes` | `mapconv.exe`, `.map` files, `Themes\_Installer` |

Running the build again on the same day refreshes the same folder and keeps `Save`, `Cache`, `Logs` and `Screenshots`.

## `build.ps1` options

| Option | Description |
|---|---|
| `-Config Release\|Debug\|RelWithDebInfo\|MinSizeRel` | Build configuration (default `Release`) |
| `-Name finished` | Output folder name: `stepmania-finished` instead of the date |
| `-Run` | Launch the game when done |
| `-Clean` | Rebuild from scratch (needed once after moving or renaming this folder) |
| `-SyncOnly` | Only refresh the internal working copy |
| `-NoPackage` | Build, but do not create the clean folder |
| `-Source <path>` | Use another source folder (default `.\source`) |
| `-NoPortable` | Ignore `.\toolchain` and use an installed Visual Studio 2022 |
| `-SkipVerify` | Skip the quick integrity check of the toolchain before building |

## How it works

StepMania's CMake writes the executable into `<source>\Program`, so building in place would modify your source. The builder mirrors `source\` (without `.git`) into `_work\stepmania`, builds there with Ninja, and then copies only the files a release build needs into the output folder.

## Security

`setup-toolchain.ps1` downloads only over HTTPS from `download.visualstudio.microsoft.com` (via `aka.ms/vs/17/release/channel`) and the official GitHub releases of Kitware/CMake and ninja-build/ninja. It:

1. checks the SHA-256 of every downloaded file against the Microsoft manifest or the GitHub API digest;
2. checks that every downloaded MSI and every `.exe`/`.dll` extracted from MSVC and the SDK has a valid Authenticode signature from Microsoft Corporation (otherwise it aborts);
3. writes `toolchain\inventory.json` with the SHA-256 of every file, so tampering can be detected later;
4. optionally scans the folder with Microsoft Defender.

`build.ps1` re-checks the key tools (`cl`, `link`, `rc`, `mt`, `cmake`, `ninja`) against the inventory before every build, and `.\verify-toolchain.ps1` checks the whole folder.

Notes:
- The Windows SDK "Store Apps Tools" package is not installed in full (it contains unsigned MSIX/Store tools); only `rc.exe`, `rcdll.dll`, `mt.exe` and its dependency are kept.
- At the time of writing, the main Microsoft manifest does not match the hash declared by Microsoft's own channel. The script reports it as a warning and relies on the per-package hashes and signatures instead.
- These checks prove the binaries are the ones published and signed by their vendors and were not altered. They are not an audit of the source code.

## What you can delete

| Item | Safe to delete? |
|---|---|
| `source\` | **No**: it is your code |
| `build.ps1`, `build.bat` | **No** |
| `toolchain\` (`msvc`, `sdk`, `cmake`, `ninja`) | Not if you want to keep building (`setup-toolchain.ps1` can recreate it) |
| `toolchain\inventory.json` | Not if you use the portable toolchain (`build.ps1` refuses to build without it, unless you pass `-SkipVerify`) |
| `_work\` | Yes. It is regenerated; the next build is just slower |
| `toolchain\_downloads\` | Yes. Only a download cache |
| `*.log` | Yes |
| `stepmania-MMDDYYYY\` | Yes, but copy its `Save\` first if you played in it (preferences, profiles, scores) |

## Moving or renaming this folder

All paths are relative to the scripts, so you can rename or move the folder (even to another PC). Run `.\build.ps1 -Clean` once afterwards, because the internal build cache stores absolute paths.

## Troubleshooting

- **"StepMania source code not found"**: paste the source into `.\source` (it must contain `CMakeLists.txt` and `src\`).
- **Build fails with an Integrity error**: a toolchain file changed. Run `.\verify-toolchain.ps1`; if you do not recognise the change, reinstall with `.\setup-toolchain.ps1 -Force`.
- **Sound feels delayed**: StepMania's default Windows driver list is `WaveOut,DirectSound-sw,WDMKS,Null`. In `Save\Preferences.ini` try `SoundDrivers=DirectSound-sw` or `SoundDrivers=WDMKS` (game closed).
- **Moved the folder and CMake complains about the cache**: run `.\build.ps1 -Clean`.
