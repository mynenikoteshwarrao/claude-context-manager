@echo off
REM install.bat — convenience entry point for Windows users.
REM Locates Git Bash and execs install.sh.

set BASH_EXE=%PROGRAMFILES%\Git\bin\bash.exe
if not exist "%BASH_EXE%" (
  echo Could not find Git Bash at %BASH_EXE%
  echo Please install Git for Windows from https://git-scm.com/download/win
  exit /b 1
)

"%BASH_EXE%" -lc "cd '%~dp0' && ./install.sh"
