"""Virtualization driver for libvirt."""

from maaslab.virtualization import VirtualMachine


class VirtualMachineLibvirt(VirtualMachine):
    """A libvirt based virtual machine."""

    def __init__(self, image_name: str):
        """Create a libvirt virtual machine."""

    def info(self) -> str:
        """Get information on virtual machine."""
        return 'instance-00001'

    def start(self):
        """Start a libvirt based virtual machine."""

    def __str__(self) -> str:
        """Convert virtual machine into a string."""
        return f'libvirt, domain f{self.info()}'
