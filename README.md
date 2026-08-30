# RFID EPC Whitelist Monitor

## Что это за проект

Сервис для RFID-ридера Hopeland, который непрерывно считывает EPC-метки,
сравнивает их с локальным whitelist и подаёт звуковой сигнал только при
совпадении.

Проект решает проблему штатного баззера ридера: стандартный режим реагирует на
любую обнаруженную метку и не учитывает бизнес-логику. Сервис отключает этот
звук, самостоятельно проверяет EPC и управляет сигналом после проверки.

## Установка

Требования:

- 64-битная Windows 10 или Windows 11;
- сетевое подключение к RFID-ридеру;
- доступ в интернет при первой установке;
- полный комплект проекта, включая `vendor\RFIDReaderAPI.dll`.

Откройте PowerShell в папке проекта и выполните:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Установщик запросит права администратора, адрес ридера и параметры звука. Если
ридер недоступен, он предложит настроить выбранный Ethernet-адаптер.

Во время установки автоматически выполняются:

1. Проверка файлов проекта и контрольной суммы Hopeland SDK.
2. Установка приложения в `C:\ProgramData\RFIDWhitelistMonitor`.
3. Загрузка переносимого Python с `python.org` и проверка SHA-256.
4. Проверка формата whitelist.
5. Подключение к ридеру через Hopeland SDK и запрос серийного номера.
6. Создание задачи автозапуска `RFID Whitelist Monitor`.
7. Запуск сервиса в фоне.

Устанавливать Python или Hopeland Demo отдельно не требуется.

Проверить установочный комплект без изменения системы:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -ValidateOnly
```

Для локального запуска из исходников без установщика сначала создайте рабочие
файлы из безопасных шаблонов:

```powershell
Copy-Item .\.env.example .\.env
Copy-Item .\whitelist.example.txt .\whitelist.txt
```

После копирования укажите реальный адрес ридера и добавьте разрешённые EPC.
`.env`, `whitelist.txt`, журналы, Python cache и локальные настройки редактора
исключены из Git через `.gitignore`.

## Настройка

После установки конфигурация находится в:

```text
C:\ProgramData\RFIDWhitelistMonitor\.env
```

Формат:

```dotenv
READER_HOST=<IP-адрес ридера>
READER_PORT=9090
HEALTH_TIMEOUT_SECONDS=5
LOG_FILE=logs/whitelist_monitor.log
WHITELIST_FILE=whitelist.txt
COOLDOWN_MS=2000
SOUND_COUNT=3
SOUND_DURATION_MS=50
SOUND_INTERVAL_MS=150
```

- `SOUND_COUNT` — количество сигналов при совпадении.
- `SOUND_DURATION_MS` — задержка перед выключением каждого сигнала.
- `SOUND_INTERVAL_MS` — пауза между сигналами.
- `HEALTH_TIMEOUT_SECONDS` — максимальное ожидание ответа ридера.
- `WHITELIST_FILE` — путь к файлу разрешённых EPC относительно директории сервиса.
- `COOLDOWN_MS` — пауза перед повторной реакцией на тот же EPC.

Разрешённые EPC находятся в:

```text
C:\ProgramData\RFIDWhitelistMonitor\whitelist.txt
```

Один EPC записывается на одной строке. Пустые строки и строки, начинающиеся с
`#`, игнорируются. После изменения `.env` или whitelist перезапустите задачу.

## Как работает сервис

1. Перед запуском Inventory выполняется health-check: временное подключение к
   ридеру и запрос `GetSN` через Hopeland SDK.
2. После успешной проверки открывается одно постоянное TCP-соединение.
3. Штатный звук чтения отключается командой ридера.
4. Inventory передаёт найденные EPC в callback SDK.
5. EPC нормализуется и сравнивается с `whitelist.txt`.
6. EPC вне списка получает результат `ОТКАЗ`; звук не подаётся.
7. Совпадение помещает запрос звука в отдельную очередь, не блокируя поток SDK.
8. Рабочий поток подаёт заданное количество сигналов и снова проверяет, что
   штатный звук чтения отключён.
9. Cooldown защищает от постоянного повторения сигнала для одной метки.
10. При остановке Inventory прекращается, баззер выключается, соединение
    закрывается.

Задача запускается при старте Windows от системной учётной записи. Если сеть
или ридер ещё не готовы, Планировщик повторяет запуск через минуту.

## Журнал и управление

Журнал работы:

```text
C:\ProgramData\RFIDWhitelistMonitor\logs\whitelist_monitor.log
```

Журнал сохраняется в UTF-8 и автоматически ротируется. Основные события:
health-check, запуск Inventory, `ОТКАЗ`, `СОВПАДЕНИЕ`, результат звука и
остановка.

Просматривать новые события в реальном времени можно из PowerShell:

```powershell
Get-Content `
  "C:\ProgramData\RFIDWhitelistMonitor\logs\whitelist_monitor.log" `
  -Encoding UTF8 `
  -Tail 50 `
  -Wait
```

`Ctrl+C` останавливает только просмотр журнала. Фоновый монитор продолжает
работать.

Управление фоновой задачей выполняется из PowerShell администратора:

```powershell
Stop-ScheduledTask -TaskName "RFID Whitelist Monitor"
Start-ScheduledTask -TaskName "RFID Whitelist Monitor"
Get-ScheduledTask -TaskName "RFID Whitelist Monitor"
```
