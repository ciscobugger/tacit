# Interactive mail frontend

`mail.qml` runs only the main mail window as an interactive prototype. The notch, system notification and provider sign-in page shown outside the window in the references are not app-owned surfaces. It uses local, in-memory state only. There is no socket client, HTTP call, OAuth flow, AI request or connection to the Go backend. Closing/restarting resets the session; Preview > Reset local data also resets it.

## Try it on macOS

Open `mac-preview/CMakeLists.txt` in Qt Creator and press Play with the desktop Qt kit. The local, ignored host stages the current frontend and actual Tacit.Kit parts. Alternatively run `mac-preview/run.sh` from this directory. Its optional first argument selects a starting screen, for example `mac-preview/run.sh draft`.

The ignored native Preview menu in the macOS menu bar offers incoming-mail simulation, offline/online, account setup, Settings and reset. When relevant it can simulate completion of system sign-in or Undo a pending send. These are development controls only. The host always displays the same main-window area; it never switches to a desktop scene.

## Reference coverage

All 19 supplied screenshots were inspected, including the three wallpaper variants, and the full 38.3-second walkthrough was inspected at one-second intervals. The same source covers:

| Reference | Working local interaction |
| --- | --- |
| `read-*`, `plain-Dune` | Select messages, mark read, expand/collapse each received or sent message independently, open attachment preview, open a real local fixture in its default app, save a copy on the Mac host |
| `switch-*` | Show/hide mailboxes, switch folders and accounts, dynamic unread/folder counts, access Settings and add account |
| `search-Dune` | Search across local mail/accounts, clear/close search, select results; filter unread/starred/attachments and sort newest/oldest/sender/unread |
| `draft-*` | Review the agent's sample draft, edit fields/body, select account and reply mode, Cc/Bcc, attach/remove local files, keep or discard a draft |
| `compose-Dune` | New message, editable recipients/subject/body, matching Anna contact suggestions, account selection, local sample agent draft and recipient validation |
| `sent-Dune` | Queue a local send, see sending state in the conversation, emit status for system-owned Undo, then see the message in Sent |
| `offline-Dune` | Retain queued content offline, retry, edit queued mail or keep it in Drafts; go online to deliver locally |
| `empty-Dune` | Empty mailbox state and return to Inbox; Later schedules a local return to Inbox while the app remains running |
| `setup-Dune`, `importing-Dune` | Pick a provider and request system sign-in; after its completion callback, show local import progress and read the sample mail |
| `settings-Dune` | Account removal with in-place confirmation, agent preferences/scope, undo delay, signatures, remote-picture preference, notification preference and reduced motion |
| `notify-Dune` | External system UI, excluded from app rendering. Incoming mail and actions returned from a future system notification are modelled without drawing the notification. |

Archive, Junk, Trash and star/read actions work through the message menu. Archive/move and draft discard offer Undo. Drafts and sends retain edited text and attachment references through navigation within the session. The agent scope is enforced for explicit sample drafts; the agent never sends automatically. Preferences without external services remain session settings: remote pictures are never fetched, and provider/agent work is clearly identified as simulated.

## Files and host boundaries

`MailState.qml` wraps the pure state transitions in `mail-store.js`; the other `Mail*.qml` files compose actual Kit controls. Mail previews extend `ListRow` with the message-specific rich text layout, and retain `RowList` keyboard interaction. Hover/focus, menus and motion use the existing Kit APIs and tokens. The app uses `Slab`, `Field` and `TextArea` directly. The shared `kit-style/reference.patch` changes these Kit components to match the screenshots: a filled primary pill, flat recipient/subject lines, and a document-like body. Their input, selection, keyboard and accessibility implementations remain the Kit’s. These are explicitly approved design changes to the Kit copy, not stock Kit styling. The ignored Mac adapter applies the patch automatically; an unpatched Linux Kit retains its standard appearance. Mail-specific content arrangements retain Kit list/action interaction. Text uses the original `TacitText` directly. The application files pass the Kit's colour/size/radius/opacity/symbol lint.

