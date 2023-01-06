"""Main function."""

import argparse
from importlib.metadata import version, PackageNotFoundError
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
    return parser.parse_args()


def main():
    """The main function."""
    options = parse_commandline()  # pragma: no mutate
    print(f'Deploying on {options.series}')
