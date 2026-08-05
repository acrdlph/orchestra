# REMOTE-ACCESS — the board from another computer

**Status:** settled. **Date:** 2026-08-05.

The board has no login screen, and minting a device token will not give it one.
`index.html` never sends an `Authorization` header — grep it, zero hits —
because on 127.0.0.1 it does not need to: a process that can open that socket
already runs as you and can read `~/.claude*` without asking this server.
Everything arriving from anywhere else is refused, with exactly two exemptions
(`GET /api/health`, `POST /api/v1/pair`).

That boundary has a consequence people meet on their second machine:
**device tokens do not help a browser.** A token is accepted only as
`Authorization: Bearer orc1_…` — never a query parameter, never a cookie, both
refused — and a browser cannot be talked into attaching a header to what you
type in the address bar. Tokens are for clients that can set one: the iOS app,
`curl`, a script.

So the answer is not to widen the bind. It is to make the request arrive on
loopback anyway.

## An SSH forward, and nothing on the board host

```bash
ssh -f -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
    -L 4242:localhost:4242 you@board-host.your-tailnet.ts.net
```

Then open **`http://localhost:4242`**. That is the whole procedure.

`-L` makes the far end open its half of the connection to *its own* 127.0.0.1,
so `auth.loopback(peer)` sees a loopback address and asks for nothing. The board
does not know the request started on another continent, and has no reason to
care: the boundary it enforces is "can you already run code as this user", and
whoever holds an SSH key to that account can.

| flag | why it is there |
|---|---|
| `-f` | fork after authenticating. The process reparents to pid 1 and outlives the terminal you started it from |
| `-N` | no remote command — a forward, not a shell. It prints nothing on success; silence is what working looks like |
| `-L 4242:localhost:4242` | local 4242 → the board's loopback 4242. That `localhost` is resolved **on the board host**, which is the entire trick |
| `ServerAliveInterval=30` | notice a dead link within 90 s instead of holding a socket open forever |
| `ExitOnForwardFailure=yes` | fail loudly when local 4242 is already taken, instead of a session that connects and forwards nothing |

**Nothing changes on the board host.** No `--tailnet`, no `--add-device`, no
config edit — the default 127.0.0.1 bind is precisely what the forward connects
to. It needs Remote Login enabled there (macOS: System Settings → General →
Sharing) and your public key in its `~/.ssh/authorized_keys`, which
`ssh-copy-id` installs in one go. Without the key everything still works and
asks for the account password on every reconnect.

## A wrapper, for when it stops being a one-off

`contrib/orchestra-tunnel.sh` is that command with its states named — `up`
(idempotent, and it first clears a forward that has stopped answering, which
`ExitOnForwardFailure` would otherwise refuse to replace), `down`, `restart`,
`status`. The host comes from the argument or `$ORCHESTRA_SSH_HOST`; `autossh`
is used when installed and plain `ssh` when not.

```bash
./contrib/orchestra-tunnel.sh up you@board-host.your-tailnet.ts.net
./contrib/orchestra-tunnel.sh status
```

`status` answers the question a blank browser tab cannot, by asking over SSH
whether the board is listening on the board host's own loopback before anything
blames the forward:

```
board host     you@board-host.your-tailnet.ts.net
board          listening on 127.0.0.1:4242 there
forward        pid 51204
dashboard      http://localhost:4242 — 200
```

## Which mechanism for which client

| client | mechanism | token |
|---|---|---|
| browser, another computer | SSH forward | none — the request is loopback |
| iOS app | `--tailnet` + pairing QR | yes; the QR exchange puts one on the phone |
| `curl`, scripts | `--tailnet` + `--add-device` | yes, as `Authorization: Bearer orc1_…` |
| browser, board host | nothing | none |

## Is it up? Ask without credentials

Under `--tailnet`, any HTTP status at all from the tailnet address proves the
server is alive — including the 401 that `/` hands an unregistered caller:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://board-host.your-tailnet.ts.net:4242/   # 401 → up
curl -s http://board-host.your-tailnet.ts.net:4242/api/health                          # exempt route, real answer
```

Without `--tailnet` nothing is listening on that address and you get a
connection refusal, which says nothing about the server. Probe through the
forward instead:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4242    # 200 → tunnel and board both healthy
```

That is the first check to run when the page will not load, because it
separates the two failures the page cannot: a dead tunnel and a dead board.

## Keeping it up

The forward dies when the board host sleeps, when either network drops, and at
reboot. Rerunning the command is the whole repair, and rerunning it while one is
already alive is safe — `ExitOnForwardFailure` turns the duplicate into an
immediate refusal rather than a second session quietly forwarding nothing.

For one that repairs itself, `autossh` wraps ssh and reconnects:

```bash
autossh -M 0 -f -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -L 4242:localhost:4242 you@board-host.your-tailnet.ts.net
```

`-M 0` disables autossh's own monitoring port and leaves the liveness question
to SSH's keepalives, which is the arrangement to prefer.

A board host that falls asleep takes the tunnel and its tailnet address down
with it. On macOS `sudo pmset -c sleep 0` keeps it awake on mains power; the lid
still has to stay open, or an external display attached, or it sleeps regardless.

## What the forward is worth, in security terms

Everything loopback is worth: reading every transcript on that machine and
typing into every terminal it can reach. Same authority as sitting at the
keyboard, which is why the key deserves the care the login password gets.

A passphrase-less key is what makes unattended reconnection possible, and is a
permanent credential in exchange. Keep it on a machine you control; revoke it by
deleting its line from `~/.ssh/authorized_keys` on the board host.

Two asymmetries against device tokens are worth knowing before choosing this
route. A token is revocable one device at a time (`--revoke-device ID`) and an
SSH key is not device-scoped. And orchestra never sees the key at all: a
forwarded request is loopback, so `audit.log.jsonl` records it as `loopback`,
indistinguishable from someone at the keyboard. The audit trail for this path
is sshd's, not the board's.
