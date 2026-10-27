@echo off
setlocal
rem Reporting preview only. Bypass is limited to this PowerShell process.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0App\Scripts\Start-SfsuUsmt.ps1" %*
set "sfsuExit=%errorlevel%"
if not "%sfsuExit%"=="0" (
    echo.
    echo SFSU USMT could not finish. Review the error above and the Logs folder.
    if "%~1"=="" pause
)
exit /b %sfsuExit%
