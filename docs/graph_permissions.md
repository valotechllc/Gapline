# Microsoft 365 Evidence Collector — Permission Set

**Principle:** read-only, application permissions, certificate auth (no client secrets), least privilege. Customers' IT people will read this list before they consent. Every permission should map to a control you can name.

## Microsoft Graph — application permissions (all `.Read`)

| Permission | What you read | 800-171 controls it evidences |
|---|---|---|
| `Policy.Read.All` | Conditional Access, authentication methods policy, security defaults, authorization policy | 3.1.1, 3.1.2, 3.5.3, 3.1.12, 3.1.20 |
| `Directory.Read.All` | Users, groups, guests, disabled accounts | 3.1.1, 3.5.1, 3.5.2, 3.5.6, 3.9.2 |
| `RoleManagement.Read.Directory` | Privileged role assignments, PIM eligibility | 3.1.5, 3.1.6, 3.1.7 |
| `UserAuthenticationMethod.Read.All` | Which users actually registered MFA | 3.5.3 |
| `AuditLog.Read.All` | Sign-in logs, directory audit logs, MFA registration report | 3.3.1, 3.3.2, 3.1.8, 3.5.3 |
| `DeviceManagementConfiguration.Read.All` | Intune config profiles, compliance policies, BitLocker/FileVault settings | 3.4.1, 3.4.2, 3.13.16, 3.1.10 |
| `DeviceManagementManagedDevices.Read.All` | Device inventory, compliance state, encryption status, OS versions | 3.4.1, 3.13.16, 3.14.1, 3.1.18 |
| `SecurityEvents.Read.All` | Microsoft Secure Score + control profiles | Cross-check only — not evidence on its own |
| `SharePointTenantSettings.Read.All` | External sharing settings | 3.1.3, 3.1.22 |
| `Organization.Read.All` | Tenant info, licenses (to detect P1/P2 gaps) | Scoping |
| `AuditLogsQuery.Read.All` | Purview unified audit log queries | 3.3.1, 3.3.4 |

**Do not request:** any `.ReadWrite`, `Mail.Read`, `Files.Read.All`, `Sites.Read.All`. You don't need content, and asking for it ends the sales call. It also risks pulling CUI into your system.

## What Graph can't give you (needs Exchange Online / Security & Compliance PowerShell)

App-only certificate auth, **View-Only** roles:
- Mailbox auditing status, audit log retention → 3.3.1
- DLP policies, retention policies, sensitivity label policies → 3.1.3, 3.8.x
- Transport rules / TLS enforcement → 3.13.8
- Malware & anti-phishing policies → 3.14.2, 3.14.6

Plan for this from day one. Many "Microsoft compliance" tools skip it and miss half the audit and data-protection evidence.

## Licensing traps — detect and report, don't fail silently

- **Sign-in logs** over the API need **Entra ID P1**. With no P1, mark those objectives `unknown`, not `not_met`.
- **Risky users / Identity Protection** needs **P2**. Optional evidence only.
- **Intune** data exists only if they actually use Intune. Many small shops don't. Fall back to the interview plus uploaded screenshots.

## GCC High is a separate world

- Endpoints differ: `graph.microsoft.us`, `login.microsoftonline.us`. PowerShell uses its own GCC High environment names.
- A commercial multi-tenant app **cannot** be consented in a GCC High tenant. You need a **separate app registration in the US Government cloud**.
- Your target customers handling CUI are disproportionately on GCC High. Support both clouds from the start, behind one collector interface.

## Consent flow

1. Customer's Global Admin clicks your admin-consent URL.
2. Show this exact permission list with the "why" column before redirecting.
3. Store tenant ID only. Use certificate-based tokens and rotate the certificates.
4. Give them a one-click "revoke" instruction (delete the enterprise app). It builds trust.

Verify current permission names and license requirements against Microsoft's Graph permissions reference before shipping. Microsoft renames and splits these periodically.
