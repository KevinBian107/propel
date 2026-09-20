"""Allow `python -m propel_cli ...` as an entry point.

The console script (`propel`) is the normal way in, but it only exists once the
package is pip-installed and its bin directory is on PATH. Module execution
works from any interpreter that can import the package, which is what the
launcher relies on: it is already running inside such an interpreter, so it can
always re-invoke itself without depending on how the user's PATH is set up.
"""

from .cli import cli

if __name__ == "__main__":
    cli()
