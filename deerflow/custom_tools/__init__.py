"""Purpose-built DeerFlow tools for Cory's home fleet.

Mounted into the gateway container at /app/backend/custom_tools, which is on
the import path because the gateway runs with PYTHONPATH=. from /app/backend.
Referenced from config.yaml via `use: custom_tools.<module>:<tool>`.
"""
