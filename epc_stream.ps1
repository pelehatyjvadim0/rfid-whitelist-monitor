<#
.SYNOPSIS
  Непрерывно выводит EPC, считанные ридером Hopeland HZ120.

.DESCRIPTION
  Скрипт использует RFIDReaderAPI.dll и режим Inventory антенны 1. Каждая
  полученная SDK метка выводится в stdout отдельной строкой только в виде EPC.
  Это намеренно простой поток данных для Python-модуля whitelist_monitor.py.
  При Ctrl+C или остановке процесса блок finally прекращает inventory и
  освобождает TCP-соединение с ридером.
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
$sdkPath = Join-Path $PSScriptRoot 'vendor\RFIDReaderAPI.dll'
if (-not (Test-Path -LiteralPath $sdkPath)) {
    throw "Hopeland SDK not found: $sdkPath"
}

Add-Type -Path $sdkPath

# SDK отправляет метки асинхронно через интерфейс IAsynchronousMessage.
# Callback пишет только EPC в stdout: служебные SDK-сообщения намеренно не
# выводятся, чтобы Python мог безопасно читать поток построчно.
$callbackCode = @'
using System;
using RFIDReaderAPI;
using RFIDReaderAPI.Interface;
using RFIDReaderAPI.Models;

public class EpcStreamCallback : IAsynchronousMessage, IAsynBarCodeMessage
{
    public void WriteDebugMsg(string message) { }
    public void WriteLog(string message) { }
    public void PortConnecting(string message) { }
    public void PortClosing(string message) { }
    public void OutPutTags(Tag_Model tag)
    {
        if (tag != null && tag.Result == 0 && !String.IsNullOrWhiteSpace(tag.EPC))
        {
            Console.Out.WriteLine(tag.EPC.Trim().ToUpperInvariant());
            Console.Out.Flush();
        }
    }
    public void OutPutTagsOver() { }
    public void GPIControlMsg(GPI_Model gpi) { }
    public void CameraMsg(Camera_Model camera) { }
    public void EventUpload(CallBackEnum eventType, object value) { }
    public void OutPutBarCode(string barcode) { }
}
'@

Add-Type -TypeDefinition $callbackCode -ReferencedAssemblies @($sdkPath, 'System.dll')
$connectionId = "$ReaderHost`:$Port"
$callback = [EpcStreamCallback]::new()

if (-not [RFIDReaderAPI.RFIDReader]::CreateTcpConn($connectionId, $callback, $callback)) {
    throw "Unable to connect to reader $connectionId"
}

try {
    # Для HZ120 эта команда SDK принимает строку "антенна|режим".
    # Значение 1|1: встроенная антенна 1 и режим непрерывного Inventory.
    $rfid = [RFIDReaderAPI.RFID_Option]::new()
    $startResult = $rfid.GetEPC($connectionId, '1|1')
    if ($startResult -ne '0|OK') {
        throw "Unable to start EPC inventory. SDK response: $startResult"
    }

    # Некоторые прошивки HZ120 повторно включают звук при входе в Inventory.
    # Поэтому выключаем оба режима ещё раз уже после успешного старта чтения.
    # EPC-поток при этом должен остаться активным.
    $config = [RFIDReaderAPI.ReaderConfig]::new()
    [void]$config.SetBuzzerSwitch($connectionId, '0')
    [void]$config.SetBuzzerControl($connectionId, $false, $false)

    while ($true) {
        Start-Sleep -Seconds 1
    }
}
finally {
    [void]$rfid.StopReader($connectionId)
    [RFIDReaderAPI.RFIDReader]::CloseConn($connectionId)
}
