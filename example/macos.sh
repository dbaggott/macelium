# shellcheck shell=bash
# The example's settings list. It writes
# only to a domain of its own, so running it changes nothing that matters.
setting com.example.macelium-example greeting string hello
setting com.example.macelium-example colors array red green
# No app reads the domain; without this, a write would restart the Dock and
# Finder.
restart_on_change com.example.macelium-example MaceliumExample
