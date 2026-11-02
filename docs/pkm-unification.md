# PKM unification (Hermes, Obsidian, iOS)

One knowledge base (the PKM, also called the Second Brain) shared by the PC (Obsidian and Claude Code),
lilith (Hermes, see [lilith.md](lilith.md)) and the iPhone. Public notes travel by Git, personal notes
travel by a LAN file sync.

## Design

| Piece | Where | Role |
|-------|-------|------|
| `BorjaIP/pkm` repo | GitHub, public | Public material only: saved URLs, technical documentation and similar. Obsidian commits to it |
| Vault folder `pkm/pkm` | PC, israfel, lilith | Public notes, `private/` and `wiki/`. Replicated two-way by Syncthing over the LAN |
| `pkm/private/` | Inside the vault, git-ignored | Everything personal. Never reaches Git |
| Clone at `~/pkm` | lilith | Hermes' working directory (`terminal.cwd`) |
| Apple Notes and Reminders bridge | Separate scripts or container | Reads iCloud data on demand. Kept apart from the PKM so iCloud credentials and session stay isolated from the vault and the agents |

Why it is built this way:

- The repo is public, so personal content lives in `private/` and is never committed.
- Syncthing keeps real local copies on every machine. Hermes skips files that take more than 5 s to
  read, so a lazy cloud mount does not work.
- israfel is the always-on hub, so the PC and lilith sync even when the other is off. Details, numbers
  and caveats: [syncthing-israfel.md](syncthing-israfel.md).
- The bridge is a separate component so Hermes never holds the Apple password in its config, `.env` or
  memory.

## Rules

- Git commits come only from Obsidian. Nothing on lilith commits or pushes.
- A push to `main` publishes the GitHub Pages site (`deploy.yaml`) within minutes. Everything committed is
  public.
- Syncthing has no history or conflict handling like Git. Keep one writer per subfolder of `private/`.
- Handoffs between agents (`_agents/bus/`) are public if they live in the repo; sensitive ones go in
  `private/`.
- Bridge output (`ios/notas`, `ios/recordatorios`) lands in `private/`, not in Git.
- Hermes does not write to the vault without approval: `memory.write_approval: true` makes memory writes
  wait for `/memory pending` and `/memory approve`.
- `pkm/private/` is human territory in `.claude/WIKI.md`.

## Prerequisites

- lilith running Hermes, user `bis`, SSH access (see [lilith.md](lilith.md)).
- A Syncthing cluster between the PC, israfel and lilith ([syncthing-israfel.md](syncthing-israfel.md)).
- A GitHub deploy key for `BorjaIP/pkm`, added by the owner in the repo settings.

## Set up Hermes on the vault

Run on lilith as `bis`.

1. Generate the deploy key (ed25519, no passphrase, mode 600) at `~/.ssh/pkm_deploy` and add its public
   key to `BorjaIP/pkm` as a deploy key.
2. Add the alias `github-pkm` to `~/.ssh/config`, using only that key. Check the GitHub host key against
   the fingerprint published by `api.github.com/meta` before trusting it.
3. Clone the repo to `~/pkm` with the URL `git@github-pkm:BorjaIP/pkm.git`.
4. Set in `~/.hermes/config.yaml`:

   ```yaml
   terminal:
     cwd: /home/bis/pkm
   memory:
     write_approval: true
   ```

   Hermes loads `AGENTS.md` from its working directory. Keep a copy of the file before editing it.
5. Add one entry to `~/.hermes/memories/MEMORY.md` with the vault path and the rule: read `AGENTS.md`, then
   `pkm/wiki/catalog.md`, cite the note, never commit or push.
6. Restart the gateway:

   ```bash
   systemctl --user restart hermes-gateway.service
   ```

7. Install and pair Syncthing for the `pkm-vault` folder (`scripts/lilith/install-syncthing.sh`,
   `scripts/syncthing/pair-pkm.sh`).

Skills use absolute paths (for example `/home/bis/corefit-booker`), so the working directory does not
affect them.

## Where the rules for agents live

| File (in the `pkm` repo) | Content |
|--------------------------|---------|
| `AGENTS.md` | Section "Lilith (Hermes) on the home server": what she is, that PKM and Second Brain are the same thing, how to use the vault (vault first, `.claude/WIKI.md`, notes in English, talk to the owner in Spanish), what she may do (edit notes under `pkm/`) and must not do (secrets, private data, infrastructure files, force-push, `reset --hard`) |
| `.claude/WIKI.md` | Wiki schema. Scripts and skills are in `.claude/` at the repository root; `wiki/`, `notes/` and `articles/` are relative to the vault folder `pkm/` |

Infrastructure files are committed from the repo, not from Obsidian.

## Verify

