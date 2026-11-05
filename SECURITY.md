# Security

Do not file a public issue for a vulnerability, a leaked secret, or anything that could be used against a user.

Use GitHub's private advisory: https://github.com/WalkerSucksAtCode/Paddle/security/advisories/new

The control bridge is a local Unix socket, off by default. A running Paddle with the bridge on is local code execution for the account that enabled it. Do not expose that socket.
