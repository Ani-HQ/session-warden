# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report privately via [GitHub's private vulnerability reporting](https://github.com/Ani-HQ/session-warden/security/advisories/new)
on this repository. You should get an acknowledgement within a few days.

## Scope notes

session-warden runs with your user's privileges, reads OpenClaw session
state, can kill processes it identifies as wedged agent CLI children, and can
restart the OpenClaw gateway. Anything that could trick it into killing the
wrong process, executing untrusted input, or leaking credentials (Telegram
token, API keys pulled into the environment) is in scope.

Secrets should live in `~/.config/session-warden/secrets.env` (chmod 600),
never in the repo tree — `config/thresholds.env` is gitignored, but keeping
tokens out of it entirely is the safer habit.