The three files in `fixtures/` are real local sample documents. The Mac host copies these assets into its staging folder. Attached user-selected files retain their local URLs, and the native Save picker can copy them through the host's local-file helper. No file is uploaded. On a host without that helper, saving directs the user to the default application rather than claiming a file was saved. PDF previews inside the prototype show the sample's readable summary; they are not a PDF page-rendering engine. Images chosen as attachments can be previewed directly.

The workspace uses RowLayout/ColumnLayout/GridLayout and wrapping action flows. The list has a bounded preferred width and the reader receives the remaining window area. Text is capped at a reading width; titles, forms, settings and toolbars reflow rather than scaling. The shared mail-specific content and Kit patch remain platform-independent. The ignored Mac adapter uses the original Kit Live palette calculations with local JSON transport. Its native Preview > Palette menu selects the Kit Dusk/Moss samples or loads a Tacit colors.json, which is reloaded when changed. MAIL_PALETTE may be dusk, moss or an absolute JSON path. Optional seethrough.json beside that file supplies the shell glass scale. It does not generate a palette from the current Mac wallpaper. Automatic wallpaper-palette generation remains the Linux shell's responsibility. Fonts come from the sibling font checkout. The local Mac host and its build directory remain ignored; shared frontend sources, fixtures and tests belong in the repository.

## Window sizing

The window system owns the available width and height. DUNE_W/H are only the Quickshell window's initial size request. The ignored Mac host passes its actual content size to the frontend, with no fixed canvas, zoom or letterboxing. Its rounded material follows the real window bounds.

Breakpoints derive from Kit tokens. With the current defaults, below 820 logical pixels the list and reader become separate views; Inbox returns from the message to the list. At 1120 pixels and above the optional mailboxes rail can fit beside both. When the rail cannot fit, the mailbox menu exposes folders, accounts, account setup and Settings. Settings switch between one and two columns. The Mac host permits resizing down to 400 × 400 logical pixels. Typography and control sizes do not scale with the window.

Layout tests cover 400 × 600, 560 × 500, 820 × 400, 1024 × 768 and 1720 × 972, compact navigation, wrapped subjects, composer entry fields, settings, setup, focus-ring room, and body/editor containment. The tests also ensure a new message starts at its recipient fields rather than scrolling them out of view. Native comparison renders cover narrow and wide windows. Hyprland itself has not been exercised on this Mac; no Hyprland-specific layout API is required.

## Checks

With Node 18+:

```sh
node tests/state.test.cjs
```

With the Mac adapter staged and Qt's tools on PATH (from this directory):

```sh
python3 mac-preview/prepare.py
QT_QPA_PLATFORM=offscreen qmltestrunner -input tests -import mac-preview/qml
python3 ../../../tacit-kit/tools/lint.py mail.qml Mail*.qml
```

The state tests cover read counts, search, folders, draft retention, recipient validation, attachment references, send/undo/offline/retry, notification reply, account setup/import, snooze return and agent scope. Qt Quick tests use real clicks and typing for selection, composing/sending, searching, mailbox visibility and archive/undo, plus the account/import, agent review/send/undo, notification and reduced-motion walkthroughs. Native comparison renders cover reading, replying, composing and settings at narrow and wide sizes; the setup/import and notification boundaries are also exercised by Qt tests.

## System integration boundary

`MailState` exposes requests without rendering system chrome:

- `authorizationRequested(provider)`: emitted after the person chooses a provider. The system owns its sign-in page and returns through `completeAuthorization(email)`.
- `notificationRequested(message)`: emitted for newly simulated mail when notification preferences permit it. The system owns the notification; its actions call `notificationAction("open" | "reply" | "agentReply" | "markRead" | "dismiss")`.
- `sendStatusChanged(status)`: carries pending jobs and Undo availability for the future system surface. Undo can call `act("undoSend")`; the app does not recreate the notch or a second send-status toast.

None of these signals is connected to a real system service or mail backend yet. Ordinary in-app notices for actions such as moving a message remain in the main window.
