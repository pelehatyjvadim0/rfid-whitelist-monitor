<#
.SYNOPSIS
  Одноканальный эксперимент: EPC whitelist и buzzer в одном TCP-соединении HZ120.

.DESCRIPTION
  Скрипт отключает штатный звук чтения, открывает одно соединение с ридером и
  запускает Inventory. SDK вызывает OutPutTags для каждой метки. В callback
  EPC сравнивается с whitelist; при совпадении запрос звука передаётся
  отдельному потоку. Команды управления нельзя выполнять прямо в callback:
  callback занят обработкой ответа SDK, поэтому синхронная команда там
  блокирует сама себя и заканчивается ошибкой -2|Timeout!.

  Важно: это тест прошивки HZ120. Если ридер пищит на DENY даже здесь, значит
  его read-prompt аппаратно срабатывает внутри Inventory и недоступен для
  программного разделения по EPC.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReaderHost,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [string]$WhitelistPath,
    [ValidateRange(1, 100)]
    [int]$SoundCount = 1,
    [ValidateRange(10, 1000)]
    [int]$SoundDurationMs = 50,
    [ValidateRange(0, 60000)]
    [int]$SoundIntervalMs = 150,
    [ValidateRange(0, 60000)]
    [int]$CooldownMs = 2000
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$sdkPath = Join-Path $PSScriptRoot 'vendor\RFIDReaderAPI.dll'
if (-not (Test-Path -LiteralPath $sdkPath)) { throw "Не найдена библиотека Hopeland SDK: $sdkPath" }
if (-not (Test-Path -LiteralPath $WhitelistPath)) { throw "Не найден whitelist: $WhitelistPath" }

$whitelist = @(
    Get-Content -LiteralPath $WhitelistPath | ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }
)
if (-not $whitelist) { throw 'Whitelist пуст.' }
if ($whitelist | Where-Object { $_ -notmatch '^[0-9A-F]+$' -or $_.Length % 2 -ne 0 }) {
    throw 'Whitelist содержит некорректный EPC.'
}

Add-Type -Path $sdkPath

# Вся логика callback живёт в этом же процессе и использует тот же connectionId.
# lock не позволяет двум одновременным событиям EPC наложить звуковые импульсы.
$callbackCode = @'
using System;
using System.Collections.Generic;
using System.Threading;
using RFIDReaderAPI;
using RFIDReaderAPI.Interface;
using RFIDReaderAPI.Models;

public class WhitelistBuzzerCallback : IAsynchronousMessage, IAsynBarCodeMessage
{
    private readonly HashSet<string> whitelist;
    private readonly Dictionary<string, DateTime> lastBeep = new Dictionary<string, DateTime>();
    private readonly Dictionary<string, DateTime> lastDenyLog = new Dictionary<string, DateTime>();
    private readonly object gate = new object();
    private readonly AutoResetEvent beepSignal = new AutoResetEvent(false);
    private readonly string connectionId;
    private readonly int soundCount;
    private readonly int durationMs;
    private readonly int intervalMs;
    private readonly int cooldownMs;
    private readonly ReaderConfig config = new ReaderConfig();
    private readonly Thread buzzerThread;
    private volatile bool stopping;
    private int beepPending;

    public WhitelistBuzzerCallback(
        string[] allowed,
        string connectionId,
        int soundCount,
        int durationMs,
        int intervalMs,
        int cooldownMs)
    {
        this.whitelist = new HashSet<string>(allowed, StringComparer.OrdinalIgnoreCase);
        this.connectionId = connectionId;
        this.soundCount = soundCount;
        this.durationMs = durationMs;
        this.intervalMs = intervalMs;
        this.cooldownMs = cooldownMs;
        this.buzzerThread = new Thread(BuzzerLoop);
        this.buzzerThread.IsBackground = true;
        this.buzzerThread.Name = "RFID whitelist buzzer";
        this.buzzerThread.Start();
    }

    public void OutPutTags(Tag_Model tag)
    {
        if (tag == null || tag.Result != 0 || String.IsNullOrWhiteSpace(tag.EPC)) return;
        string epc = tag.EPC.Trim().ToUpperInvariant();
        lock (gate)
        {
            DateTime now = DateTime.UtcNow;
            if (!whitelist.Contains(epc))
            {
                // Одинаковый чужой EPC читается десятки раз в секунду. Для
                // фонового журнала достаточно одной записи за cooldown.
                DateTime previousDeny;
                if (!lastDenyLog.TryGetValue(epc, out previousDeny) ||
                    (now - previousDeny).TotalMilliseconds >= cooldownMs)
                {
                    lastDenyLog[epc] = now;
                    Console.Out.WriteLine("ОТКАЗ " + epc);
                    Console.Out.Flush();
                }
                return;
            }
            DateTime previous;
            if (lastBeep.TryGetValue(epc, out previous) && (now - previous).TotalMilliseconds < cooldownMs) return;
            lastBeep[epc] = now;

            // Callback только ставит запрос в очередь и сразу освобождает
            // поток приёма SDK. Одновременно может ожидать один импульс.
            Interlocked.Exchange(ref beepPending, 1);
            beepSignal.Set();
            Console.Out.WriteLine("СОВПАДЕНИЕ " + epc + " -> ЗВУК В ОЧЕРЕДИ");
            Console.Out.Flush();
        }
    }

