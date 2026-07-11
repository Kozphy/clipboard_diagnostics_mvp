$test = "CLIPBOARD_TEST_" + [guid]::NewGuid().ToString("N")

try {
    Set-Clipboard -Value $test
    Start-Sleep -Milliseconds 500
    $result = Get-Clipboard -Raw

    if ($result.Trim() -eq $test) {
        Write-Host "PASS: Clipboard write/read is working." -ForegroundColor Green
        Write-Host "Test value: $result"
    }
    else {
        Write-Host "FAIL: Clipboard content did not match." -ForegroundColor Red
        Write-Host "Expected: $test"
        Write-Host "Received: $result"
    }
}
catch {
    Write-Host "ERROR: Clipboard test failed." -ForegroundColor Red
    Write-Host $_.Exception.Message
}
