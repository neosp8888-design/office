@echo off
cd /d G:\StellarBladeModding\Tools\FModel
for /r %%F in (FModel.exe) do (
  start "FModel - Stellar Blade" "%%F"
  exit /b 0
)
echo FModel.exe not found.
pause