1. Command line, on lilith:

   ```bash
   hermes -z "search my pkm for Kubernetes networking"
   ```

   Expected: notes with paths that exist in `~/pkm`.
2. Telegram: ask Lilith a question about the vault. Expected: she answers from the PKM and the wiki and
   cites note paths.
3. Discovery: in a fresh one-shot session, ask what the repo is, how she accesses it and what she can
   and cannot do. Expected: she answers from `AGENTS.md`.

## iOS Notes and Reminders bridge

Goal: Hermes queries Apple Notes and Reminders **on demand** (search, read, extract insights). There is no
sync, no dump and no duplicate, because the data already lives on the phone. Hermes may modify some of
it, never password-locked notes. Anything Hermes needs to write down goes into `pkm/private/notes/` or
`pkm/private/reminders/`, as its own note related to what it found, never as a copy of the source.

### Tool

[`timlaing/pyicloud`](https://github.com/timlaing/pyicloud) (MIT, Python >= 3.10) covers both apps. It is
the maintained code behind the `pyicloud` package on PyPI.

| Service | Capability |
|---------|------------|
| Notes | **Read only.** `recents`, `folders`, `in_folder`, `iter_all`, `get` (with attachments), `iter_changes`, `render_note` (HTML), `export_note`. `get` raises `NoteLockedError` for passphrase-locked notes. No full-text search; the CLI offers title search, so searching bodies means fetching notes |
| Reminders | **Read and write.** Lists, reminders, `create`, `update`, `delete`, alarms and location triggers, hashtags, URL attachments, recurrence rules, change feed. No search API; filter client-side |
| Auth | Apple ID password plus 2FA, trusted session cached on disk, optional keepalive (`refresh_interval`, default 5 minutes) |

### Planned shape

- A small service in its own container on lilith holds the Apple session and exposes a few tools to
  Hermes through its MCP client.
- Search fetches on demand. If it is too slow, an in-memory index that is never written to disk keeps the
  "no duplicates" rule.
- Apple Notes are read-only with this stack. "Editing" a note means Hermes writing its own note in
  `pkm/private/notes/`. Only Reminders can be created, completed or changed in iCloud.
- The container keeps the Apple password out of Hermes' config, `.env` and memory. It is not a hard
  boundary: `bis` has passwordless `sudo`, so Hermes could still reach a container volume.
- Advanced Data Protection may block web access to iCloud. If the first login test fails, check it first.

### Options to write to Apple Notes

Apple has no public API for Notes ([overview](https://pintonotes.com/blog/apple-notes-api)). Every write
path is unofficial.

| Path | Needs | Edits existing notes | Main limits |
|------|-------|----------------------|-------------|
| Reverse-engineered CloudKit: [`icloud-md`](https://github.com/coddingtonbear/icloud-md) (MIT; same approach in [Notes-Of-Fruit](https://github.com/sharkusmanch/Notes-Of-Fruit)) | Linux, Node 20+, a real browser window for the login | Yes: "surgical writes" that keep Apple's text format; rich text, tables and checklists both ways | Its README warns that **data loss is a real possibility** and that it likely **requires Advanced Data Protection off**. Notes with attachments (other than tables) and very large notes are read-only. Attachments cannot be uploaded. Folders are only created. Works as a clone/pull/push mirror of all notes, which clashes with the "no dump" rule |
| A Mac with AppleScript or Shortcuts, driven through an MCP server ([`xiaofeng-han/apple-notes-mcp`](https://github.com/xiaofeng-han/apple-notes-mcp) has an `edit_note` tool; [`sweetrb/apple-notes-mcp`](https://github.com/sweetrb/apple-notes-mcp) and [`vinny1575/apple-notes-mcp`](https://github.com/vinny1575/apple-notes-mcp) document Hermes setup) | A Mac that is on and signed in to the same Apple ID | Yes, through Notes.app itself | macOS only; Automation permission and one Shortcut confirmation; not tested here. Some appends are not atomic and one server replaces a note by delete-and-create, which changes its identity |
| `pyicloud` | Linux | No (read only) | See above |
| `icloud-cli-tools` over IMAP with an app-specific password | Linux | Only `add`, no edit | Unverified whether notes in the current iCloud format are visible over IMAP |
| iPhone Shortcuts ("Append to Note", "Find Notes") | The phone | Yes, on the device | No way found for a server to trigger them. A queue file read by a scheduled Shortcut is an unverified idea |

Build order when this is implemented: define what Hermes has to do with Notes (real examples), pick the
write path, define the security model, then build and test against a disposable test note and a test
Reminders list, after a backup of the Notes.

## Open points

1. Hermes on the PC as well, or only Claude Code.
2. Which Notes and Reminders content is sensitive and must stay out of what an external model reads.
3. Advanced Data Protection on the Apple ID; willingness to use a secondary Apple ID.
4. Access to a Mac.
