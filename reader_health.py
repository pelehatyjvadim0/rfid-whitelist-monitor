"""Проверяет доступность и ответ RFID-ридера до запуска EPC Inventory."""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from app_config import ConfigError, env_int, load_env, require_env


PROJECT_DIR = Path(__file__).resolve().parent


@dataclass(frozen=True)
class HealthResult:
    """Хранит итог SDK-проверки без печати и завершения процесса."""

    ok: bool
    message: str
    serial_number: str | None = None
    temperature_raw: str | None = None


def check_reader(host: str, port: int, timeout_seconds: int = 5) -> HealthResult:
    """Подключается через Hopeland SDK и проверяет ответ на запрос GetSN."""
    script = PROJECT_DIR / "reader_health.ps1"
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-ReaderHost",
        host,
        "-Port",
        str(port),
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        return HealthResult(False, f"ридер не ответил за {timeout_seconds} с")
    except OSError as error:
        return HealthResult(False, f"не удалось запустить health-check: {error}")

    if completed.returncode != 0:
        details = (completed.stderr or completed.stdout).strip()
        return HealthResult(False, details or "health-check завершился с ошибкой")

    try:
        payload = json.loads(completed.stdout.strip())
    except (json.JSONDecodeError, TypeError) as error:
        return HealthResult(False, f"неверный ответ health-check: {error}")

    serial_number = str(payload.get("serial_number", "")).strip()
    if payload.get("ok") is not True or not serial_number:
        return HealthResult(False, "ридер не подтвердил исправное состояние")

    return HealthResult(
        True,
        "ридер отвечает",
        serial_number=serial_number,
        temperature_raw=str(payload.get("temperature_raw", "")),
    )


def main() -> int:
    """Берёт адрес из `.env`, выполняет проверку и печатает итог по-русски."""
    parser = argparse.ArgumentParser(description=__doc__)
    try:
        env = load_env(PROJECT_DIR / ".env")
        default_host = require_env(env, "READER_HOST")
        default_port = env_int(env, "READER_PORT")
        default_timeout = env_int(env, "HEALTH_TIMEOUT_SECONDS")
    except ConfigError as error:
        parser.error(str(error))

    parser.add_argument("--host", default=default_host)
    parser.add_argument("--port", type=int, default=default_port)
    parser.add_argument("--timeout-seconds", type=int, default=default_timeout)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port должен быть от 1 до 65535")
    if not 1 <= args.timeout_seconds <= 60:
        parser.error("--timeout-seconds должен быть от 1 до 60")

    result = check_reader(args.host, args.port, args.timeout_seconds)
    if not result.ok:
        print(f"ОШИБКА ПРОВЕРКИ: {result.message}")
        return 1

    print(
        f"РИДЕР ДОСТУПЕН: {args.host}:{args.port}; "
        f"серийный номер={result.serial_number}; "
        f"температура(raw)={result.temperature_raw}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
