<#
.SYNOPSIS
  Проверяет, что RFID-ридер Hopeland доступен и отвечает через официальный SDK.

.DESCRIPTION
  Скрипт открывает временное TCP-соединение, запрашивает серийный номер и
  диагностическое значение температуры, затем обязательно закрывает соединение.
  Успешный CreateTcpConn без ответа GetSN не считается исправным состоянием.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReaderHost,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$sdkPath = Join-Path $PSScriptRoot 'vendor\RFIDReaderAPI.dll'
if (-not (Test-Path -LiteralPath $sdkPath)) {
    throw "Не найдена библиотека Hopeland SDK: $sdkPath"
}

Add-Type -Path $sdkPath
$connectionId = "$ReaderHost`:$Port"
$connected = $false

try {
    $connected = [RFIDReaderAPI.RFIDReader]::CreateTcpConn($connectionId, $null, $null)
    if (-not $connected) {
        throw "Ридер $connectionId не принял соединение Hopeland SDK"
    }

    $config = [RFIDReaderAPI.ReaderConfig]::new()
    $serialNumber = $config.GetSN($connectionId)
    if ([string]::IsNullOrWhiteSpace($serialNumber) -or $serialNumber -match '^-\d+\|') {
        throw "Ридер не ответил на запрос серийного номера: $serialNumber"
    }

    $temperature = $config.GetReaderTemperature($connectionId)
    [pscustomobject]@{
        ok = $true
        address = $connectionId
        serial_number = $serialNumber
        temperature_raw = $temperature
    } | ConvertTo-Json -Compress
}
finally {
    if ($connected) {
        [RFIDReaderAPI.RFIDReader]::CloseConn($connectionId)
    }
}
