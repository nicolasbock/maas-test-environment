"""Tests for command line parsing."""

import unittest
try:
    # python 3.4+ should use builtin unittest.mock not mock package
    from unittest.mock import patch
except ImportError:
    from mock import patch  # type: ignore
import sys
import contextlib
import io
import maaslab.main


class TestCommandLine(unittest.TestCase):
    """Tests."""
    def test_version(self):
        """Test the `--version` argument."""
        options = None
        output = None
        with self.assertRaises(SystemExit) as exit_code:
            with patch.object(sys, 'argv', ['prog', '--version']):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    options = maaslab.main.parse_commandline()
        self.assertEqual(exit_code.exception.code, 0)
        self.assertIsNotNone(output)
        if output is not None:
            output_string = output.getvalue().rstrip()
            self.assertEqual(output_string, '0.0.0')
        self.assertIsNone(options)
