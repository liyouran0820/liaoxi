$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Test-Path '.venv/Scripts/python.exe')) {
    & py -3.12 -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw 'Please install Python 3.12 x64 from python.org, including Tcl/Tk and the Python launcher.' }
}
& ./.venv/Scripts/python.exe -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed. Check your connection and run start.cmd again.' }
& ./.venv/Scripts/python.exe app.py
if ($LASTEXITCODE -ne 0) { throw 'The application exited with an error. Please keep this window for diagnostics.' }
