# Changelog

Newest first. Each entry says what changed for someone playing. The version is the join
scripts' (`$joinVersion` in join.cmd, `JOIN_VERSION` in join.py); a server can ask for a newer
one (`roe_server set join-min-version`). The server's own changes are in its repository's
CHANGELOG.md.

## 0.9 (2026-11-19)

- join-gui.cmd: pick the Ring of Elysium folder itself and tick **DirectX 12** for the DX12
  version (its XVersion folder); an XVersion folder picked directly is recognised. It says which
  version is missing in the folder. The full folder is saved as before, so join.cmd agrees.
- GM accounts: the server's admin page (bot settings, matchmaking, status, the log of GM
  actions) opens in the browser without a password: `join.cmd admin`, `python3 join.py --admin`,
  or in join-gui.cmd **Advanced > Open the admin page** (shown only for an account with GM rights
  on the selected server). The scripts ask the server for a one-time login link that works for
  one minute.
- The player counts per region (STATS) are asked at most every 10 seconds per server, to keep
  the server's load low.
- The voice DLL (`voice/GCloudVoice.dll`) is built locally and committed by hand; the GitHub
  Actions workflow no longer runs on push and starts only by hand.

Licensed under GPL-3.0 (`LICENSE`).

The first version in its own repository (before, the files were part of the server's
repository, which keeps their history).

- join-gui.cmd: join a server in a window (servers with who plays in each region, accounts, game
  folder, voice chat, Play; firewall rules, account backup and the log under Advanced). It needs
  join.cmd next to it and uses its functions.
- join.cmd (Windows console) and join.py (Linux, Steam with Proton or GE-Proton): game folder and
  version check, the servers joined before, accounts with a secret key per account
  (`%APPDATA%\roe-join`, `~/.config/roe-join`), export and import of every account into one file,
  the server's name and players per region (every region with its numbers after the login and
  every 30 s while the game runs), a version check against the server.
- join.cmd's firewall rules: the game may reach only the servers joined and the addresses the
  server lists, with a check that the rules are there and that no block rule of another program
  names the game.
- Voice chat, on by default (asked once): our GCloudVoice.dll goes into the game folder while the
  game runs and the original is put back afterwards (kept in `roe-join-backup` in the game
  folder). The DLL is looked for next to the script, then in its `voice` folder, then asked for.
- voice/: the replacement GCloudVoice.dll (Opus, the server's voice relay over UDP 10101), with a
  test that drives it the way the game does and tests of its platform-independent core.
