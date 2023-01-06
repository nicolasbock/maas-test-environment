"""The project configuration."""

import setuptools


setuptools.setup(
    name="maaslab",
    use_scm_version=True,
    author="Nicolas Bock",
    install_requires=[
        'setuptools_scm',
    ],
    packages=setuptools.find_packages(),
    entry_points={
        'console_scripts': [
            'maaslab = maaslab.main:main',
        ]
    },
)
