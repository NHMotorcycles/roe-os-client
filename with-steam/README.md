# join-roe-os.cmd with Start through Steam

The same join script as [../join-roe-os.cmd](../join-roe-os.cmd), plus starting it from Steam's
**Play** button, set up from the script itself:

- the window: **Set up starting through Steam** (sets the launch option in Steam for the selected
  server and account, closes and restarts Steam if needed; **Turn off** removes it)
- the console: `join-roe-os.cmd steam-setup` (and `steam-setup off`)

Steam's Play button then opens the window, which starts the game after a 3 s countdown and closes
when the game exits; Steam counts the playtime.

**Some virus scanners (Kaspersky) flag this file** because it changes Steam's settings
(localconfig.vdf) and closes Steam. If yours does, use [../join-roe-os.cmd](../join-roe-os.cmd)
and set the launch option by hand (main README, "Start it from Steam").

Download [join-roe-os.cmd](join-roe-os.cmd) ("Download raw file") and use it instead of the main
one. Accounts, servers and settings are the same for both.
