@echo off
rem join-gui.cmd is part of join.cmd since version 1.0: double-click join.cmd for the window.
rem This file only starts it, for one version (shortcuts to join-gui.cmd), then it goes away.
if not exist "%~dp0join.cmd" (
  echo join.cmd is missing next to join-gui.cmd. Download join.cmd from https://github.com/mschnati/roe-os-client
  echo and double-click it: since version 1.0 it is the window too, join-gui.cmd is no longer needed.
  pause
  exit /b 1
)
call "%~dp0join.cmd" --window
