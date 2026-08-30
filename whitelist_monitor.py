"""Запускает фоновый EPC-монитор whitelist + buzzer для HZ120."""

from __future__ import annotations

import argparse
import logging
from logging.handlers import RotatingFileHandler
import subprocess
from pathlib import Path

from app_config import ConfigError, env_int, load_env, require_env
from reader_health import check_reader


PROJECT_DIR = Path(__file__).resolve().parent


def resolve_project_path(raw_path: str) -> Path:
    """Преобразует относительный путь в путь от директории проекта."""
    path = Path(raw_path).expanduser()
    return path if path.is_absolute() else PROJECT_DIR / path


def create_file_logger(log_path: Path) -> logging.Logger:
    """Создаёт UTF-8 журнал с ротацией: три файла не более 5 МБ каждый."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("rfid_whitelist_monitor")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.handlers.clear()
    handler = RotatingFileHandler(
        log_path,
        maxBytes=5 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    logger.addHandler(handler)
    return logger


def emit(logger: logging.Logger, message: str) -> None:
    """Одновременно выводит сообщение в консоль и сохраняет в файл."""
    print(message, flush=True)
    logger.info(message)


def main() -> int:
    """Проверяет ридер, запускает монитор и сохраняет его вывод в журнал."""
    parser = argparse.ArgumentParser(description=__doc__)
    env_path = PROJECT_DIR / ".env"
    try:
        env = load_env(env_path)
        default_host = require_env(env, "READER_HOST")
        default_port = env_int(env, "READER_PORT")
        health_timeout = env_int(env, "HEALTH_TIMEOUT_SECONDS")
        whitelist_path = resolve_project_path(require_env(env, "WHITELIST_FILE"))
        log_file = require_env(env, "LOG_FILE")
        cooldown_ms = env_int(env, "COOLDOWN_MS")
        sound_count = env_int(env, "SOUND_COUNT")
        sound_duration_ms = env_int(env, "SOUND_DURATION_MS")
        sound_interval_ms = env_int(env, "SOUND_INTERVAL_MS")
    except ConfigError as error:
        parser.error(str(error))

    parser.add_argument("--whitelist", type=Path, default=whitelist_path)
    parser.add_argument("--host", default=default_host)
    parser.add_argument("--port", type=int, default=default_port)
    parser.add_argument("--cooldown-ms", type=int, default=cooldown_ms)
    parser.add_argument("--health-timeout-seconds", type=int, default=health_timeout)
    parser.add_argument("--log-file", default=log_file)
    parser.add_argument(
        "--sound-count",
        type=int,
        default=sound_count,
    )
    parser.add_argument(
        "--sound-duration-ms",
        type=int,
        default=sound_duration_ms,
    )
    parser.add_argument(
        "--sound-interval-ms",
        type=int,
        default=sound_interval_ms,
    )
    args = parser.parse_args()
    if args.cooldown_ms < 0:
        parser.error("--cooldown-ms не может быть отрицательным")
    if not 1 <= args.sound_count <= 100:
        parser.error("--sound-count должен быть от 1 до 100")
    if not 10 <= args.sound_duration_ms <= 1000:
        parser.error("--sound-duration-ms должен быть от 10 до 1000")
    if not 0 <= args.sound_interval_ms <= 60000:
        parser.error("--sound-interval-ms должен быть от 0 до 60000")
    if not 1 <= args.port <= 65535:
        parser.error("--port должен быть от 1 до 65535")
    if not 1 <= args.health_timeout_seconds <= 60:
        parser.error("--health-timeout-seconds должен быть от 1 до 60")

    log_path = resolve_project_path(args.log_file)
    try:
        logger = create_file_logger(log_path)
    except OSError as error:
        parser.error(f"Не удалось открыть файл журнала {log_path}: {error}")

    emit(logger, f"ПРОВЕРКА: подключение к ридеру {args.host}:{args.port}")
    health = check_reader(args.host, args.port, args.health_timeout_seconds)
    if not health.ok:
        emit(logger, f"ОШИБКА ПРОВЕРКИ: {health.message}")
        return 2
    emit(
        logger,
        f"РИДЕР ДОСТУПЕН: серийный номер={health.serial_number}; "
        f"температура(raw)={health.temperature_raw}",
    )

    script = PROJECT_DIR / "one_connection_monitor.ps1"
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                "-ReaderHost",
                args.host,
                "-Port",
                str(args.port),
                "-WhitelistPath",
                str(args.whitelist),
                "-SoundCount",
                str(args.sound_count),
                "-SoundDurationMs",
                str(args.sound_duration_ms),
                "-SoundIntervalMs",
                str(args.sound_interval_ms),
                "-CooldownMs",
                str(args.cooldown_ms),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert process.stdout is not None
        for output_line in process.stdout:
            message = output_line.rstrip()
            if message:
                emit(logger, message)
        return process.wait()
    except OSError as error:
        emit(logger, f"ОШИБКА ЗАПУСКА МОНИТОРА: {error}")
        return 3
    except KeyboardInterrupt:
        emit(logger, "МОНИТОР ОСТАНОВЛЕН ПОЛЬЗОВАТЕЛЕМ")
        if process is not None and process.poll() is None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
