@echo off
rem Windows launcher: run-qemu.sh is a Linux script and must run inside WSL.
rem   run-qemu.cmd prod            boot the production image (Ctrl-A X to quit)
rem   run-qemu.cmd prod --fresh    start from a pristine disk
wsl.exe -d Ubuntu --cd "%~dp0." -- bash ./run-qemu.sh %*
