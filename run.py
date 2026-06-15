#!/usr/bin/env python3
"""Launch the WHOOP menu-bar app + local dashboard.

    python run.py

This is a thin wrapper around `python -m whoop_dashboard menubar`.
"""

from whoop_dashboard.menubar import main

if __name__ == "__main__":
    main()
