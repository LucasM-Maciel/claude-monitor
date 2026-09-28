@echo off
rem Duplo clique aqui pra instalar o Claude Monitor no Windows.
chcp 65001 >nul
if not exist "%~dp0arquivos\instalar-windows.ps1" (
  echo.
  echo  Extraia o .zip antes: botao direito no ClaudeMonitor.zip ^> "Extrair tudo".
  echo  Depois abra a pasta extraida e de duplo clique no instalar-windows.cmd de la.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0arquivos\instalar-windows.ps1"
echo.
pause
