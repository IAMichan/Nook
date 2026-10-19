# Security Policy

Nook has access to sensitive local context—including screen text, calendars, microphone audio, and coding-agent shell hooks—so we take security issues seriously.

## Reporting a Vulnerability

Please **do not** report security vulnerabilities in public GitHub issues. Instead, use [GitHub Private Vulnerability Reporting](https://github.com/IAMichan/nook/security/advisories/new).

Whenever possible, please include:
- A clear description of the issue and its potential impact
- Step-by-step reproduction instructions or a proof of concept
- The affected version or commit hash

You will receive an initial response within 7 days.

## Scope of Particular Interest

- Prompt injection via screen OCR text, calendar items, emails, web pages, or tool outputs that leads to an unapproved action or memory poisoning
- Unauthorized access to the local Unix hook socket or companion server by another user or untrusted process
- Leakage of API keys, OAuth tokens, or local database contents (`nook.sqlite`)
- Dangerous shell commands that bypass `CommandRisk` classification or SSRF bypasses in `NetworkGuard`

## Supported Versions

Security updates are applied to the latest commit on the `main` branch.
