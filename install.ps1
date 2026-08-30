<#
.SYNOPSIS
  Разворачивает RFID whitelist monitor на чистой Windows и включает автозапуск.

.DESCRIPTION
  Установщик запускается один раз от администратора. Он проверяет комплект,
  спрашивает параметры ридера и звука, при необходимости помогает настроить
  Ethernet, скачивает официальный переносимый Python с проверкой SHA-256,
  выполняет SDK health-check и создаёт задачу Планировщика Windows от SYSTEM.

  Установщик идемпотентен: повторный запуск обновляет код и задачу, сохраняя
  существующий whitelist. Никаких глобальных PATH или Python-пакетов он не
  устанавливает.

.PARAMETER InstallRoot
  Постоянная директория приложения. По умолчанию:
  C:\ProgramData\RFIDWhitelistMonitor.

.PARAMETER SkipNetworkSetup
  Не предлагать изменение сетевого адаптера, даже если ридер недоступен.

.PARAMETER DoNotStart
  Создать задачу автозапуска, но не запускать её сразу после установки.

.PARAMETER ValidateOnly
  Только проверить исходный комплект без установки и изменения компьютера.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:ProgramData 'RFIDWhitelistMonitor'),
    [switch]$SkipNetworkSetup,
    [switch]$DoNotStart,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$taskName = 'RFID Whitelist Monitor'
$pythonVersion = '3.12.10'
$pythonUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
$pythonSha256 = '4ACBED6DD1C744B0376E3B1CF57CE906F9DC9E95E68824584C8099A63025A3C3'
$sdkSha256 = '10C5F711DCF565CA5254CC3E1AE65E2B585C1B475A27BE46AA32C929A788F5B3'
$sourceRoot = $PSScriptRoot

function Write-Step {
    <# Выводит заметный заголовок текущего этапа установки. #>
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Test-Administrator {
    <# Проверяет, запущен ли текущий PowerShell с правами администратора. #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedInstaller {
    <# Повторно запускает этот же файл через UAC, сохраняя безопасные параметры. #>
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-InstallRoot', ('"{0}"' -f $InstallRoot)
    )
    if ($SkipNetworkSetup) { $arguments += '-SkipNetworkSetup' }
    if ($DoNotStart) { $arguments += '-DoNotStart' }

    Write-Host 'Для установки нужны права администратора. Открываю запрос UAC...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($arguments -join ' ') -WindowStyle Normal
}

function Read-DotEnv {
    <# Читает существующий .env и возвращает таблицу значений для defaults. #>
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
        # ``String.Split(..., 2)`` неодинаково выбирает перегрузку метода в
        # Windows PowerShell 5.1 и PowerShell 7. Ищем первый разделитель
        # вручную, чтобы значение могло содержать знак ``=``.
        $separatorIndex = $line.IndexOf('=')
        $key = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim().Trim('"').Trim("'")
        $values[$key] = $value
    }
    return $values
}