    private void BuzzerLoop()
    {
        while (!stopping)
        {
            beepSignal.WaitOne();
            if (stopping) break;
            if (Interlocked.Exchange(ref beepPending, 0) == 0) continue;

            int completed = 0;
            string error = null;
            for (int index = 0; index < soundCount; index++)
            {
                // true,false = явно подать один звуковой сигнал. Это не
                // включает автоматический звук чтения, который постоянно
                // выключен через SetBuzzerSwitch(..., "1").
                string start = config.SetBuzzerControl(connectionId, true, false);
                if (start != "0|OK")
                {
                    error = "сигнал=" + (index + 1) + ", включение=" + start;
                    break;
                }

                Thread.Sleep(durationMs);
                string stop = config.SetBuzzerControl(connectionId, false, false);
                if (stop != "0|OK")
                {
                    error = "сигнал=" + (index + 1) + ", выключение=" + stop;
                    break;
                }

                completed++;
                if (index + 1 < soundCount && intervalMs > 0)
                    Thread.Sleep(intervalMs);
            }

            string keepReadSoundOff = config.SetBuzzerSwitch(connectionId, "1");
            if (error == null && keepReadSoundOff == "0|OK")
                Console.Out.WriteLine("ЗВУК ПОДАН: сигналов=" + completed);
            else
                Console.Out.WriteLine(
                    "ОШИБКА ЗВУКА: подано=" + completed +
                    ", ошибка=" + (error ?? "нет") +
                    ", штатныйЗвукОтключён=" + keepReadSoundOff);
            Console.Out.Flush();
        }
    }

    public void Shutdown()
    {
        stopping = true;
        beepSignal.Set();
        buzzerThread.Join(3000);
        beepSignal.Dispose();
    }

    public void WriteDebugMsg(string message) { }
    public void WriteLog(string message) { }
    public void PortConnecting(string message) { }
    public void PortClosing(string message) { }
    public void OutPutTagsOver() { }
    public void GPIControlMsg(GPI_Model gpi) { }
    public void CameraMsg(Camera_Model camera) { }
    public void EventUpload(CallBackEnum eventType, object value) { }
    public void OutPutBarCode(string barcode) { }
}
'@
Add-Type -TypeDefinition $callbackCode -ReferencedAssemblies @($sdkPath, 'System.dll')

$connectionId = "$ReaderHost`:$Port"
$config = [RFIDReaderAPI.ReaderConfig]::new()
$callback = [WhitelistBuzzerCallback]::new(
    [string[]]$whitelist,
    $connectionId,
    $SoundCount,
    $SoundDurationMs,
    $SoundIntervalMs,
    $CooldownMs
)
if (-not [RFIDReaderAPI.RFIDReader]::CreateTcpConn($connectionId, $callback, $callback)) {
    throw "Не удалось подключиться к ридеру $connectionId"
}

try {
    # По документации Hopeland: '0' ВКЛЮЧАЕТ звук при чтении тега, а '1'
    # ОТКЛЮЧАЕТ его. Ранее здесь стоял '0', поэтому звучал каждый DENY.
    $readSoundOff = $config.SetBuzzerSwitch($connectionId, '1')
    $buzzerOff = $config.SetBuzzerControl($connectionId, $false, $false)
    if ($readSoundOff -ne '0|OK' -or $buzzerOff -ne '0|OK') {
        throw "Не удалось отключить баззер перед Inventory: switch=$readSoundOff, control=$buzzerOff"
    }

    $rfid = [RFIDReaderAPI.RFID_Option]::new()
    $startResult = $rfid.GetEPC($connectionId, '1|1')
    if ($startResult -ne '0|OK') { throw "Не удалось запустить EPC Inventory: $startResult" }
    Write-Output "ГОТОВ: одно TCP-соединение; баззер отключён до совпадения; звук=$SoundCount x ${SoundDurationMs}мс, интервал=${SoundIntervalMs}мс."
    while ($true) { Start-Sleep -Seconds 1 }
}
finally {
    if ($rfid) { [void]$rfid.StopReader($connectionId) }
    if ($callback) { $callback.Shutdown() }
    [void]$config.SetBuzzerSwitch($connectionId, '1')
    [void]$config.SetBuzzerControl($connectionId, $false, $false)
    [RFIDReaderAPI.RFIDReader]::CloseConn($connectionId)
}
