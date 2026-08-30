"""Общие функции чтения конфигурации RFID-проекта из файла `.env`."""

from __future__ import annotations

from pathlib import Path


class ConfigError(ValueError):
    """Сообщает о неверной или отсутствующей настройке проекта."""


def load_env(path: Path) -> dict[str, str]:
    """Читает простой `.env`, пропуская пустые строки и комментарии.

    Значение можно записать без кавычек либо в одиночных/двойных кавычках.
    Ошибка формата содержит номер строки, чтобы настройку было легко найти.
    """
    if not path.exists():
        raise ConfigError(f"Не найден файл настроек: {path}")

    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError as error:
        raise ConfigError(f"Не удалось прочитать {path}: {error}") from error

    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError(f"{path}:{line_number}: ожидается запись ИМЯ=ЗНАЧЕНИЕ")
        name, value = (part.strip() for part in line.split("=", 1))
        if not name:
            raise ConfigError(f"{path}:{line_number}: пустое имя переменной")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[name] = value
    return values


def require_env(values: dict[str, str], name: str) -> str:
    """Возвращает обязательную непустую настройку или выдаёт понятную ошибку."""
    value = values.get(name, "").strip()
    if not value:
        raise ConfigError(f"В .env отсутствует обязательная переменная {name}")
    return value


def env_int(values: dict[str, str], name: str, fallback: int | None = None) -> int:
    """Читает целое число из `.env`, при необходимости используя fallback."""
    raw_value = values.get(name)
    if raw_value is None:
        if fallback is None:
            raise ConfigError(f"В .env отсутствует обязательная переменная {name}")
        return fallback
    try:
        return int(raw_value)
    except ValueError as error:
        raise ConfigError(
            f"{name} в .env должен быть целым числом, получено: {raw_value!r}"
        ) from error
