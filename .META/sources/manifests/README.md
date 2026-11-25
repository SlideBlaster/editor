# Source manifests

Source manifests are tracked records for external material. Each manifest must
state:

1. source name and canonical upstream location;
2. exact immutable revision or content digest;
3. acquisition date and reproduction command;
4. included and excluded paths;
5. license and attribution evidence;
6. generated artifacts derived from the source; and
7. decision or ADR authorizing its use, when accepted.

Do not place a checkout, archive, generated catalog, or large evidence bundle in
this directory. A local checkout belongs in a sibling directory under
`.META/sources/` and is ignored.
