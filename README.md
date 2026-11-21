# StepMania Windows Builder

A small Windows toolkit to build [StepMania](https://github.com/stepmania/stepmania), [ITGmania](https://github.com/itgmania/itgmania) or any StepMania Fork (except OutFox lol) from source and get a **clean, ready-to-play build folder**, without touching your original source and without installing Visual Studio or git.

- **A window for everything** (`StepMania Builder.bat`): it guides you the first time (toolchain, then a source), builds with a progress bar, checks for updates, and has light and dark themes. The same steps are also available as `.bat` files in `cli\` for the console.
- **Foolproof**: no source yet? The builder downloads StepMania, ITGmania or a fork for you.
- Your source code is **never modified**.
- Uses a **portable toolchain** (MSVC v143 + Windows SDK + CMake + Ninja) downloaded into this folder. Nothing is installed on your system.
- Every download is **verified** (SHA-256 + Microsoft Authenticode signatures).
- **You choose how tidy it is**: keep the internal working folder (`_work`) and the next build is **incremental** (only what you changed is recompiled, ideal while testing code changes); delete it and the folder stays clean, but the next build compiles everything again.
- **You always see that it is working**: numbered steps (`[3/5]`), percentage bars for downloads, compilation and packaging, and an "in progress" spinner with the elapsed time for tasks whose length cannot be known.
- The game (StepMania or ITGmania) is **detected automatically** from the source.

## Requirements

- Windows 10/11 x64
- Windows PowerShell 5.1 (included with Windows)
- Internet access the first time (toolchain: about 600 MB download, about 1.5 GB on disk; source: about 600 MB)

## Quick start

1. Double-click **`StepMania Builder.bat`**.
2. The first time, it explains that it needs its **toolchain** (the compilers) and offers to install it: about 600 MB, once, every file checked, nothing installed on Windows. Say **Yes** (or press **Install toolchain** in the yellow note later).
3. Press **Download a source...** and pick StepMania, ITGmania or the address of a fork. Each one goes into its own folder inside `source\`. (Already have one? Paste it into its own folder inside `source\` and press **Refresh**.)
4. Press **Build**. When it finishes, press **Play**.

The result is in a folder with the **same name as the source**, always: `source\stepmania-fixes` -> `.\stepmania-fixes\`, `source\itgmania` -> `.\itgmania\`. Its game is `Program\StepMania.exe` or `Program\ITGmania.exe`.

Each source has **one** build folder. Building again refreshes it and keeps its `Save` (preferences, profiles, scores), `Cache`, `Logs` and `Screenshots`, and **everything you added to it yourself** (themes, noteskins, songs, announcers...). Only the files that come from the source are updated; a file that the source removed in a newer version is removed from the build too, but only if the builder had put it there (the build keeps that list in `.builder-files.txt`). The build **remembers the commit it was made from** (in `.builder-build.json`). When the source moved to another commit (e.g. after **Check updates > Update**), the Builds list marks it **Outdated** and Build asks whether to **update** it: **Yes** refreshes it (same folder name; its Save and your files are kept); **No** builds nothing and leaves it as it is.

To change the game's code: edit the files in its folder inside `.\source` and build again.

Tip: **Help > Create desktop shortcut** puts a "StepMania Builder" icon on your desktop. To add another source later, choose **+ Download another source...** at the end of the Source list. The toolchain check (**Verify**) and the other maintenance options are under **Advanced**. More in [Graphical interface](#graphical-interface).

> **Do not use GitHub's "Download ZIP" button.** ZIP files do not include the git submodules (`extern\mbedtls`, `extern\libpng`...), so the build cannot work. Use **Download a source...** (it also downloads forks) or `git clone --recursive <URL>`. The builder detects a source without submodules and tells you how to fix it.

### Command line (`cli\` folder)

The same steps are in `cli\` as `.bat` files, for those who prefer a console or want to automate. Each one starts with a **SETTINGS** section (see [Changing options from the .bat files](#changing-options-from-the-bat-files)). Run them in this order:

| Step | File | When |
|---|---|---|
| 1 | `cli\1. setup-toolchain.bat` | **Once**, to get the portable toolchain |
| 2 | `cli\2. get-source.bat` | **Only if you do not have StepMania or ITGmania in `source\` yet**, or to add another one (it downloads it for you into its own folder). If you already pasted the source there, skip this step |
| 3 | `cli\3. build.bat` | Every time you want to build |

(`cli\verify-toolchain.bat` has no number: it is an optional check that you can run whenever you want.)

1. **Get the toolchain** (one time): double-click `cli\1. setup-toolchain.bat`.
   When it reaches the Microsoft Defender scan (it can take several minutes) it asks you to **continue** or **skip** it. Skipping is less secure: the files are still checked by hash and Microsoft signature, but not scanned for malware. To stop being asked, set `DEFENDER=scan` or `DEFENDER=skip` inside the `.bat`.

2. **Get the source code** in `.\source`. **This step is only needed if you do not already have StepMania (or ITGmania) in `source\`.** Pick one:
   - **Let the builder download it**: double-click `cli\2. get-source.bat` and choose StepMania, ITGmania, or **another repository such as a fork** (paste its URL). It goes into its own folder: `source\stepmania`, `source\itgmania` or `source\<fork name>`. (If you skip it and `source\` is empty, step 3 offers the same menu, so you cannot get stuck.)
   - **Do it yourself**: paste the source into its own folder inside `source\` (e.g. `source\stepmania\`, the folder that contains `CMakeLists.txt`, `src`, `Themes`...) and skip this step. A single source pasted directly in `source\` also works. A `.git` folder is optional.

   **Several sources side by side**: you can keep as many as you want (e.g. `source\stepmania`, `source\itgmania`, `source\stepmania-fixes`). When there is more than one, `cli\3. build.bat` asks which one to build (Enter = the last one you built), or set `SOURCE=<folder name>` in it. If you download a source whose folder already exists, `cli\2. get-source.bat` warns you and lets you **keep it and download the new one with another name** (e.g. `stepmania-2`) or **delete it and download it again** (you must type `YES`; your changes in it would be lost).

3. **Build**: double-click `cli\3. build.bat`. The result is in the same `<source>` folder as with the window (it asks the same question before updating it; `UPDATE_BUILD=yes|no` answers it for you).

### About the download

`get-source` clones the official repositories over HTTPS (`github.com/stepmania/stepmania`, `github.com/itgmania/itgmania`) **with their submodules**, as a shallow clone (latest commit only: smaller and faster, all that is needed to build). It never downloads into a folder that already has files.

You do **not** need git: it uses the one it finds (PATH, Program Files, GitHub Desktop) or, if there is none, downloads a portable MinGit into `.\tools\git` (official git-for-windows release, SHA-256 verified).

**Forks and other repositories**: choose `[3] Other repository` in the menu and paste its HTTPS address (e.g. `https://github.com/SomeUser/stepmania-fork`), or set `REPO_URL` in `cli\2. get-source.bat`, or run `"cli\2. get-source.bat" -Url <URL>`. It must be a public repository; it is cloned the same way, with submodules. That code is your choice to trust: the builder verifies the toolchain, not the source.

To add the other game, just download it too: each source has its own folder and its own output folder (and, while you keep `_work`, its own build cache in `_work\<name>\`, so switching between them does not recompile everything).

If an older version of the builder left a source pasted directly in `source\`, `cli\2. get-source.bat` offers to **move** it into its own folder (e.g. `source\stepmania\`) before downloading another one. Nothing inside it is changed.

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

## Graphical interface

`StepMania Builder.bat` opens a window that does everything the `cli\` files do, with buttons instead of settings. It runs the same scripts underneath and needs nothing extra (it uses WPF, part of Windows). Hover any `(?)` mark for an explanation, or press **Help** for a short guide (Help also has **Create desktop shortcut**, which puts a "StepMania Builder" icon on your desktop; create it again if you move the folder). Your choices are remembered.

**First start**: if the toolchain is missing, a welcome message explains what it is and offers to install it. Until it is installed, and while there is no source, a yellow note at the top keeps explaining what is missing, with an **Install toolchain** and a **Download a source...** button. So you never need Advanced to get started.

**Compact mode** (the default) shows only what you do every time:

- **Source**: pick which folder of `source\` to build (it starts on the last one you built). The last entry of the list, **+ Download another source...**, opens the download window. **Refresh** looks again after you paste one.
- **Launch the game when done**, **Keep _work** (keep the build cache so the next build is fast) and **Notify me when done** (a Windows notification when a task finishes or fails; click it to open the build folder).
- **Build** shows the current step, a progress bar (with Ninja's `735/1335` counter while compiling) and the elapsed time. **Stop** cancels the running task and everything it started.
- When it finishes: **Play** and **Open folder**. If it fails, the window shows the first error and opens **Details (log)** with the full output.
**Advanced** (the checkbox at the top) adds setup and maintenance:

- **Toolchain**: its status (Not installed / Installed / Verified on a date), **Install** (or **Repair** once installed) and **Verify**, with the **Defender scan** option.
- **Download...**: StepMania, ITGmania or the HTTPS address of a fork, into its own folder (you can choose the folder name). If that folder already exists, it asks whether to keep it and download with another name, or delete it and download again (it asks twice before deleting). A source pasted directly in `source\` is moved into its own folder first, after asking. **Open** opens the selected source folder.
- Build options: **Config** (Release / Debug...), **Name** (adds a name to the output folder: `<source>-<name>`), **Clean** (rebuild everything; one time) and **Copy Save from the last build** (your preferences, profiles and scores go to the new build).
- **Builds**: your finished builds with the commit each one was built from, marked **Outdated** (the source is now at a newer commit: press Build to update it), **Older copy** (a build left by an older version of the builder), **Source deleted** and **Has Save**. **Play**, **Open** and **Delete**. Delete always asks first, shows the build's date and size, warns if it is the current build of its source or has a Save, and moves it to the **Recycle Bin**.

**Check updates** (next to the source, in both modes) compares the selected source with the latest commits of its repository on GitHub, **without downloading anything**. A window shows your commit and the latest one (with dates), the list of new commits (message, author, date), how many files they change and where, the submodules they move, and the files you changed yourself. Then you choose **Update** or **Not now** (**View on GitHub** opens the full comparison).

**Update** never loses your work:

1. every file you changed is copied to `source-backups\<name>-MMDDYYYY-HHMM\`;
2. your changes are put aside, the source moves to the latest commit, and the submodules are updated (only the new commit is downloaded);
3. your changes are re-applied. If the update changed the same lines, the updated file is kept and a message lists those files; your version is in the backup folder, ready to copy back.

Files git does not track (e.g. songs you added) are never touched. It works for sources downloaded with **Download...** / `cli\2. get-source.bat` (or any git clone of a GitHub repository); a pasted copy or a ZIP has no git information to compare. GitHub allows 60 checks per hour without an account. The same is available from a console: `.\scripts\update-source.ps1 -Source <name> -Check` (or without `-Check` to update).

**Theme**: **Auto** (default) follows the light or dark app mode chosen in Windows settings, also when you change it while the window is open; **Light** and **Dark** force one of them. Every window of the builder (and its title bar) follows it.

## Changing options from the .bat files

Each `.bat` in `cli\` starts with a **SETTINGS** section. Open it with any text editor (Notepad is fine), change a value, save, and double-click the file. No command line needed.

```bat
rem Build configuration: Release | Debug | RelWithDebInfo | MinSizeRel
set "CONFIG=Release"

rem Launch the game when the build finishes.
set "RUN=0"
```

| File | Settings |
|---|---|
| `cli\3. build.bat` | `CONFIG`, `NAME`, `UPDATE_BUILD` (`ask`/`yes`/`no`), `SOURCE`, `DOWNLOAD`, `RUN`, `COPY_SAVE`, `CLEAN`, `SYNC_ONLY`, `NO_PACKAGE`, `NO_PORTABLE`, `SKIP_VERIFY`, `DELETE_WORK` (`ask`/`yes`/`no`), `PAUSE_AT_END` |
| `cli\2. get-source.bat` | `GAME`, `REPO_URL`, `FOLDER_NAME`, `TARGET`, `FULL_HISTORY`, `USE_MINGIT`, `PAUSE_AT_END` |
| `cli\1. setup-toolchain.bat` | `DEFENDER` (`ask`/`scan`/`skip`), `FORCE`, `SDK_VERSION`, `MSVC_MINOR`, `TOOLCHAIN_DIR`, `PAUSE_AT_END` |
| `cli\verify-toolchain.bat` | `DEFENDER` (`ask`/`scan`/`skip`), `TOOLCHAIN_DIR`, `PAUSE_AT_END` |

- On/off settings use `1` (yes) or `0` (no). Text settings can be left empty to use the default.
- Paths with spaces are fine; do not add extra quotes.
- Anything typed on the command line (e.g. `"cli\3. build.bat" -Config Debug -Run`) is added at the end and **replaces** the matching setting for that run.
- `PAUSE_AT_END=0` closes the window when finished (useful for automation); the exit code of the script is preserved.
- `DOWNLOAD=itgmania` (or `stepmania`) in `cli\3. build.bat` downloads that game without showing the menu when `source\` is empty.
- `SOURCE=itgmania` in `cli\3. build.bat` always builds `source\itgmania` without asking (any folder name inside `source\`, or a full path).
- `FOLDER_NAME=sm-test` in `cli\2. get-source.bat` downloads into `source\sm-test` instead of the repository name.

## Folder layout

```
builder-folder\
  StepMania Builder.bat   <- opens the window: this is all most people need
  README.md
  source\                 <- your sources, one folder each (never modified by the builder)
    stepmania\            <-   e.g. StepMania
    itgmania\             <-   e.g. ITGmania
    stepmania-fixes\      <-   e.g. a fork
  toolchain\              <- portable MSVC + SDK + CMake + Ninja (created by setup-toolchain)
  tools\git\              <- portable git, only if you had none (created by get-source)
  source-backups\         <- copies of the files you changed, made before each Check updates > Update
  _work\                  <- internal: working copy + build cache (you are asked after each build whether to delete it)
  stepmania-fixes\        <- the clean builds (output): one per source, same name as the source
  cli\                    <- the same steps for the console (each .bat has a SETTINGS section)
    1. setup-toolchain.bat  <- step 1: downloads and verifies the toolchain (once)
    2. get-source.bat       <- step 2: downloads StepMania, ITGmania or a fork into source\<name>
    3. build.bat            <- step 3: builds the game
    verify-toolchain.bat    <- optional: checks the toolchain was not tampered with
  scripts\                <- the PowerShell scripts that do the work; do not delete
                             (.last-source and .gui-settings.json in it remember your last choices)
    build.ps1  get-source.ps1  setup-toolchain.ps1  verify-toolchain.ps1
    gui.ps1               <- the window of StepMania Builder.bat
    update-source.ps1     <- Check updates / Update (compares a git source with GitHub)
    progress.ps1          <- shared helpers (progress bars, spinner)
    builder.ico           <- the builder's icon (window, taskbar, desktop shortcut)
```

The window and the `cli\` files use the same scripts, so you can mix them. Renaming the `.bat` files (e.g. removing the numbers) is fine. If you prefer PowerShell, the scripts can be run directly, e.g. `.\scripts\build.ps1 -Run`.

## What a clean build contains

| Included | Not included |
|---|---|
| `Program\` (the game `.exe`, its `.vdi`, DLLs) | `src`, `extern`, `CMake`, `Build`, `Installer`, `Manual`, `Utils`, `Xcode`, `icons`, `_assets` |
| `portable.ini` (portable mode: `Save`, `Cache`, `Logs` live inside the folder) | Files in the repo root (`CMakeLists.txt`, `.git*`, `README.md`...) |
| `Announcers`, `BackgroundEffects`, `BackgroundTransitions`, `BGAnimations`, `Characters`, `Courses`, `Data`, `Docs`, `NoteSkins`, `Scripts`, `Songs`, `Themes` | `mapconv.exe`, `.map` files, `Themes\_Installer`, `.git` files of submodule themes |

Each source has one build folder, with the same name as the source folder: building again refreshes it and keeps its `Save`, `Cache`, `Logs` and `Screenshots`, plus anything you added yourself (custom themes, noteskins, songs...). The files that come from the source are copied over the build (never mirrored); `.builder-files.txt` inside the build lists them, so a file the source no longer has is removed only if the builder had put it there. `.builder-build.json` remembers the commit the build was made from: when the source moved to another commit, you are asked whether to update the build. Builds made by older versions of the builder (`<source>-<commit>`, `<source>-MMDDYYYY`, `<source>-MMDDYYYY-HHMM`) are recognized: the newest one is renamed to the fixed name the next time you build (after asking), the others show as **Older copy** in the Builds list and can be deleted. With `-Name` / `NAME=`, the folder is `<source>-<name>` instead.

ITGmania's optional `Texture Font Generator.exe` is not built (it needs MFC, which is not part of the portable toolchain).

## Command-line options

These options go after the `.bat` name (`"cli\3. build.bat" -Run`) or after `.\scripts\build.ps1`.

### `build`

| Option | Description |
|---|---|
| `-Config Release\|Debug\|RelWithDebInfo\|MinSizeRel` | Build configuration (default `Release`) |
| `-Name finished` | Output folder name: `<source name>-finished` (e.g. `stepmania-finished`) instead of just `<source name>` |
| `-UpdateBuild ask\|yes\|no` | The source moved to another commit than its build: ask whether to update the build (default; Enter = yes), update it, or build nothing |
| `-Download stepmania\|itgmania` | If there is no source at all, download that game without asking |
| `-Run` | Launch the game when done |
| `-Clean` | Rebuild from scratch (needed once after moving or renaming this folder) |
| `-SyncOnly` | Only refresh the internal working copy |
| `-NoPackage` | Build, but do not create the clean folder |
| `-Source <name or path>` | Which source to build: a folder name inside `source\` (e.g. `-Source itgmania`) or a full path. Default: the only one, or a menu when there are several |
| `-NoPortable` | Ignore `.\toolchain` and use an installed Visual Studio 2022 |
| `-SkipVerify` | Skip the quick integrity check of the toolchain before building |
| `-CopySave` | Copy the `Save` folder (preferences, profiles, scores) of the newest previous build of the same source into the new build (only if the new build has no Save yet) |
| `-DeleteWork ask\|yes\|no` | After a successful build: ask whether to delete `_work` (default; Enter = keep), delete it (`yes`: the next build compiles everything again), or keep it (`no`: the next build only recompiles what changed). `-KeepWork` = `no`. `_work` is always kept with `-SyncOnly` / `-NoPackage` and when the build fails |

### `get-source`

`-Game stepmania|itgmania`, `-Url <https URL>` (another repository, e.g. a fork; not together with `-Game`), `-FolderName <name>` (folder inside `source\`; default: the repository name), `-Target <folder>` (exact empty folder instead), `-FullHistory` (download the whole git history), `-UseMinGit` (ignore installed git), `-IfExists ask|rename|replace|cancel` (what to do when `source\<name>` already exists; default `ask`), `-MoveOld ask|yes|no` (move a source pasted directly in `source\` into its own folder; default `ask`).

### `update-source` (PowerShell only: `.\scripts\update-source.ps1`)

`-Source <name or path>`, `-Check` (only compare, change nothing), `-Json` (also print the result as one `##JSON` line, used by the window).

### `setup-toolchain` and `verify-toolchain`

`setup-toolchain`: `-Defender ask|scan|skip` (`-SkipDefender` = `skip`), `-Force`, `-SdkVersion <n>`, `-MsvcMinor <14.xx>`, `-ToolchainDir <folder>`.
`verify-toolchain`: `-Defender ask|scan|skip` (`-SkipDefender` = `skip`), `-ToolchainDir <folder>`.

## How it works

The games' CMake writes the executable into `<source>\Program`, so building in place would modify your source. The builder mirrors the chosen source (without `.git`) into `_work\<name>\stage`, builds there with Ninja into `_work\<name>\build\<Config>`, and then copies only the files a release build needs into the output folder. Finally it asks whether to delete `_work\<name>\` (and `_work\` when it is empty). If you keep it, each source keeps its own `_work\<name>\` and its next build is incremental. (Older versions used `_work\stepmania` and `_work\build`; they are removed automatically once, and that first build recompiles everything.)

**Version stamp.** The game's version (shown by themes, in `Logs\log.txt`, crash reports and `--version`) gets the source's commit **and its date** (US format):

| Source | Version shown |
|---|---|
| git clone (e.g. downloaded with `cli\2. get-source.bat`) | `5.1.0-git-208bc90-11122026` (commit `208bc90`, last commit on November 12, 2026) |
| no git info (pasted copy, ZIP) | `5.1.0-11122026` (date of the newest file in the source) instead of `5.1.0-UNKNOWN` |

ITGmania keeps its own words: `1.3.0-BETA-git-8a3bf88-11182026`. For a git source, the working copy gets a small `.git` pointer file to your repository (read-only use; nothing is copied). The date is added to the **copy** of `CMake\SMDefs.cmake` in `_work`; your source is not touched. (Without git, CMake still prints its harmless "git was not found on your path" warning.)

## Security

`setup-toolchain.ps1` downloads only over HTTPS from `download.visualstudio.microsoft.com` (via `aka.ms/vs/17/release/channel`) and the official GitHub releases of Kitware/CMake and ninja-build/ninja. It:

1. checks the SHA-256 of every downloaded file against the Microsoft manifest or the GitHub API digest;
2. checks that every downloaded MSI and every `.exe`/`.dll` extracted from MSVC and the SDK has a valid Authenticode signature from Microsoft Corporation (otherwise it aborts);
3. writes `toolchain\inventory.json` with the SHA-256 of every file, so tampering can be detected later;
4. scans the folder with Microsoft Defender, unless you choose to skip it when asked (or set `DEFENDER=skip`).

`build.ps1` re-checks the key tools (`cl`, `link`, `rc`, `mt`, `cmake`, `ninja`) against the inventory before every build, and `cli\verify-toolchain.bat` checks the whole folder again (hashes, signatures and, unless skipped, a Defender scan).

`get-source.ps1` clones the two official repositories, or a repository whose HTTPS address you type yourself (e.g. a fork), plus the submodules that repository declares. A repository you choose is code you decided to trust: the builder does not audit it. If it needs a portable git, it downloads MinGit from the official `git-for-windows/git` GitHub release and refuses to use it unless the SHA-256 published for that release matches.

Notes:
- The Windows SDK "Store Apps Tools" package is not installed in full (it contains unsigned MSIX/Store tools); only `rc.exe`, `rcdll.dll`, `mt.exe` and its dependency are kept.
- At the time of writing, the main Microsoft manifest does not match the hash declared by Microsoft's own channel. The script reports it as a warning and relies on the per-package hashes and signatures instead.
- These checks prove the binaries are the ones published and signed by their vendors and were not altered. They are not an audit of the source code you build.

## What you can delete

| Item | Safe to delete? |
|---|---|
| `source\` and the folders inside it | **No**: it is your code (if you only downloaded one, you can download it again). Deleting one source folder is fine if you no longer need it; also delete its `_work\<name>\` to free space |
| `StepMania Builder.bat` and the `scripts\` folder | **No** (only `scripts\.last-source` and `scripts\.gui-settings.json` can go: they only remember your last choices; without the settings file, the welcome message appears again) |
| `cli\` | Yes, if you only use the window (it only holds the console versions) |
| `toolchain\` (`msvc`, `sdk`, `cmake`, `ninja`) | Not if you want to keep building (`cli\1. setup-toolchain.bat` can recreate it) |
| `toolchain\inventory.json` | Not if you use the portable toolchain (`build.ps1` refuses to build without it, unless you pass `-SkipVerify`) |
| `tools\git\` | Yes. It is downloaded again if you need it |
| `source-backups\` | Yes, once you have copied back anything you need from it |
| `_work\` | Yes (the builder offers to delete it after each build). It is regenerated; the next build is just slower because it compiles everything |
| `toolchain\_downloads\` | Yes. Only a download cache |
| `*.log` | Yes |
| The build folders (e.g. `stepmania-fixes\`) | Yes, but copy its `Save\` first if you played in it (preferences, profiles, scores), and anything you added to it. Builds marked **Older copy** (left by older versions of the builder) can also go |

## Moving or renaming this folder

All paths are relative to the scripts, so you can rename or move the folder (even to another PC). Run `"cli\3. build.bat" -Clean` once afterwards, because the internal build cache stores absolute paths.

## Troubleshooting

- **"No source code in ... source"**: run `cli\2. get-source.bat`, or paste the source into its own folder inside `.\source` (that folder must contain `CMakeLists.txt` and `src\`).
- **"Several sources found ... Choose one with -Source <name>"**: this appears only when there is no console to show the menu. Set `SOURCE=<folder name>` in `cli\3. build.bat`.
- **"A source named '...' already exists"** (get-source): choose `[1]` to keep it and download the new one with another name, or `[2]` to delete it and download it again.
- **"The source is missing N git submodule(s)"** (or CMake errors such as `extern/mbedtls does not contain a CMakeLists.txt` / `pnglibconf.h.prebuilt does not exist`): the source was downloaded with GitHub's "Download ZIP", which leaves `extern\...` empty. Fix it in one of these ways:
  - delete that source folder and run `cli\2. get-source.bat` (choose `[3]` and paste the URL for a fork);
  - or clone it yourself: `git clone --recursive <URL> source\<name>`;
  - if the folder is already a git clone, `cli\3. build.bat` offers to download the missing submodules for you (or run `git submodule update --init --recursive` inside it).
- **"Target folder is not empty"** (get-source with `-Target`): that exact folder already has files. Rename or empty it first; nothing is overwritten.
- **Download fails**: check your internet connection and run it again. Nothing half-downloaded is left behind.
- **Build fails with an Integrity error**: a toolchain file changed. Run `cli\verify-toolchain.bat`; if you do not recognise the change, reinstall with `"cli\1. setup-toolchain.bat" -Force`.
- **Sound feels delayed (StepMania)**: StepMania's default Windows driver list is `WaveOut,DirectSound-sw,WDMKS,Null` (ITGmania's is `DirectSound-sw,WASAPI,WaveOut,WDMKS,Null`). In `Save\Preferences.ini` try `SoundDrivers=DirectSound-sw` or `SoundDrivers=WDMKS` (game closed).
- **StepMania shows "String 'SortOrder::Meter' is missing" (also TopP1Grades, TopP2Grades) in the music wheel**: this is an upstream bug of the StepMania source (the engine added those sort orders without adding their texts). It is not caused by the builder. Add these three lines at the end of the `[SortOrder]` section of `source\<name>\Themes\_fallback\Languages\en.ini` (and your language's file) and build again:

  ```ini
  TopP1Grades=P1 Top Grades
  TopP2Grades=P2 Top Grades
  Meter=Meter
  ```
- **Moved the folder and CMake complains about the cache**: run `"cli\3. build.bat" -Clean`.
- **`fatal error C1083: Cannot open compiler generated file: '': Invalid argument`**: the path is too long for the compiler (260 characters). The builder warns about it before building. Move the builder to a shorter path (e.g. `D:\SMBuilder`) or give the source folder a shorter name, then build again with `-Clean`.
