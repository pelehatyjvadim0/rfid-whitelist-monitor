"""Python-интерфейс для подачи звуковых импульсов на Hopeland HZ120.

Этот файл не работает с сетевым протоколом ридера самостоятельно. Он проверяет
параметры командной строки и запускает ``reader_buzzer.ps1``, где используется
официальная DLL Hopeland SDK. Такое разделение оставляет Python-код простым, а
низкоуровневую работу с устройством — в PowerShell.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Sequence

from app_config import ConfigError, env_int, load_env, require_env


PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_DURATION_MS = 150


def validate_arguments(count: int, interval_ms: int) -> None:
    """Проверяет параметры повторяющихся звуковых импульсов.

    ``count`` — число импульсов. ``interval_ms`` — пауза между окончанием
    одного импульса и началом следующего в миллисекундах. Проверка вынесена
    отдельно, чтобы её можно было использовать и из тестов, и при запуске CLI.
    """
    if count < 1:
        raise ValueError("Количество сигналов должно быть не меньше 1.")
    if interval_ms < 0:
        raise ValueError("Интервал не может быть отрицательным.")


def build_powershell_command(
    *,
    powershell_exe: str,
    script_path: str,
    host: str,
    port: int,
    count: int,
    interval_ms: int,
    duration_ms: int = DEFAULT_DURATION_MS,
    mode: str = "Beep",
) -> list[str]:
    """Собирает безопасный список аргументов для запуска PowerShell.

    Возвращается именно список, а не строка: ``subprocess`` передаёт каждый
    элемент как отдельный аргумент, поэтому IP-адрес, путь с пробелами и числа
    не требуют ручного экранирования. Параметры со значениями по умолчанию не
    передаются — эти значения уже заданы в PowerShell-скрипте.
    """
    validate_arguments(count, interval_ms)
    command = [
        powershell_exe,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script_path,
        "-ReaderHost",
        host,
        "-Port",
        str(port),
        "-Count",
        str(count),
        "-IntervalMs",
        str(interval_ms),
    ]
    if duration_ms != DEFAULT_DURATION_MS:
        command.extend(["-DurationMs", str(duration_ms)])
    if mode != "Beep":
        command.extend(["-Mode", mode])
    return command


def main(argv: Sequence[str] | None = None) -> int:
    """Разбирает аргументы CLI, запускает PowerShell и возвращает его код.

    При ``--disable-continuous`` скрипт не воспроизводит импульс, а просит
    ридер отключить штатный непрерывный зуммер. Иначе PowerShell включает
    зуммер на ``duration_ms``, выключает его и повторяет действие ``count`` раз.
    Вывод SDK передаётся в консоль без изменения, чтобы были видны ответы
    устройства вроде ``0|OK`` или текст ошибки.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    try:
        env = load_env(PROJECT_DIR / ".env")
        default_host = require_env(env, "READER_HOST")
        default_port = env_int(env, "READER_PORT")
    except ConfigError as error:
        parser.error(str(error))

    parser.add_argument("--count", type=int, default=1, help="Количество звуковых импульсов.")
    parser.add_argument("--interval-ms", type=int, default=500, help="Пауза между импульсами, мс.")
    parser.add_argument("--duration-ms", type=int, default=DEFAULT_DURATION_MS, help="Длительность импульса, мс.")
    parser.add_argument("--host", default=default_host, help="IP-адрес из READER_HOST в .env.")
    parser.add_argument("--port", type=int, default=default_port, help="Порт из READER_PORT в .env.")
    parser.add_argument("--disable-continuous", action="store_true", help="Отключить постоянный зуммер и выйти.")
    args = parser.parse_args(argv)

    validate_arguments(args.count, args.interval_ms)
    if args.duration_ms < 1:
        parser.error("--duration-ms должен быть не меньше 1")
    if not 1 <= args.port <= 65535:
        parser.error("--port должен быть от 1 до 65535")

    script_path = PROJECT_DIR / "reader_buzzer.ps1"
    mode = "Disable" if args.disable_continuous else "Beep"
    command = build_powershell_command(
        powershell_exe="powershell.exe",
        script_path=str(script_path),
        host=args.host,
        port=args.port,
        count=args.count,
        interval_ms=args.interval_ms,
        duration_ms=args.duration_ms,
        mode=mode,
    )
    result = subprocess.run(command, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=__import__("sys").stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
