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
& ./.venv/Scripts/python.exe -m PyInstaller --noconfirm --clean --windowed --onefile --name ChatArchive-Windows-x64 app.py
if ($LASTEXITCODE -ne 0) { throw 'Executable packaging failed.' }
$reportPath = Join-Path $PSScriptRoot 'dist/packaged-smoke.json'
if (Test-Path $reportPath) { Remove-Item $reportPath }
$smoke = Start-Process -FilePath './dist/ChatArchive-Windows-x64.exe' -ArgumentList @('--self-test', '--self-test-report', ('"' + $reportPath + '"')) -PassThru
if (-not $smoke.WaitForExit(120000)) { $smoke.Kill(); throw 'Packaged application smoke test timed out.' }
if ($smoke.ExitCode -ne 0 -or -not (Test-Path $reportPath)) { throw 'Packaged application smoke test failed.' }
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
if ($report.status -ne 'passed' -or $report.mode -ne 'manual' -or $report.ocr -ne $false -or $report.screen_capture -ne $false) { throw 'Packaged manual export self-test did not pass.' }
Compress-Archive -Path './dist/ChatArchive-Windows-x64.exe', './README.md' -DestinationPath './dist/ChatArchive-Windows-x64.zip' -Force
Write-Output 'Ready: dist/ChatArchive-Windows-x64.exe and dist/ChatArchive-Windows-x64.zip'
