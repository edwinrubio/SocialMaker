@echo off
REM ============================================================================
REM init.bat - Verificacion de entorno de SocialMaker (Hearness base/07) - Windows
REM
REM Uso:   init.bat
REM
REM Contrato:
REM   exit 0   -> todo verde, se puede empezar / cerrar sesion
REM   exit !=0 -> algo falla; el agente PARA y reporta que chequeo fallo
REM
REM Solo lectura / idempotente. En Windows solo se puede compilar Android.
REM ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"
set FALLOS=0

echo Verificando entorno...

REM --- Herramientas de runtime ---------------------------------------------
call :check_cmd flutter "Flutter"
call :check_cmd dart "Dart"
call :check_cmd git "Git"
call :check_cmd java "Java (Gradle)"
call :check_cmd adb "adb"

REM --- Dependencias ---------------------------------------------------------
call :check_path .dart_tool "dependencias de la app"
call :check_path packages\bg_camera\.dart_tool "dependencias del plugin bg_camera"

REM --- Compila / smoke test -------------------------------------------------
call flutter analyze --no-pub >nul 2>&1
if !errorlevel! EQU 0 ( echo   [OK] flutter analyze sin issues ) else ( echo   [X] flutter analyze con issues & set /a FALLOS+=1 )
call flutter test --no-pub >nul 2>&1
if !errorlevel! EQU 0 ( echo   [OK] flutter test pasa ) else ( echo   [X] flutter test falla & set /a FALLOS+=1 )

echo ----------------------------------------
if !FALLOS! EQU 0 (
  echo [OK] Entorno sano. Puedes empezar / cerrar sesion.
  exit /b 0
) else (
  echo [ERROR] !FALLOS! chequeo^(s^) fallaron. NO empieces hasta arreglarlos.
  exit /b 1
)

REM ============================================================================
REM helpers
REM ============================================================================
:check_cmd
where %~1 >nul 2>&1
if !errorlevel! EQU 0 ( echo   [OK] %~2 disponible ) else ( echo   [X] %~2 NO encontrado & set /a FALLOS+=1 )
goto :eof

:check_path
if exist %~1 ( echo   [OK] %~2 existe ) else ( echo   [X] %~2 falta & set /a FALLOS+=1 )
goto :eof
