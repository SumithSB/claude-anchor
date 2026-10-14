# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (private security advisories). Do not open a public issue for security problems.

## What the app accesses

- **Keychain (read only):** Claude Code's own login items, read by running `/usr/bin/security`. The app does not create, modify or refresh these items.
- **Network:** the OAuth token is sent only to `api.anthropic.com`, to read usage limits. Tokens are never stored, logged or sent anywhere else.
- **`~/.claude`:** transcripts are read only, to compute usage and continue conversations. Shared settings, skills and plugins are symlinked into extra account dirs.
- **Writes:** only under `~/.claude-anchor`, plus two opt-in changes: the `claudeCode.claudeProcessWrapper` key in VS Code/Cursor user settings (gear menu toggle) and one marked line in `~/.zshrc` added by the installer.

The app is ad-hoc signed, not notarized.
