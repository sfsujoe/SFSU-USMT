@echo off
setlocal
rem Profile discovery and folder preparation only. USMT is not connected.
rem Bypass is limited to this PowerShell process; this launcher does not auto-elevate.
rem Normal launch shows the existing application/sign-in form without a persistent console.
rem Argument-based diagnostic commands remain synchronous and visible.
if not "%~1"=="" goto commandline
if not exist "%~dp0App\Scripts\Start-SfsuUsmt.ps1" goto missingapp
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0App\Scripts\Start-SfsuUsmt.ps1"
if errorlevel 1 goto launchfailed
exit /b 0

:missingapp
echo SFSU USMT could not find App\Scripts\Start-SfsuUsmt.ps1 beside this launcher.
echo Keep the launcher and the complete App folder together.
pause
exit /b 1

:launchfailed
echo SFSU USMT could not start Windows PowerShell. Review the error above.
pause
exit /b 1

:commandline
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0App\Scripts\Start-SfsuUsmt.ps1" %*
set "sfsuExit=%errorlevel%"
if not "%sfsuExit%"=="0" (
    echo.
    echo SFSU USMT could not finish. Review the error above and the Logs folder.
    if "%~1"=="" pause
)
exit /b %sfsuExit%
