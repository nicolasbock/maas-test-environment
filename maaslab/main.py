"""Main function."""

import argparse
from importlib.metadata import version, PackageNotFoundError
from maaslab.virtualization_libvirt import VirtualMachineLibvirt
try:
    __version__ = version("maaslab")
except PackageNotFoundError:
    # package is not installed
    __version__ = 'undefined'


def parse_commandline():
    """Parse the command line and return a NameSpace object."""
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--version',
        help='Print the program version',  # pragma: no mutate
        action='version',
        version=__version__,
    )
    parser.add_argument(
        '--series',
        help='The series to deploy',  # pragma: no mutate
        choices=['bionic', 'focal', 'jammy'],
        default='focal',
    )
    parser.add_argument(
        '--provider',
        help='The virtualization provider',  # pragma: no mutate
        choices=['libvirt'],
        default='libvirt'
    )
    return parser.parse_args()


def main():
    """The main function."""
    options = parse_commandline()  # pragma: no mutate
    print(f'Deploying on {options.series}')
    if options.provider == 'libvirt':  # pragma: no mutate
        maas_server = VirtualMachineLibvirt(options.series)  # pragma: no mutate
    else:
        raise Exception(f'[FIXME] cannot handle provider f{options.provider}')
    print(maas_server)  # pragma: no mutate


if __name__ == '__main__':  # pragma: no mutate
    main()
