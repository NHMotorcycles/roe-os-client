# roe-os-client: details for advanced users and developers

Everything the [README](README.md) leaves out: the console scripts with their commands and
options, what they do step by step, the voice DLL, building and testing.

## Window or console: join-roe-os.cmd

join-roe-os.cmd is one file with both: the window and the console version run the same functions and
share the settings, accounts and keys. Its batch part decides:

- **The window** when it has no arguments and was not typed in a command prompt: a double-click
  (Explorer runs `cmd.exe /c ""...\join-roe-os.cmd" "`), a shortcut, or `.\join-roe-os.cmd` from PowerShell
  all start cmd.exe with `/c`, a command prompt's own cmd.exe has none. `join-roe-os.cmd --window`
  forces it. The batch part `start`s it minimized (`start /min`) and ends.
- **The console** with any argument (`-Server`, `-Name`, `firewall`, `voice`, `export`,
  `import`, `admin`), or typed in a command prompt without arguments. `join-roe-os.cmd --console`
  forces it, for example from PowerShell.

PowerShell runs a script file (`-File`) only when its name ends in `.ps1`, so the batch part first
writes its own text as `%APPDATA%\roe-join\run-<number>.ps1` (with `type`: `copy` would take a
download's mark along, which `-ExecutionPolicy RemoteSigned` refuses) and runs that; the script
removes copies older than 10 minutes. The firewall step runs as administrator the same way: a
`.ps1` copy of join-roe-os.cmd with `-FirewallStep <file>`, the file naming the rules to create and
remove (JSON, no code).

The window's questions are dialogs, the messages go to its status line, its log is
`%APPDATA%\roe-join\gui.log`. join-gui.cmd (until 0.9 the window, needing join.cmd next to it)
is gone since 1.0: join-roe-os.cmd opens the window.

## Separate files (separate-files/)

For virus scanners that flag the single file (Kaspersky's `HEUR:Trojan.PowerShell.Agent.c` on
the batch and PowerShell file that copies itself to a `.ps1`), `separate-files/` has the same
thing as plain files, like join.cmd and join-gui.cmd before 1.0:

- `join-roe-os.ps1`: all of join-roe-os.cmd's PowerShell part, run directly with `-File`.
- `join-roe-os.cmd`: the batch part without the copy: the same choice of window or console, it
  runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0join-roe-os.ps1"` (Bypass,
  as the old join.cmd: a downloaded `.ps1` has the download's mark, which RemoteSigned refuses).

The launcher passes what the code reads in the environment, as the single file does:
`ROE_JOIN_SELF` (the started launcher), `ROE_JOIN_ARGS`, `ROE_JOIN_WINDOW`, and for these files
`ROE_JOIN_CODE` (the `.ps1`: the window's worker loads it, the firewall step as administrator is
a copy of it). `join-roe-os.ps1` started on its own (Run with PowerShell) sets them as its
join-roe-os.cmd would.

The folder is generated, never edited by hand: after a change of join-roe-os.cmd run
`python3 tools/make_separate_files.py` (`--check` only compares). The tests fail when the folder
differs from what the tool makes.

## The console scripts

### join-roe-os.cmd (Windows)

1. In a command prompt in the folder of join-roe-os.cmd, run `join-roe-os.cmd` (or `join-roe-os.cmd --console` from PowerShell). If Windows shows "Windows protected your PC", click "More info", then "Run anyway".
2. It asks two questions. Your answers are remembered: next time press Enter to keep them, or pick from the list.
   - **Game folder**: where Ring of Elysium is installed, usually `C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium` for the DX11 version or `C:\Program Files (x86)\Steam\steamapps\common\Ring of Elysium\XVersion` for the DX12 version.
   - **Server address**: the first start offers ROE-OS (`roe-os.de`, Enter takes it) and "Enter another server (IP or domain)" for the IP address or domain another host gave you (a domain is kept as you typed it and looked up again at every join). Later starts show the servers you joined before (the last one used on top): choose one with the arrow keys and Enter, or "Enter another server (IP or domain)" at the bottom. `join-roe-os.cmd -Server <address>` skips the list.

   The first time on a server it creates your account. If the server lets you create your character in the game, you pick your name there; otherwise join-roe-os.cmd asks for the name you want to play under. Later starts show your accounts on that server (the last one used on top, each under its current name): choose one with the arrow keys and Enter, or "Create a new account" at the bottom. `join-roe-os.cmd -Name <name>` skips the list: it uses your account of that name, or creates one with it.
3. Windows asks for administrator approval once (and again when you join another server).
4. The game starts. In the game: click **Play, Training, Start Matchmaking**.

What join-roe-os.cmd does:

- It checks that your game is the right version.
- It checks that other launchers did not change your game files. Some change the game's archives (`SFC\Common.sfc`, `SFC\TableBin.sfc`, `SFC\UI.sfc`, `data_dyn.sfc`, `data_org_dyn.sfc`: menus, lobby banners and images, chat texts, the intro video), the lobby room's caches (`Cache\otherbin.sfc`, `Cache\Data\world\ActorCreationScreen\ActorCreationScreen.sfc`), `GCloudVoice.dll`, or add files the game loads (`data_exp.vfs`, proxy DLLs such as `dinput8.dll`, `version.dll`, `winmm.dll`, `dxgi.dll`). join-roe-os.cmd compares those files with the Steam install (size and SHA-256; an XVersion folder uses its parent's archives and has its own `GCloudVoice.dll`; ours is expected while voice chat is on) and looks for the added ones. Only these files are hashed (about 290 MB, around a second on the first start); the hashes are kept by size and write time in `%APPDATA%\roe-join\file-check.json`, so later starts take a few milliseconds. When one differs it names it and says what to do: Steam's Verify integrity of game files for changed or missing ones (Ring of Elysium > Properties > Installed Files), deleting the added ones (Steam's check leaves them), then starting again. The game starts only if you answer yes to "Start the game anyway?" (the window asks the same). Backup folders other tools leave in the game folder are no problem. `join-roe-os.cmd --skip-file-check` leaves the check out (for players who changed files on purpose); join-roe-os.py has `--skip-file-check` too and checks the same files in a Proton install (`~/.config/roe-join/file-check.json`).
- If you want (it asks once), it adds Windows Firewall rules so the game can only talk to the servers you joined and to your own computer, nothing else on the internet. The server also tells join-roe-os.cmd every other address its matches use, and the rules follow that list at each join. This is what needs the administrator approval, only when the allowed addresses change. To see the rules and the servers they allow, open a command prompt in the folder of join-roe-os.cmd and run `join-roe-os.cmd firewall`; `join-roe-os.cmd firewall off` removes them and stops adding them, `join-roe-os.cmd firewall on` turns them back on, and `join-roe-os.cmd firewall reset` removes all of them (the next join allows only its own server). After that step join-roe-os.cmd checks that the rules are really there and on, and that no block rule of another program (another launcher, or a "blocked" answer to the Windows Firewall popup) names the game; it removes those with the same approval. If the approval prompt was declined or never appeared (User Account Control off, a standard Windows account) or a policy keeps a block rule, it says so and asks before starting the game: then right-click join-roe-os.cmd > **Run as administrator** (run that way, it sets the rules without a prompt), or turn the rules off with `join-roe-os.cmd firewall off`.
- For a new account the server gives you a secret key, which join-roe-os.cmd saves on your PC (`%APPDATA%\roe-join\<server>\accounts.json`, with the account's name). Next time it uses the key to log you in, so nobody else can play under your name. To play with the same accounts on another PC, run `join-roe-os.cmd export` (it writes `roe-join-accounts.json` with every server's accounts, keys and certificates; `join-roe-os.cmd export D:\file.json` picks the file) and `join-roe-os.cmd import <file>` on the other PC: it adds the accounts it does not have, keeps the more recently used one of an account on both, and asks before taking another certificate for a server. The file holds your keys: keep it private and delete it afterwards.
- Voice chat is on by default: on the first start join-roe-os.cmd asks once "Use voice chat? (y/n)" (Enter: yes). It needs our [GCloudVoice.dll](https://github.com/mschnati/roe-os-client/raw/main/voice/GCloudVoice.dll), a separate download: put it into a folder `voice` next to join-roe-os.cmd (the server package has the same folder), or anywhere else and enter that folder when join-roe-os.cmd asks for it. Once found, join-roe-os.cmd remembers the DLL's path and uses it at every start without asking; only when that file is gone it asks for the folder again. Enter without a folder starts without voice this time (after the first yes, the question comes again next start). A no is remembered too. join-roe-os.cmd puts that `GCloudVoice.dll` into the game folder you start while the game runs. The original is saved in the folder `roe-join-backup` inside the game folder (with a README.txt; to put it back by hand, copy its `GCloudVoice.dll` into the game folder) and put back when the game exits; after a crash or a closed window, the next start puts it back first, also when the game's DLL was deleted. A game that runs already is never changed. It never uses the game's own GCloudVoice.dll. `join-roe-os.cmd voice off` turns voice chat off, `join-roe-os.cmd voice on` back on and asks for the DLL's folder again (Enter keeps it). If join-roe-os.cmd says it could not put the original back, close the game and start join-roe-os.cmd again, or in Steam: Ring of Elysium > Properties > Installed Files > Verify integrity of game files.
- It starts the game, connected to the server.

If join-roe-os.cmd says the name is taken, pick another one. If you lost your key, ask the host to reset your name.

**On Linux** (Steam with Proton or GE-Proton): download [join-roe-os.py](https://github.com/mschnati/roe-os-client/blob/main/join-roe-os.py) the same way and run `python3 join-roe-os.py` in a terminal (it needs python3, nothing else). It asks the same questions, finds the game in any Steam library (also Flatpak and Snap Steam) and starts it with the Proton that last ran the game, else the newest GE-Proton, else the newest Proton from Steam. `python3 join-roe-os.py --proton /path/to/proton` (or `PROTON=...`) picks another one; `--game` answers the game question up front, `--server` skips the server list as `-Server` does, `--name` picks the account as `-Name` does; `--voice on|off` turns voice chat on or off (as on Windows, with the backup in `roe-join-backup` in the game folder; `--voice on` also asks for the DLL's folder again); `--dry-run` only shows what it would do; `--help` lists the rest. If it finds no Proton, install GE-Proton (for example with ProtonUp-Qt) or any Proton in Steam. The server and account lists work as on Windows (arrow keys and Enter; a numbered list when the input is not a terminal). Your keys are kept in `~/.config/roe-join`, the same files as `%APPDATA%\roe-join` on Windows, so you can copy them between the two; `--export [FILE]` and `--import FILE` read and write the same backup file as `join-roe-os.cmd export` and `import`. There is no firewall step on Linux: the game can reach the internet.

### The window's game folder

The window shows the Ring of Elysium folder and a **DirectX 12** box: checked, the game starts
from its `XVersion` folder, unchecked from the folder itself. An `XVersion` folder picked
directly becomes its parent with the box checked. It saves the resulting full folder as
`client` in roe-join.json, the same setting the console asks for, so both agree, and says
which version is missing when the folder has no `Europa_Client.exe` for the choice.

### The admin page (GM accounts)

`join-roe-os.cmd admin` (with `-Server` and `-Name` before it, as for a join), `python3 join-roe-os.py --admin`
(with `--server`, `--name`) and the window's **Advanced > Open the admin page** open the
server's admin page in the default browser. The script asks the account service for the
account's role (`ROLE <key>`: `OK gm` or `OK player`; the window asks it for every saved
account when the server is selected and shows the button only for a GM) and then for a one-time
web ticket (`WEB <key>`: `OK <ticket> <url>`, 60 s, single use, GM accounts only). The page is
at the address the server names (`roe_server set admin-url URL`), else at
`https://admin.<the server's domain>`; a server reached by its IP address without an admin URL,
one without the page (`NONE`) or an older one (`INVALID`) gets a clear message. The server checks
the GM rights again at the login and at every change, so the hidden button is only convenience.

### Start through Steam (Linux only)

join-roe-os.cmd has no Start through Steam (removed for virus scanners: no edits of Steam's
settings, no closing of Steam); start it yourself. On Linux `python3 join-roe-os.py --steam-setup [off]`
(with `--server`, `--name`),
launch option `python3 "/path/join-roe-os.py" --steam %command%`. There `%command%` is Steam's whole
chain (reaper, the Steam Linux Runtime, Proton, then SLauncher.exe); join-roe-os.py runs it with
`Europa_Client.exe` and our arguments in place of SLauncher.exe and its arguments, so Steam's
Proton and prefix are used. A failure without a terminal shows a message with zenity, kdialog or
notify-send when one exists.

## The voice DLL

The game's voice chat (party and squad, and the match's proximity channel) ran over Tencent's
GVoice servers, which are gone. [voice/GCloudVoice.dll](https://github.com/mschnati/roe-os-client/raw/main/voice/GCloudVoice.dll)
replaces the game's `GCloudVoice.dll`; join-roe-os.cmd and join-roe-os.py put it into the game
folder while the game runs (they ask once) and put the original back afterwards. It talks to the
server's voice relay (UDP port 10101). In the game, the voice settings work as before: free talk
or push-to-talk, channel Team or All, volumes. Its log is `GCloudVoice.log` next to the DLL in the
game folder. The protocol between the DLL and the relay:
[docs/VOICE-PROTOCOL.md](https://github.com/mschnati/ring-of-elysium-open-source/blob/main/docs/VOICE-PROTOCOL.md)
in the server's repository.

## Build the voice DLL

On Windows with Visual Studio 2022 (the C++ tools), from this folder:

```bat
cmake --preset windows-release
cmake --build --preset windows-release
ctest --preset windows-release
```

`build\windows-release\bin\RelWithDebInfo\GCloudVoice.dll` is the DLL. CMake fetches its
dependencies itself (Opus 1.5.2, GoogleTest for the tests). The DLL's own test (`Voice.Dll`) drives
it the way the game does against a fake relay; `roe_voice_tests` tests the platform-independent
core (`voice/core`: protocol, jitter buffer, mixing, the client state machine), also on Linux
(`cmake --preset linux-debug`). When the voice sources change, build the DLL as above and commit it as
`voice/GCloudVoice.dll` (the server repository's `tools/build_windows.sh` builds it too, from WSL;
the DLL lands next to roe_server.exe). Nothing builds or commits it for you: the GitHub Actions
workflow runs only when started by hand (Actions tab, "Run workflow"), and such a run only
builds and tests, it commits nothing.

The server's repository has this folder as `client/` and builds its voice relay with
`voice/core` from here, so the protocol code exists once.

## Tests

```sh
python3 -m unittest discover -s tests -p test_join.py
```

join-roe-os.py against fake Steam trees and game folders (the game file check on a fake install with original, changed, missing and added files and its cache); in WSL also join-roe-os.cmd's functions (console
and window, no window shown) through `powershell.exe`, and its batch part's choice of window or
console through `cmd.exe` (elsewhere those skip), and the same for separate-files/ (its launcher's
choice, a real start of its join-roe-os.cmd with a download's mark on the `.ps1`, the window's
code from its `.ps1`); separate-files/ must match what tools/make_separate_files.py makes. The test that compares the version and
URL with the server's runs only inside the server's repository.
