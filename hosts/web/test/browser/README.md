# Browser checks

`run.sh` serves a copy of one of the decks in `decks/` with `sb serve`, opens the editor in a
headless Chrome of its own, drives it with real mouse and key events, and prints what the
deck's source says after every step. See the top of `run.sh` for the checks there are.

These are checks to read, not tests that pass or fail on their own: they show the round trip
from a gesture on the canvas to the text it writes.
