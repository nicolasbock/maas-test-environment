"""Main function."""

import argparse
from importlib.metadata import version, PackageNotFoundError
try:
    __version__ = version("maaslab")
except PackageNotFoundError:
    # package is not installed
    __version__ = 'undefined'


def parse_commandline():
    """Parse the commandline and return a NameSpace object."""
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--version',
        help='Print the program version',  # pragma: no mutate
        action='version',
        version=__version__,
    )
    return parser.parse_args()


def main():
    """The main function."""
    options = parse_commandline()
    print(options)
