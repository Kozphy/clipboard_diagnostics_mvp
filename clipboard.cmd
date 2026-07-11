$test = "CLIPBOARD_TEST_" + [guid]::NewGuid().ToString("N")

try {
    Set-Clipboard -Value $test
    Start-Sleep -Milliseconds 500
    $result = Get-Clipboard -Raw

    if($result.Trim() -eq $test) {
        Write-Host "Pass Clipboard write/read is working." -ForegroundColor Green
        Write-Host "Test Value: $result"
    }
    else {
        Write-Host "Fail Clipboard write/read is not working." -ForegroundColor Red
        Write-Host "Expected: $test"
        Write-Host "Received: $result"
    }
}
catch {
    Write-Host "Error: Clipboard test failed." -ForegroundColor Red
    Write-Host $_.Exception.Message
}

