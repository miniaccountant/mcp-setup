# Mini Accountant — MCP setup

Connect your AI assistant to your [Mini Accountant](https://ad.miniaccountant.app)
workspace through our hosted **Model Context Protocol (MCP)** server. No local
setup, no API keys — the server is remote and protected by OAuth 2.1, so you sign
in once with your Mini Accountant account and your assistant acts on your behalf.

- **Server:** `mini-accountant`
- **Transport:** streamable HTTP
- **URL:** `https://mcp.miniaccountant.app/v1beta`
- **Auth:** OAuth 2.1 / OIDC (Authorization Code + PKCE) — you'll be prompted to sign in.

## What you can do

Once connected, the assistant can:

- **Invoices** — create, read, update, delete; add/update/remove positions and
  transactions; change the customer on an invoice.
- **Customers** — create, read, update, delete; set a customer's payment method.
- **Expenses** — create, read, update, delete; fetch expenses for a period.
- **Services** — manage your reusable product/service catalogue.
- **Payment settings** — manage the payment-method documents customers reference.
- **Analytics** — run reporting queries; get invoices/transactions/expenses for a
  date range; estimate tax for a period.
- **Account** — read and update your user profile and app settings.

Guided **skills** and **prompts** (e.g. "create an invoice") are also exposed so
the assistant discovers the right workflow automatically.

---

## Install in Claude Code (plugin)

The quickest path — installs the remote server as a plugin, no manual config file.

```
/plugin marketplace add miniaccountant/mcp-setup
/plugin install mini-accountant@miniaccountant
/reload-plugins
```

Then run `/mcp` and complete the OAuth sign-in when prompted. That's it — the
`mini-accountant` tools are now available in your session.

> Prefer not to use the marketplace? Add the server directly:
> ```
> claude mcp add --transport http mini-accountant https://mcp.miniaccountant.app/v1beta
> ```

---

## Connect from other clients

Same remote URL, same OAuth sign-in — only the config location differs.

### Claude Desktop / claude.ai connectors

Add a **custom connector** pointing at the server URL:

1. Open **Settings → Connectors → Add custom connector** (claude.ai) or the
   equivalent in Claude Desktop.
2. Name: `Mini Accountant`
3. URL: `https://mcp.miniaccountant.app/v1beta`
4. Save, then connect and sign in with your Mini Accountant account when prompted.

### Cursor

Add to `~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (per-project):

```json
{
  "mcpServers": {
    "mini-accountant": {
      "url": "https://mcp.miniaccountant.app/v1beta"
    }
  }
}
```

Reload Cursor, then authorize the server when Cursor opens the OAuth prompt.

### VS Code (GitHub Copilot / MCP) and other clients

Any client that supports remote/streamable-HTTP MCP servers works with the same
endpoint. Use the client's HTTP-server form:

```json
{
  "servers": {
    "mini-accountant": {
      "type": "http",
      "url": "https://mcp.miniaccountant.app/v1beta"
    }
  }
}
```

---

## Authentication

The server implements OAuth 2.1 / OpenID Connect with:

- Authorization Code grant + **PKCE (S256)**, refresh tokens.
- Dynamic Client Registration (RFC 7591) — clients register automatically.
- Discovery documents:
  - `https://mcp.miniaccountant.app/.well-known/oauth-authorization-server`
  - `https://mcp.miniaccountant.app/.well-known/oauth-protected-resource`
  - `https://mcp.miniaccountant.app/.well-known/openid-configuration`

Compliant MCP clients discover these automatically — you only need the server URL.
Tokens are issued to your account; the assistant can only see and change **your**
data.

---

## Troubleshooting

- **`401 Unauthorized` / prompted to sign in again** — the access token expired
  (1h TTL). Re-run the client's connect/authorize action.
- **Tools don't appear** — confirm the client finished the OAuth flow (in Claude
  Code, run `/mcp` and check the server shows *connected*).
- **Wrong workspace** — sign out of the connector and reconnect with the correct
  Mini Accountant account.

## Support

- Website: https://ad.miniaccountant.app
- Support: support@miniaccountant.app