function Read-Value {
    <# Запрашивает строковое значение и принимает default при пустом вводе. #>
    param(
        [string]$Prompt,
        [string]$Default
    )
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-IPv4Value {
    <# Запрашивает обязательный IPv4 и повторяет вопрос при неверном вводе. #>
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    while ($true) {
        $value = if ($Default) {
            Read-Value -Prompt $Prompt -Default $Default
        } else {
            (Read-Host $Prompt).Trim()
        }
        try {
            Assert-IPv4 -Value $value -SettingName $Prompt
            return $value
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Read-Integer {
    <# Запрашивает целое число в заданных границах. #>
    param(
        [string]$Prompt,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )
    while ($true) {
        $raw = Read-Value -Prompt $Prompt -Default $Default
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
            return $value
        }
        Write-Warning "Введите целое число от $Minimum до $Maximum."
    }
}

function Confirm-Choice {
    <# Запрашивает подтверждение да/нет с безопасным значением по умолчанию. #>
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
    if (-not $answer) { return $Default }
    return $answer -in @('y', 'yes', 'д', 'да')
}

function Assert-IPv4 {
    <# Проверяет, что строка является обычным IPv4-адресом. #>
    param(
        [string]$Value,
        [string]$SettingName
    )
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$SettingName должен быть корректным IPv4-адресом: $Value"
    }
}

function Test-TcpEndpoint {
    <# Быстро проверяет TCP-порт без длительного ожидания Test-NetConnection. #>
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($pending)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Assert-SafeInstallRoot {
    <# Запрещает использование корня диска или самой ProgramData как цели. #>
    param([string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $driveRoot = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    $programDataRoot = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if ($resolved -eq $driveRoot -or $resolved -eq $programDataRoot) {
        throw "Небезопасная директория установки: $resolved"
    }
    return $resolved
}

function Test-SourcePackage {
    <# Проверяет наличие всех файлов и целостность вложенной Hopeland DLL. #>
    param([string]$Root)
    $requiredFiles = @(
        '.env.example',
        'app_config.py',
        'reader_health.py',
        'reader_health.ps1',
        'whitelist_monitor.py',
        'one_connection_monitor.ps1',
        'reader_buzzer.ps1',
        'beep_reader.py',
        'whitelist.example.txt',
        'README.md',
        'vendor\RFIDReaderAPI.dll'
    )
    foreach ($relativePath in $requiredFiles) {
        $fullPath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "В установочном комплекте отсутствует: $relativePath"
        }
    }
    $dllPath = Join-Path $Root 'vendor\RFIDReaderAPI.dll'
    $actualHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
    if ($actualHash -ne $script:sdkSha256) {
        throw "Контрольная сумма RFIDReaderAPI.dll не совпала. Получено: $actualHash"
    }
}

function Copy-ApplicationFiles {
    <# Обновляет runtime-файлы, но не перезаписывает рабочий whitelist. #>
    param(
        [string]$From,
        [string]$To
    )
    $files = @(
        'app_config.py',
        'reader_health.py',
        'reader_health.ps1',
        'whitelist_monitor.py',
        'one_connection_monitor.ps1',
        'reader_buzzer.ps1',
        'beep_reader.py',
        'README.md'
    )
    foreach ($name in $files) {
        Copy-Item -LiteralPath (Join-Path $From $name) -Destination (Join-Path $To $name) -Force
    }

    $vendorTarget = Join-Path $To 'vendor'
    New-Item -ItemType Directory -Path $vendorTarget -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $From 'vendor\RFIDReaderAPI.dll') -Destination (Join-Path $vendorTarget 'RFIDReaderAPI.dll') -Force
    Unblock-File -LiteralPath (Join-Path $vendorTarget 'RFIDReaderAPI.dll')

    $installedWhitelist = Join-Path $To 'whitelist.txt'
    if (-not (Test-Path -LiteralPath $installedWhitelist)) {
        $localWhitelist = Join-Path $From 'whitelist.txt'
        $whitelistSource = if (Test-Path -LiteralPath $localWhitelist) {
            $localWhitelist
        } else {
            Join-Path $From 'whitelist.example.txt'
        }
        Copy-Item -LiteralPath $whitelistSource -Destination $installedWhitelist
    }
}

function Install-EmbeddedPython {
    <# Скачивает локальный Python, проверяет SHA-256 и настраивает import path. #>
    param([string]$Root)
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Поддерживается только 64-битная Windows.'
    }

    $runtimeDir = Join-Path $Root 'runtime'
    $packagesDir = Join-Path $Root 'packages'
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
    $archivePath = Join-Path $packagesDir "python-$script:pythonVersion-embed-amd64.zip"

    $downloadRequired = -not (Test-Path -LiteralPath $archivePath)
    if (-not $downloadRequired) {
        $cachedHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($cachedHash -ne $script:pythonSha256) {
            throw "Кэш Python повреждён: $archivePath. Удалите этот файл и повторите установку."
        }
    }

    if ($downloadRequired) {
        Write-Host "Скачивание Python $script:pythonVersion с python.org..."
        $temporaryArchive = "$archivePath.download"
        Invoke-WebRequest -Uri $script:pythonUrl -OutFile $temporaryArchive -UseBasicParsing
        $downloadHash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash
        if ($downloadHash -ne $script:pythonSha256) {
            throw "SHA-256 загруженного Python не совпал. Получено: $downloadHash"
        }
        Move-Item -LiteralPath $temporaryArchive -Destination $archivePath
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $runtimeDir -Force
    $pathFile = Join-Path $runtimeDir 'python312._pth'
    @('python312.zip', '.', '..', '#import site') | Set-Content -LiteralPath $pathFile -Encoding ASCII

    $pythonExe = Join-Path $runtimeDir 'python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "После распаковки не найден Python: $pythonExe"
    }
    $versionText = & $pythonExe --version 2>&1
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^Python 3\.12\.') {
        throw "Переносимый Python не прошёл проверку: $versionText"
    }
    Write-Host "Готово: $versionText"
    return $pythonExe
}

function Write-ApplicationEnv {
    <# Создаёт рабочий .env из подтверждённых пользователем значений. #>
    param(
        [string]$Root,
        [string]$ReaderHost,
        [int]$ReaderPort,
        [int]$HealthTimeout,
        [int]$CooldownMs,
        [int]$SoundCount,
        [int]$SoundDuration,
        [int]$SoundInterval
    )
    $content = @"
# Сетевой адрес RFID-ридера.
READER_HOST=$ReaderHost
READER_PORT=$ReaderPort

# Максимальное время ожидания SDK-проверки.
HEALTH_TIMEOUT_SECONDS=$HealthTimeout

# Журнал относительно директории приложения.
LOG_FILE=logs/whitelist_monitor.log

# Whitelist и пауза повторной реакции на один EPC.
WHITELIST_FILE=whitelist.txt
COOLDOWN_MS=$CooldownMs

# Звуковой рисунок для одного совпадения whitelist.
SOUND_COUNT=$SoundCount
SOUND_DURATION_MS=$SoundDuration
SOUND_INTERVAL_MS=$SoundInterval
"@
    $content | Set-Content -LiteralPath (Join-Path $Root '.env') -Encoding UTF8
}

function Assert-Whitelist {
    <# Проверяет whitelist и запрашивает EPC, если список пока пуст. #>
    param([string]$Path)
    $entries = @(
        Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
    )
    if (-not $entries) {
        Write-Warning 'Whitelist пока не содержит EPC.'
        while (-not $entries) {
            $rawEntries = Read-Host 'Введите один или несколько EPC через пробел или запятую'
            $entries = @(
                $rawEntries.ToUpperInvariant() -split '[,;\s]+' |
                Where-Object { $_ }
            )
            $invalidInput = @($entries | Where-Object { $_ -notmatch '^[0-9A-F]+$' -or $_.Length % 2 -ne 0 })
            if (-not $entries -or $invalidInput) {
                Write-Warning 'Каждый EPC должен содержать чётное количество шестнадцатеричных символов.'
                $entries = @()
            }
        }
        @(
            '# Один EPC на строку. Строки с # являются комментариями.'
            $entries
        ) | Set-Content -LiteralPath $Path -Encoding UTF8
    }
    $invalid = @($entries | Where-Object { $_ -notmatch '^[0-9A-F]+$' -or $_.Length % 2 -ne 0 })
    if ($invalid) {
        throw "Whitelist содержит некорректный EPC: $($invalid -join ', ')"
    }
    Write-Host "Whitelist проверен: EPC=$($entries.Count)"
}

function Get-DefaultLocalAddress {
    <# Предлагает свободный адрес .10 в той же /24 подсети, что и ридер. #>
    param([string]$ReaderAddress)
    $octets = $ReaderAddress.Split('.')
    $lastOctet = if ($octets[3] -eq '10') { '11' } else { '10' }
    return "$($octets[0]).$($octets[1]).$($octets[2]).$lastOctet"
}

function Configure-NetworkIfNeeded {
    <# При недоступном ридере предлагает явно выбранную статическую IPv4. #>
    param(
        [string]$ReaderHost,
        [int]$ReaderPort,
        [string]$Root,
        [switch]$Skip
    )
    if (Test-TcpEndpoint -HostName $ReaderHost -Port $ReaderPort) {
        Write-Host "TCP $ReaderHost`:$ReaderPort уже доступен; сеть менять не нужно."
        return
    }
    Write-Warning "TCP $ReaderHost`:$ReaderPort сейчас недоступен."
    if ($Skip) {
        Write-Warning 'Автоматическая настройка сети пропущена параметром -SkipNetworkSetup.'
        return
    }
    if (-not (Confirm-Choice -Prompt 'Настроить отдельный Ethernet-адаптер для ридера?' -Default $true)) {
        return
    }

    $adapters = @(Get-NetAdapter -Physical | Where-Object Status -ne 'Disabled' | Sort-Object ifIndex)
    if (-not $adapters) { throw 'Не найден доступный физический сетевой адаптер.' }
    Write-Host 'Доступные адаптеры:'
    for ($index = 0; $index -lt $adapters.Count; $index++) {
        $adapter = $adapters[$index]
        Write-Host ("  {0}. {1} — {2} ({3})" -f ($index + 1), $adapter.Name, $adapter.InterfaceDescription, $adapter.Status)
    }
    $selection = Read-Integer -Prompt 'Номер Ethernet-адаптера' -Default 1 -Minimum 1 -Maximum $adapters.Count
    $selected = $adapters[$selection - 1]
    $existingAddresses = @(Get-NetIPAddress -InterfaceIndex $selected.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    Write-Host "Текущие IPv4 на '$($selected.Name)': $($existingAddresses.IPAddress -join ', ')"

    $defaultLocalIp = Get-DefaultLocalAddress -ReaderAddress $ReaderHost
    $localIp = Read-Value -Prompt 'Статический IPv4 этого компьютера' -Default $defaultLocalIp
    Assert-IPv4 -Value $localIp -SettingName 'Локальный IP'
    if ($localIp -eq $ReaderHost) { throw 'Локальный IP не может совпадать с IP ридера.' }
    $prefixLength = Read-Integer -Prompt 'Длина префикса сети' -Default 24 -Minimum 1 -Maximum 30

    Write-Warning "Будет изменена IPv4-конфигурация адаптера '$($selected.Name)'."
    $confirmation = Read-Host 'Для подтверждения введите НАСТРОИТЬ'
    if ($confirmation -cne 'НАСТРОИТЬ') {
        Write-Warning 'Настройка сети отменена.'
        return
    }

    $backupPath = Join-Path $Root 'network_before_install.json'
    Get-NetIPConfiguration -InterfaceIndex $selected.ifIndex -Detailed |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8

    $alreadyConfigured = $existingAddresses | Where-Object IPAddress -eq $localIp
    if (-not $alreadyConfigured) {
        Set-NetIPInterface -InterfaceIndex $selected.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        New-NetIPAddress -InterfaceIndex $selected.ifIndex -IPAddress $localIp -PrefixLength $prefixLength | Out-Null
    }
    Write-Host "Настроено: $localIp/$prefixLength на '$($selected.Name)'. Резервная информация: $backupPath"
}

function Invoke-InstalledHealthCheck {
    <# Запускает полный CreateTcpConn + GetSN установленной копией приложения. #>
    param(
        [string]$PythonExe,
        [string]$Root
    )
    $healthScript = Join-Path $Root 'reader_health.py'
    & $PythonExe $healthScript
    return $LASTEXITCODE -eq 0
}

function Register-MonitorTask {
    <# Создаёт автозапуск от SYSTEM с повтором при ошибке health или Inventory. #>
    param(
        [string]$PythonExe,
        [string]$Root
    )
    $monitorScript = Join-Path $Root 'whitelist_monitor.py'
    $action = New-ScheduledTaskAction -Execute $PythonExe -Argument ('"{0}"' -f $monitorScript) -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    $existingTask = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Stop-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:taskName -Confirm:$false
    }
    Register-ScheduledTask `
        -TaskName $script:taskName `
        -Description 'RFID EPC whitelist monitor with Hopeland reader health-check' `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings | Out-Null
}

try {
    Write-Step 'Проверка установочного комплекта'
    Test-SourcePackage -Root $sourceRoot
    Write-Host "Hopeland SDK проверен: SHA-256=$sdkSha256"
    if ($ValidateOnly) {
        Write-Host 'Комплект корректен. ValidateOnly не изменял систему.' -ForegroundColor Green
        exit 0
    }

    if (-not (Test-Administrator)) {
        Start-ElevatedInstaller
        exit 0
    }

    $InstallRoot = Assert-SafeInstallRoot -Path $InstallRoot
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'logs') -Force | Out-Null

    $currentEnvPath = Join-Path $InstallRoot '.env'
    $defaults = if (Test-Path -LiteralPath $currentEnvPath) {
        Read-DotEnv -Path $currentEnvPath
    } else {
        Read-DotEnv -Path (Join-Path $sourceRoot '.env')
    }

    Write-Step 'Параметры ридера и звука'
    $readerHost = Read-IPv4Value -Prompt 'IP-адрес RFID-ридера' -Default $(if ($defaults.READER_HOST) { $defaults.READER_HOST } else { '' })
    $readerPort = Read-Integer -Prompt 'TCP-порт RFID-ридера' -Default $(if ($defaults.READER_PORT) { [int]$defaults.READER_PORT } else { 9090 }) -Minimum 1 -Maximum 65535
    $healthTimeout = Read-Integer -Prompt 'Timeout health-check, секунд' -Default $(if ($defaults.HEALTH_TIMEOUT_SECONDS) { [int]$defaults.HEALTH_TIMEOUT_SECONDS } else { 5 }) -Minimum 1 -Maximum 60
    $cooldownMs = Read-Integer -Prompt 'Пауза повторной реакции на один EPC, мс' -Default $(if ($defaults.COOLDOWN_MS) { [int]$defaults.COOLDOWN_MS } else { 2000 }) -Minimum 0 -Maximum 60000
    $soundCount = Read-Integer -Prompt 'Количество сигналов на совпадение' -Default $(if ($defaults.SOUND_COUNT) { [int]$defaults.SOUND_COUNT } else { 3 }) -Minimum 1 -Maximum 100
    $soundDuration = Read-Integer -Prompt 'Длительность сигнала, мс' -Default $(if ($defaults.SOUND_DURATION_MS) { [int]$defaults.SOUND_DURATION_MS } else { 50 }) -Minimum 10 -Maximum 1000
    $soundInterval = Read-Integer -Prompt 'Интервал между сигналами, мс' -Default $(if ($defaults.SOUND_INTERVAL_MS) { [int]$defaults.SOUND_INTERVAL_MS } else { 150 }) -Minimum 0 -Maximum 60000

    Write-Step 'Развёртывание файлов'
    Copy-ApplicationFiles -From $sourceRoot -To $InstallRoot
    Assert-Whitelist -Path (Join-Path $InstallRoot 'whitelist.txt')
    Write-ApplicationEnv `
        -Root $InstallRoot `
        -ReaderHost $readerHost `
        -ReaderPort $readerPort `
        -HealthTimeout $healthTimeout `
        -CooldownMs $cooldownMs `
        -SoundCount $soundCount `
        -SoundDuration $soundDuration `
        -SoundInterval $soundInterval
    $pythonExe = Install-EmbeddedPython -Root $InstallRoot

    Write-Step 'Проверка сети'
    Configure-NetworkIfNeeded `
        -ReaderHost $readerHost `
        -ReaderPort $readerPort `
        -Root $InstallRoot `
        -Skip:$SkipNetworkSetup

    Write-Step 'Полный health-check ридера'
    $healthOk = Invoke-InstalledHealthCheck -PythonExe $pythonExe -Root $InstallRoot
    if (-not $healthOk) {
        Write-Warning 'Ридер сейчас не прошёл health-check.'
        if (-not (Confirm-Choice -Prompt 'Всё равно создать автозапуск с повторной проверкой каждую минуту?' -Default $false)) {
            throw 'Установка остановлена: health-check ридера не пройден.'
        }
    }

    Write-Step 'Настройка автозапуска'
    Register-MonitorTask -PythonExe $pythonExe -Root $InstallRoot
    if (-not $DoNotStart) {
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 2
    }
    $task = Get-ScheduledTask -TaskName $taskName
    Write-Host "Задача '$taskName': $($task.State)"

    Write-Step 'Установка завершена'
    Write-Host "Приложение: $InstallRoot"
    Write-Host "Настройки: $(Join-Path $InstallRoot '.env')"
    Write-Host "Whitelist: $(Join-Path $InstallRoot 'whitelist.txt')"
    Write-Host "Журнал: $(Join-Path $InstallRoot 'logs\whitelist_monitor.log')"
    Write-Host "Health вручную: & '$pythonExe' '$(Join-Path $InstallRoot 'reader_health.py')'"
    Write-Host 'Для изменений .env и whitelist в ProgramData откройте редактор от администратора.'
    Write-Host 'Готово.' -ForegroundColor Green
}
catch {
    Write-Host "`nОШИБКА УСТАНОВКИ: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Строка: $($_.InvocationInfo.ScriptLineNumber)"
    exit 1
}
