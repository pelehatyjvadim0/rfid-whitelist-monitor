import unittest

from beep_reader import build_powershell_command, validate_arguments


class BeepReaderTests(unittest.TestCase):
    def test_builds_command_with_count_interval_and_reader_address(self):
        """Проверяет передачу числа импульсов, интервала и адреса в PowerShell."""
        command = build_powershell_command(
            powershell_exe="powershell",
            script_path="reader_buzzer.ps1",
            host="192.0.2.10",
            port=9090,
            count=3,
            interval_ms=500,
        )

        self.assertEqual(
            command,
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "reader_buzzer.ps1",
                "-ReaderHost",
                "192.0.2.10",
                "-Port",
                "9090",
                "-Count",
                "3",
                "-IntervalMs",
                "500",
            ],
        )

    def test_rejects_invalid_sound_parameters(self):
        """Проверяет, что нулевое число импульсов и отрицательная пауза запрещены."""
        with self.assertRaises(ValueError):
            validate_arguments(count=0, interval_ms=500)
        with self.assertRaises(ValueError):
            validate_arguments(count=1, interval_ms=-1)


if __name__ == "__main__":
    unittest.main()
