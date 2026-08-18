# The scenario-driver environment: identical to development except for its
# database (storage/scenario.sqlite3, see database.yml) — the headless
# driver and MCP tester must never touch the play save.
require_relative "development"
