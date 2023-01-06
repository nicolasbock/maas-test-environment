"""Tests for command line parsing."""

import unittest
try:
    # python 3.4+ should use builtin unittest.mock not mock package
    from unittest.mock import patch
except ImportError:
    from mock import patch  # type: ignore
import argparse
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

    def test_options(self):
        """Test whether a Namespace object is returned."""
        with patch.object(sys, 'argv', ['prog']):
            options = maaslab.main.parse_commandline()
        self.assertTrue(isinstance(options, argparse.Namespace))

    def test_incorrect_series(self):
        """Test `--series` argument with incorrect value."""
        with patch.object(sys, 'argv', ['prog', '--series', 'xx']):
            with self.assertRaises(SystemExit) as exit_code:
                maaslab.main.parse_commandline()
        self.assertEqual(exit_code.exception.code, 2)

    def test_default_series(self):
        """Test the default series."""
        with patch.object(sys, 'argv', ['prog']):
            options = maaslab.main.parse_commandline()
        self.assertEqual(options.series, 'focal')

    def test_series(self):
        """Test legal values of `--series` argument."""
        for series in ['bionic', 'focal', 'jammy']:
            with patch.object(sys, 'argv', ['prog', '--series', series]):
                options = maaslab.main.parse_commandline()
            self.assertEqual(options.series, series)

    def test_default_provider(self):
        """Test the default virtualization provider argument."""
        with patch.object(sys, 'argv', ['prog']):
            options = maaslab.main.parse_commandline()
        self.assertEqual(options.provider, 'libvirt')

    def test_provider(self):
        """Test virtualization provider argument."""
        for provider in ['libvirt']:
            with patch.object(sys, 'argv', ['prog', '--provider', provider]):
                options = maaslab.main.parse_commandline()
            self.assertEqual(options.provider, provider)
