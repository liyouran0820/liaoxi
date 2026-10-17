$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Test-Path '.venv/Scripts/python.exe')) {
    & py -3.12 -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 x64 is required.' }
}
& ./.venv/Scripts/python.exe -m pip install -r requirements.txt 'pyinstaller>=6.20,<7'
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
& ./.venv/Scripts/python.exe -m unittest discover -s tests -v
if ($LASTEXITCODE -ne 0) { throw 'Archive tests failed.' }
& ./.venv/Scripts/python.exe -m PyInstaller --noconfirm --clean --windowed --onedir --name ChatArchive --collect-all winrt --collect-all comtypes --hidden-import win32timezone app.py
if ($LASTEXITCODE -ne 0) { throw 'Executable packaging failed.' }
Compress-Archive -Path './dist/ChatArchive/*' -DestinationPath './dist/ChatArchive-Windows.zip' -Force
Write-Output 'Ready: dist/ChatArchive/ChatArchive.exe and dist/ChatArchive-Windows.zip'
