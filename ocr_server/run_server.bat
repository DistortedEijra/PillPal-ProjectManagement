@echo off
rem PillPal OCR server - run this on the laptop, then use the address it shows in the app.
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
  echo Creating Python environment...
  py -3.12 -m venv .venv 2>nul || py -3.11 -m venv .venv 2>nul || python -m venv .venv
)
if not exist ".venv\Scripts\python.exe" (
  echo Could not create the environment. Install Python 3.11 or 3.12 from python.org first.
  pause
  exit /b 1
)

echo Installing libraries (the first time takes a few minutes)...
".venv\Scripts\python.exe" -m pip install --upgrade pip >nul
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
  echo Installing the libraries failed. See the message above.
  pause
  exit /b 1
)

echo.
echo ================================================================
echo  In the PillPal app, set the server address to http://YOUR-IP:7860
echo  Your laptop's IP address:
ipconfig | findstr /c:"IPv4"
echo  The first start downloads the model (about 800 MB).
echo  Wait for "Application startup complete" before scanning.
echo  If Windows Firewall asks, allow access on Private networks.
echo ================================================================
echo.

".venv\Scripts\python.exe" -m uvicorn app:app --host 0.0.0.0 --port 7860
pause
