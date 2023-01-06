"""Test libvirt virtualzation."""

import unittest

from maaslab.virtualization_libvirt import VirtualMachineLibvirt


class TestLibvirt(unittest.TestCase):
    """"Test libvirt virtualization."""
    def test_info(self):
        """Test the info method."""
        machine = VirtualMachineLibvirt('image')
        self.assertEqual(machine.info(), 'instance-00001')
