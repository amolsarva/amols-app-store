# iMessage Campaign Studio

A local, keyboard-driven campaign tool for Messages.app. It finds every person in
one-to-one iMessage/SMS history where a word or exact phrase occurs, lets you inspect
and curate the recipient set, sends an independently addressed message to each person,
and keeps a local campaign archive. Opening an archived campaign checks for inbound
messages after each send and can prepare a bump for only the people who did not reply.

## Run

```bash
./run.sh --dry-run
./run.sh
```

Use dry-run first. Dry run requires typing `SIMULATE`, never opens Messages.app, and
archives recipients under `simulated_recipients` rather than `recipients`. Live mode
requires typing `SEND` on the final review screen.

Terminal needs **Full Disk Access** to read `~/Library/Messages/chat.db`, plus
**Automation → Messages** permission to send. Campaign records are JSON files in
`campaign-archive/`; message content and recipient handles therefore remain local.
Operational events and errors are written to `imessage-campaign-studio.log` beside
the script. Search phrases are logged, but message bodies and matching snippets are not.

## Keys

- Arrow keys or `j`/`k`: move
- Space: select/unselect a recipient
- `a` / `n`: all / none
- Enter: inspect the matching-message context
- `c`: compose
- `q`: back

Group chats and business handles are deliberately excluded, preventing accidental
group posting or repeated recipients. Search is literal and case-insensitive.
