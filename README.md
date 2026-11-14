# StepMania / ITGmania Builder

A small Windows toolkit to build [StepMania](https://github.com/stepmania/stepmania) or [ITGmania](https://github.com/itgmania/itgmania) from source and get a **clean, ready-to-play build folder**, without touching your original source and without installing Visual Studio or git.

- **Foolproof**: no source yet? The builder offers to download StepMania or ITGmania for you.
- Your source code is **never modified**.
- Uses a **portable toolchain** (MSVC v143 + Windows SDK + CMake + Ninja) downloaded into this folder. Nothing is installed on your system.
- Every download is **verified** (SHA-256 + Microsoft Authenticode signatures).
- **You choose how tidy it is**: at the end of every build you are asked whether to delete the internal working folder (`_work`). Keep it and the next build is **incremental** (only what you changed is recompiled, ideal while testing code changes); delete it and the folder stays clean, but the next build compiles everything again. `DELETE_WORK=yes` / `no` in `3. build.bat` answers it for you.
- **You always see that it is working**: numbered steps (`[3/5]`), percentage bars for downloads, compilation and packaging, and an "in progress" spinner with the elapsed time for tasks whose length cannot be known.
- The game (StepMania or ITGmania) is **detected automatically** from the source.

## Requirements

- Windows 10/11 x64
- Windows PowerShell 5.1 (included with Windows)
- Internet access the first time (toolchain: about 600 MB download, about 1.5 GB on disk; source: about 600 MB)

## Quick start

The three numbered `.bat` files in the main folder are the recommended order. Double-click them one after another:

| Step | File | When |
|---|---|---|
| 1 | `1. setup-toolchain.bat` | **Once**, to get the portable toolchain |
| 2 | `2. get-source.bat` | **Only if you do not have StepMania or ITGmania in `source\` yet**, or to add another one (it downloads it for you into its own folder). If you already pasted the source there, skip this step |
| 3 | `3. build.bat` | Every time you want to build |

(`verify-toolchain.bat` has no number: it is an optional check that you can run whenever you want.)

1. **Get the toolchain** (one time): double-click `1. setup-toolchain.bat`.
   When it reaches the Microsoft Defender scan (it can take several minutes) it asks you to **continue** or **skip** it. Skipping is less secure: the files are still checked by hash and Microsoft signature, but not scanned for malware. To stop being asked, set `DEFENDER=scan` or `DEFENDER=skip` inside the `.bat`.

2. **Get the source code** in `.\source`. **This step is only needed if you do not already have StepMania (or ITGmania) in `source\`.** Pick one:
   - **Let the builder download it**: double-click `2. get-source.bat` and choose StepMania, ITGmania, or **another repository such as a fork** (paste its URL). It goes into its own folder: `source\stepmania`, `source\itgmania` or `source\<fork name>`. (If you skip it and `source\` is empty, step 3 offers the same menu, so you cannot get stuck.)
   - **Do it yourself**: paste the source into its own folder inside `source\` (e.g. `source\stepmania\`, the folder that contains `CMakeLists.txt`, `src`, `Themes`...) and skip this step. A single source pasted directly in `source\` also works. A `.git` folder is optional.

   **Several sources side by side**: you can keep as many as you want (e.g. `source\stepmania`, `source\itgmania`, `source\stepmania-fixes`). When there is more than one, `3. build.bat` asks which one to build (Enter = the last one you built), or set `SOURCE=<folder name>` in it. If you download a source whose folder already exists, `2. get-source.bat` warns you and lets you **keep it and download the new one with another name** (e.g. `stepmania-2`) or **delete it and download it again** (you must type `YES`; your changes in it would be lost).

   > **Do not use GitHub's "Download ZIP" button.** ZIP files do not include the git submodules (`extern\mbedtls`, `extern\libpng`...), so the build cannot work. Use `2. get-source.bat` (it also downloads forks) or `git clone --recursive <URL>`. The builder detects a source without submodules and tells you how to fix it.

3. **Build**: double-click `3. build.bat`.

4. **Play**: the result is in a folder named after the source, the date (US format) and the time of the build (24 h): `.\stepmania-MMDDYYYY-HHMM\`, `.\itgmania-MMDDYYYY-HHMM\`, `.\stepmania-fixes-MMDDYYYY-HHMM\`... (e.g. `itgmania-11082026-1530` = November 8, 2026 at 15:30). Run `Program\StepMania.exe` or `Program\ITGmania.exe`.

To change the game's code: edit the files in its folder inside `.\source` and run the build again.

### About the download

`get-source` clones the official repositories over HTTPS (`github.com/stepmania/stepmania`, `github.com/itgmania/itgmania`) **with their submodules**, as a shallow clone (latest commit only: smaller and faster, all that is needed to build). It never downloads into a folder that already has files.

You do **not** need git: it uses the one it finds (PATH, Program Files, GitHub Desktop) or, if there is none, downloads a portable MinGit into `.\tools\git` (official git-for-windows release, SHA-256 verified).

**Forks and other repositories**: choose `[3] Other repository` in the menu and paste its HTTPS address (e.g. `https://github.com/SomeUser/stepmania-fork`), or set `REPO_URL` in `2. get-source.bat`, or run `"2. get-source.bat" -Url <URL>`. It must be a public repository; it is cloned the same way, with submodules. That code is your choice to trust: the builder verifies the toolchain, not the source.

To add the other game, just download it too: each source has its own folder and its own output folder (and, while you keep `_work`, its own build cache in `_work\<name>\`, so switching between them does not recompile everything).

If an older version of the builder left a source pasted directly in `source\`, `2. get-source.bat` offers to **move** it into its own folder (e.g. `source\stepmania\`) before downloading another one. Nothing inside it is changed.

## What you will see while it works

Long tasks never run silently:

| Task | What is shown |
|---|---|
| Every script | Numbered steps, e.g. `==> [3/5] Configuring CMake` |
| Downloads (toolchain, MinGit) | A percentage bar per big file, and one bar for the whole SDK download (`Downloading SDK [####------] 38%  120 MB of 317 MB`) |
| Extracting archives | `Extracting [########----] 61%  3100/5100 files` |
| Compiling | `Building [#######-----] 55%  735/1335  01:05` (the counter comes from Ninja) |
| Copying the source, running installers, Defender scan | An "in progress" spinner with the elapsed time: `/ Copying source files  (in progress, 00:12)` |
| Checking signatures / hashing files | `Hashing files [####------] 40%  6200/15541 files` |
| Downloading the source (git) | git's own progress (`Receiving objects: 62%`), one block per submodule |

If the percentage or the spinner keeps moving, the script is working, even when a step takes several minutes. The first build is the slowest one.

## Changing options from the .bat files

Each `.bat` starts with a **SETTINGS** section. Open it with any text editor (Notepad is fine), change a value, save, and double-click the file. No command line needed.

```bat
rem Build configuration: Release | Debug | RelWithDebInfo | MinSizeRel
set "CONFIG=Release"

rem Launch the game when the build finishes.
set "RUN=0"
```

| File | Settings |
|---|---|
| `3. build.bat` | `CONFIG`, `NAME`, `SOURCE`, `DOWNLOAD`, `RUN`, `CLEAN`, `SYNC_ONLY`, `NO_PACKAGE`, `NO_PORTABLE`, `SKIP_VERIFY`, `DELETE_WORK` (`ask`/`yes`/`no`), `PAUSE_AT_END` |
| `2. get-source.bat` | `GAME`, `REPO_URL`, `FOLDER_NAME`, `TARGET`, `FULL_HISTORY`, `USE_MINGIT`, `PAUSE_AT_END` |
| `1. setup-toolchain.bat` | `DEFENDER` (`ask`/`scan`/`skip`), `FORCE`, `SDK_VERSION`, `MSVC_MINOR`, `TOOLCHAIN_DIR`, `PAUSE_AT_END` |
| `verify-toolchain.bat` | `DEFENDER` (`ask`/`scan`/`skip`), `TOOLCHAIN_DIR`, `PAUSE_AT_END` |

- On/off settings use `1` (yes) or `0` (no). Text settings can be left empty to use the default.
- Paths with spaces are fine; do not add extra quotes.
- Anything typed on the command line (e.g. `"3. build.bat" -Config Debug -Run`) is added at the end and **replaces** the matching setting for that run.
- `PAUSE_AT_END=0` closes the window when finished (useful for automation); the exit code of the script is preserved.
- `DOWNLOAD=itgmania` (or `stepmania`) in `3. build.bat` downloads that game without showing the menu when `source\` is empty.
- `SOURCE=itgmania` in `3. build.bat` always builds `source\itgmania` without asking (any folder name inside `source\`, or a full path).
- `FOLDER_NAME=sm-test` in `2. get-source.bat` downloads into `source\sm-test` instead of the repository name.

## Folder layout

```
builder-folder\
  source\                 <- your sources, one folder each (never modified by the builder)
    stepmania\            <-   e.g. StepMania
    itgmania\             <-   e.g. ITGmania
    stepmania-fixes\      <-   e.g. a fork
  toolchain\              <- portable MSVC + SDK + CMake + Ninja (created by setup-toolchain)
  tools\git\              <- portable git, only if you had none (created by get-source)
  _work\                  <- internal: working copy + build cache (you are asked after each build whether to delete it)
  stepmania-MMDDYYYY-HHMM\ <- the clean builds (output): <source name>-<US date>-<time>
  1. setup-toolchain.bat  <- step 1: downloads and verifies the toolchain (once)
  2. get-source.bat       <- step 2: downloads StepMania, ITGmania or a fork into source\<name> (only if you need one)
  3. build.bat            <- step 3: builds the game
  verify-toolchain.bat    <- optional: checks the toolchain was not tampered with
  scripts\                <- the PowerShell scripts the .bat files run; do not delete
                             (.last-source in it remembers the last source you built)
    build.ps1  get-source.ps1  setup-toolchain.ps1  verify-toolchain.ps1
    progress.ps1          <- shared helpers (progress bars, spinner)
```

You only ever need to touch the four `.bat` files (renaming them, e.g. removing the numbers, is fine). If you prefer PowerShell, the scripts can be run directly, e.g. `.\scripts\build.ps1 -Run`.

## What a clean build contains

| Included | Not included |
|---|---|
| `Program\` (the game `.exe`, its `.vdi`, DLLs) | `src`, `extern`, `CMake`, `Build`, `Installer`, `Manual`, `Utils`, `Xcode`, `icons`, `_assets` |
| `portable.ini` (portable mode: `Save`, `Cache`, `Logs` live inside the folder) | Files in the repo root (`CMakeLists.txt`, `.git*`, `README.md`...) |
| `Announcers`, `BackgroundEffects`, `BackgroundTransitions`, `BGAnimations`, `Characters`, `Courses`, `Data`, `Docs`, `NoteSkins`, `Scripts`, `Songs`, `Themes` | `mapconv.exe`, `.map` files, `Themes\_Installer`, `.git` files of submodule themes |

Every build gets its own folder (the time is part of the name), so older builds are never overwritten. A build that starts in the same minute as the previous one refreshes that folder. With `-Name` / `NAME=`, the same folder is refreshed on every build and its `Save`, `Cache`, `Logs` and `Screenshots` are kept.

ITGmania's optional `Texture Font Generator.exe` is not built (it needs MFC, which is not part of the portable toolchain).

## Command-line options

These options go after the `.bat` name (`"3. build.bat" -Run`) or after `.\scripts\build.ps1`.

### `build`

| Option | Description |
|---|---|
| `-Config Release\|Debug\|RelWithDebInfo\|MinSizeRel` | Build configuration (default `Release`) |
| `-Name finished` | Output folder name: `<source name>-finished` (e.g. `stepmania-finished`) instead of the date and time; that folder is refreshed on every build |
| `-Download stepmania\|itgmania` | If there is no source at all, download that game without asking |
| `-Run` | Launch the game when done |
| `-Clean` | Rebuild from scratch (needed once after moving or renaming this folder) |
| `-SyncOnly` | Only refresh the internal working copy |
| `-NoPackage` | Build, but do not create the clean folder |
| `-Source <name or path>` | Which source to build: a folder name inside `source\` (e.g. `-Source itgmania`) or a full path. Default: the only one, or a menu when there are several |
| `-NoPortable` | Ignore `.\toolchain` and use an installed Visual Studio 2022 |
| `-SkipVerify` | Skip the quick integrity check of the toolchain before building |
| `-DeleteWork ask\|yes\|no` | After a successful build: ask whether to delete `_work` (default; Enter = keep), delete it (`yes`: the next build compiles everything again), or keep it (`no`: the next build only recompiles what changed). `-KeepWork` = `no`. `_work` is always kept with `-SyncOnly` / `-NoPackage` and when the build fails |

### `get-source`

`-Game stepmania|itgmania`, `-Url <https URL>` (another repository, e.g. a fork; not together with `-Game`), `-FolderName <name>` (folder inside `source\`; default: the repository name), `-Target <folder>` (exact empty folder instead), `-FullHistory` (download the whole git history), `-UseMinGit` (ignore installed git).

### `setup-toolchain` and `verify-toolchain`

`setup-toolchain`: `-Defender ask|scan|skip` (`-SkipDefender` = `skip`), `-Force`, `-SdkVersion <n>`, `-MsvcMinor <14.xx>`, `-ToolchainDir <folder>`.
`verify-toolchain`: `-Defender ask|scan|skip` (`-SkipDefender` = `skip`), `-ToolchainDir <folder>`.

## How it works

The games' CMake writes the executable into `<source>\Program`, so building in place would modify your source. The builder mirrors the chosen source (without `.git`) into `_work\<name>\stage`, builds there with Ninja into `_work\<name>\build\<Config>`, and then copies only the files a release build needs into the output folder. Finally it asks whether to delete `_work\<name>\` (and `_work\` when it is empty). If you keep it, each source keeps its own `_work\<name>\` and its next build is incremental. (Older versions used `_work\stepmania` and `_work\build`; they are removed automatically once, and that first build recompiles everything.)

If the source is a git repository and git is available, the build is stamped with the real commit (e.g. `ITGmania1.3.0-BETA-git-8a3bf88`) by giving the working copy a small `.git` pointer file to your repository (read-only use; nothing is copied).

## Security

`setup-toolchain.ps1` downloads only over HTTPS from `download.visualstudio.microsoft.com` (via `aka.ms/vs/17/release/channel`) and the official GitHub releases of Kitware/CMake and ninja-build/ninja. It:

1. checks the SHA-256 of every downloaded file against the Microsoft manifest or the GitHub API digest;
2. checks that every downloaded MSI and every `.exe`/`.dll` extracted from MSVC and the SDK has a valid Authenticode signature from Microsoft Corporation (otherwise it aborts);
3. writes `toolchain\inventory.json` with the SHA-256 of every file, so tampering can be detected later;
4. scans the folder with Microsoft Defender, unless you choose to skip it when asked (or set `DEFENDER=skip`).

`build.ps1` re-checks the key tools (`cl`, `link`, `rc`, `mt`, `cmake`, `ninja`) against the inventory before every build, and `verify-toolchain.bat` checks the whole folder again (hashes, signatures and, unless skipped, a Defender scan).

`get-source.ps1` clones the two official repositories, or a repository whose HTTPS address you type yourself (e.g. a fork), plus the submodules that repository declares. A repository you choose is code you decided to trust: the builder does not audit it. If it needs a portable git, it downloads MinGit from the official `git-for-windows/git` GitHub release and refuses to use it unless the SHA-256 published for that release matches.

Notes:
- The Windows SDK "Store Apps Tools" package is not installed in full (it contains unsigned MSIX/Store tools); only `rc.exe`, `rcdll.dll`, `mt.exe` and its dependency are kept.
- At the time of writing, the main Microsoft manifest does not match the hash declared by Microsoft's own channel. The script reports it as a warning and relies on the per-package hashes and signatures instead.
- These checks prove the binaries are the ones published and signed by their vendors and were not altered. They are not an audit of the source code you build.

## What you can delete

| Item | Safe to delete? |
|---|---|
| `source\` and the folders inside it | **No**: it is your code (if you only downloaded one, you can download it again). Deleting one source folder is fine if you no longer need it; also delete its `_work\<name>\` to free space |
| The four `.bat` files and the `scripts\` folder | **No** |
| `toolchain\` (`msvc`, `sdk`, `cmake`, `ninja`) | Not if you want to keep building (`1. setup-toolchain.bat` can recreate it) |
| `toolchain\inventory.json` | Not if you use the portable toolchain (`build.ps1` refuses to build without it, unless you pass `-SkipVerify`) |
| `tools\git\` | Yes. It is downloaded again if you need it |
| `_work\` | Yes (the builder offers to delete it after each build). It is regenerated; the next build is just slower because it compiles everything |
| `toolchain\_downloads\` | Yes. Only a download cache |
| `*.log` | Yes |
| `<source name>-MMDDYYYY-HHMM\` (e.g. `stepmania-11142026-1530\`) | Yes, but copy its `Save\` first if you played in it (preferences, profiles, scores). Since every build creates a new folder, delete the old ones from time to time |

## Moving or renaming this folder

All paths are relative to the scripts, so you can rename or move the folder (even to another PC). Run `"3. build.bat" -Clean` once afterwards, because the internal build cache stores absolute paths.

## Troubleshooting

- **"No source code in ... source"**: run `2. get-source.bat`, or paste the source into its own folder inside `.\source` (that folder must contain `CMakeLists.txt` and `src\`).
- **"Several sources found ... Choose one with -Source <name>"**: this appears only when there is no console to show the menu. Set `SOURCE=<folder name>` in `3. build.bat`.
- **"A source named '...' already exists"** (get-source): choose `[1]` to keep it and download the new one with another name, or `[2]` to delete it and download it again.
- **"The source is missing N git submodule(s)"** (or CMake errors such as `extern/mbedtls does not contain a CMakeLists.txt` / `pnglibconf.h.prebuilt does not exist`): the source was downloaded with GitHub's "Download ZIP", which leaves `extern\...` empty. Fix it in one of these ways:
  - delete that source folder and run `2. get-source.bat` (choose `[3]` and paste the URL for a fork);
  - or clone it yourself: `git clone --recursive <URL> source\<name>`;
  - if the folder is already a git clone, `3. build.bat` offers to download the missing submodules for you (or run `git submodule update --init --recursive` inside it).
- **"Target folder is not empty"** (get-source with `-Target`): that exact folder already has files. Rename or empty it first; nothing is overwritten.
- **Download fails**: check your internet connection and run it again. Nothing half-downloaded is left behind.
- **Build fails with an Integrity error**: a toolchain file changed. Run `verify-toolchain.bat`; if you do not recognise the change, reinstall with `"1. setup-toolchain.bat" -Force`.
- **Sound feels delayed (StepMania)**: StepMania's default Windows driver list is `WaveOut,DirectSound-sw,WDMKS,Null` (ITGmania's is `DirectSound-sw,WASAPI,WaveOut,WDMKS,Null`). In `Save\Preferences.ini` try `SoundDrivers=DirectSound-sw` or `SoundDrivers=WDMKS` (game closed).
- **StepMania shows "String 'SortOrder::Meter' is missing" (also TopP1Grades, TopP2Grades) in the music wheel**: this is an upstream bug of the StepMania source (the engine added those sort orders without adding their texts). It is not caused by the builder. Add these three lines at the end of the `[SortOrder]` section of `source\<name>\Themes\_fallback\Languages\en.ini` (and your language's file) and build again:

  ```ini
  TopP1Grades=P1 Top Grades
  TopP2Grades=P2 Top Grades
  Meter=Meter
  ```
- **Moved the folder and CMake complains about the cache**: run `"3. build.bat" -Clean`.
