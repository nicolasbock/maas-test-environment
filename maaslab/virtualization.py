"""Virtualization driver layer."""

from abc import (
    ABC,
    abstractmethod,
)


class VirtualMachine(ABC):
    """Abstract class for a virtual machine."""

    @abstractmethod  # pragma: no mutate
    def __init__(self, image_name: str):
        """Create a virtual machine."""

    @abstractmethod  # pragma: no mutate
    def info(self) -> str:
        """Get information on virtual machine."""

    @abstractmethod  # pragma: no mutate
    def start(self):
        """Start the virtual machine."""

    @abstractmethod  # pragma: no mutate
    def __str__(self) -> str:
        """Convert virtual machine into a string."""
