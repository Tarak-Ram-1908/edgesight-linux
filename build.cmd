@echo off
rem Windows launcher: build.sh is a Linux script and must run inside WSL.
rem   build.cmd prod | build.cmd dev
wsl.exe -d Ubuntu --cd "%~dp0." -- bash ./build.sh %*
