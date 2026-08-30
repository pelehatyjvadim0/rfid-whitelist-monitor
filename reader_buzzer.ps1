<#
.SYNOPSIS
  Управляет встроенным зуммером RFID-ридера Hopeland HZ120 по TCP.

.DESCRIPTION
  Скрипт загружает RFIDReaderAPI.dll из установленного комплекта Hopeland SDK,
  подключается к ридеру и вызывает SetBuzzerControl. Команда `true, false`
  включает звук; команда `false, false` его выключает. Каждый импульс всегда
  заканчивается выключением звука, а блок finally закрывает TCP-соединение
  даже при ошибке или прерывании.

.PARAMETER ReaderHost
  IP-адрес ридера, который Python передаёт из READER_HOST в `.env`.

.PARAMETER Port
  TCP-порт протокола Hopeland SDK. По умолчанию 9090.

.PARAMETER Count
  Количество импульсов в режиме Beep.

.PARAMETER IntervalMs
  Пауза между импульсами в миллисекундах.

.PARAMETER DurationMs
  Длительность одного включения зуммера в миллисекундах.

.PARAMETER Mode
  Disable — выключает постоянный штатный звук и завершает работу.
  Beep — подаёт заданное число коротких импульсов.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReaderHost,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [ValidateRange(1, 100)]
    [int]$Count = 1,

    [ValidateRange(0, 60000)]
    [int]$IntervalMs = 500,

    [ValidateRange(1, 5000)]
    [int]$DurationMs = 150,

    [ValidateSet('Disable', 'Beep')]
    [string]$Mode = 'Beep'
)

# Любая ошибка должна прерывать выполнение: нельзя продолжать и отправлять
# следующие команды, если DLL, сеть или сам ридер недоступны.
$ErrorActionPreference = 'Stop'
$sdkPath = Join-Path $PSScriptRoot 'vendor\RFIDReaderAPI.dll'
if (-not (Test-Path -LiteralPath $sdkPath)) {
    throw "Не найдена библиотека Hopeland SDK: $sdkPath"
}

# Загружаем DLL только после проверки пути, иначе ошибка будет неочевидной.
Add-Type -Path $sdkPath
$connectionId = "$ReaderHost`:$Port"

if (-not [RFIDReaderAPI.RFIDReader]::CreateTcpConn($connectionId, $null, $null)) {
    throw "Не удалось подключиться к ридеру $connectionId"
}

try {
    $config = [RFIDReaderAPI.ReaderConfig]::new()
    if ($Mode -eq 'Disable') {
        # false, false — отключает встроенный постоянный buzzer. Это важно:
        # далее звук должен подаваться только явными командами скрипта.
        # В протоколе Hopeland '1' означает: не пищать при чтении тега.
        $switchResult = $config.SetBuzzerSwitch($connectionId, '1')
        $controlResult = $config.SetBuzzerControl($connectionId, $false, $false)
        [pscustomobject]@{ mode = $Mode; switch = $switchResult; control = $controlResult } | ConvertTo-Json -Compress
        exit 0
    }

    # До импульса выключаем глобальный режим звука при чтении тегов.
    # Это не заменяет краткий импульс ниже, но уменьшает риск звука на чужой EPC.
    [void]$config.SetBuzzerSwitch($connectionId, '1')
    $results = for ($index = 1; $index -le $Count; $index++) {
        # Импульс формируется парой команд: включить → подождать → выключить.
        # Второй флаг false не разрешает ридеру перейти в постоянный режим.
        $start = $config.SetBuzzerControl($connectionId, $true, $false)
        Start-Sleep -Milliseconds $DurationMs
        $stop = $config.SetBuzzerControl($connectionId, $false, $false)
        if ($index -lt $Count -and $IntervalMs -gt 0) {
            Start-Sleep -Milliseconds $IntervalMs
        }
        [pscustomobject]@{ signal = $index; start = $start; stop = $stop }
    }
    $results | ConvertTo-Json -Compress
}
finally {
    # Возвращаем встроенный зуммер в выключенное состояние и закрываем сокет.
    if ($config) {
        [void]$config.SetBuzzerSwitch($connectionId, '1')
        [void]$config.SetBuzzerControl($connectionId, $false, $false)
    }
    # Освобождаем сокет независимо от исхода команды, чтобы следующий запуск
    # или Hopeland Demo могли сразу подключиться к TCP-порту 9090.
    [RFIDReaderAPI.RFIDReader]::CloseConn($connectionId)
}
