# Microsoft 365 Evidence Collector — Permission Set

**Principle:** read-only, application permissions, certificate auth (no client secrets), least privilege. Customers' IT people will read this list before they consent. Every permission should map to a control you can name.

## Microsoft Graph — application permissions (all `.Read`)

| Permission | What you read | 800-171 controls it evidences |
|---|---|---|
| `Policy.Read.All` | Conditional Access, authentication methods policy, security defaults, authorization policy | 3.1.1, 3.1.2, 3.5.3, 3.1.12, 3.1.20 |
| `Directory.Read.All` | Users, groups, guests, disabled accounts, tenant info and licenses (`/organization`, `/subscribedSkus`) | 3.1.1, 3.5.1, 3.5.2, 3.5.6, 3.9.2; licenses for scoping |
| `RoleManagement.Read.Directory` | Privileged role assignments, PIM eligibility (PIM needs P2, see below) | 3.1.5, 3.1.6, 3.1.7 |
| `UserAuthenticationMethod.Read.All` | Each user's registered methods. Needed only for tenants without P1, where the registration report isn't available | 3.5.3 |
| `AuditLog.Read.All` | Sign-in logs, directory audit logs, MFA registration report (`userRegistrationDetails`), last sign-in per user (`signInActivity`) | 3.3.1, 3.3.2, 3.1.8, 3.5.3, 3.5.6 |
| `DeviceManagementConfiguration.Read.All` | Intune config profiles, compliance policies, BitLocker/FileVault settings | 3.4.1, 3.4.2, 3.13.16, 3.1.10 |
| `DeviceManagementManagedDevices.Read.All` | Device inventory, compliance state, encryption status, OS versions | 3.4.1, 3.13.16, 3.14.1, 3.1.18 |
| `SecurityEvents.Read.All` | Microsoft Secure Score + control profiles | Cross-check only — not evidence on its own |
| `SharePointTenantSettings.Read.All` | External sharing settings | 3.1.3, 3.1.22 |
| `AuditLogsQuery.Read.All` | Purview unified audit log queries. **Commercial cloud only**: Microsoft lists this API as unavailable in US Gov L4 (GCC High) and L5 (DoD) | 3.3.1 |

`Organization.Read.All` was dropped: `Directory.Read.All` already reads `/organization` and `/subscribedSkus`, so it only added a line to the consent screen. Add it back only if you later swap `Directory.Read.All` for narrower permissions.

`AuditLogsQuery.Read.All` covers every service's audit log. Microsoft also publishes per-service variants (`AuditLogsQuery-Exchange.Read.All`, `-SharePoint`, `-OneDrive`, `-Entra`, `-Endpoint`, `-CRM`). If your checks only need a few services, request those instead. 3.3.4 (alert when audit logging fails) was removed from this row: reading the log doesn't show that anyone gets alerted when logging stops.

**Decide before shipping:**
- `DeviceManagementApps.Read.All` reads Intune **app protection policies**, which is how many small shops control BYOD phones without enrolling them (3.1.18, 3.1.19). Without it, those shops show no mobile evidence at all.
- Risky users (listed as optional below) needs `IdentityRiskyUser.Read.All`, which isn't on this list. Add it, or drop that evidence from the plan.

**Do not request:** any `.ReadWrite`, `Mail.Read`, `Files.Read.All`, `Sites.Read.All`. You don't need content, and asking for it ends the sales call. It also risks pulling CUI into your system.

**Audit logs carry content too.** Unified audit records include file names, site and file URLs, and for some Exchange mailbox operations the message subject. A file name like `F-35 bracket rev C.dwg` can itself be CUI. Query only the operations a check needs, and store counts or settings rather than raw user-activity records.

## What Graph can't give you (needs Exchange Online / Security & Compliance PowerShell)

App-only certificate auth:
- Mailbox auditing status, audit log retention → 3.3.1
- DLP policies, retention policies, sensitivity label policies → 3.1.3, 3.8.x
- Transport rules / TLS enforcement → 3.13.8
- Malware & anti-phishing policies → 3.14.2, 3.14.6

What this adds to onboarding:
- **Another permission on the consent screen.** App-only PowerShell needs `Exchange.ManageAsApp` on the **Office 365 Exchange Online** API (Exchange Online) and on **Microsoft Exchange Online Protection** (Security & Compliance). It sounds alarming ("manage"), so the "why" column has to explain that it grants nothing by itself.
- **A second step after consent.** `Exchange.ManageAsApp` does nothing until the customer assigns a role to your service principal. Microsoft lists two read-only Entra roles as supported for app-only access to both Exchange Online and Security & Compliance PowerShell: **Global Reader** and **Security Reader**. Test which of your cmdlets each one can actually run before choosing. Exchange "View-Only" role groups are possible only as custom role groups bound with `New-ServicePrincipal`, which is more work for the customer. Either way, onboarding takes more than one click.
- **GCC High connection parameters:** `Connect-ExchangeOnline -ExchangeEnvironmentName O365USGovGCCHigh`; `Connect-IPPSSession -ConnectionUri https://ps.compliance.protection.office365.us/powershell-liveid/ -AzureADAuthorizationEndpointUri https://login.microsoftonline.us/organizations`.
- **Unified audit log in GCC High:** the Graph audit query API above doesn't exist there, so 3.3.1 audit evidence for GCC High tenants has to come from PowerShell (`Search-UnifiedAuditLog` in Exchange Online PowerShell). Confirm the role you assign is allowed to run it.

Plan for this from day one. Many "Microsoft compliance" tools skip it and miss half the audit and data-protection evidence.

## Licensing traps — detect and report, don't fail silently

- **Sign-in logs** over the API need **Entra ID P1**. With no P1, mark those objectives `unknown`, not `not_met`.
- **Log retention is short.** Entra sign-in and audit logs are kept 7 days on Free and 30 days on P1/P2, so the API can never show a long audit trail. Evidence that logs are *retained* (3.3.1) means checking where they're exported (diagnostic settings to Log Analytics, Sentinel or a storage account). That's an Azure Resource Manager setting, outside Graph and outside this permission set: ask in the interview and get a screenshot, or request Azure RBAC Reader separately.
- **`signInActivity`** (last sign-in per user, used for 3.5.6 inactive accounts) needs **P1**.
- **MFA registration report** (`userRegistrationDetails`) needs **P1**. Without P1, read each user's registered methods with `UserAuthenticationMethod.Read.All` instead.
- **Registration is not enforcement.** A user can have MFA methods registered and never be prompted. Evidence for 3.5.3 has to come from Conditional Access or security defaults. Don't mark it met from registration data alone.
- **Conditional Access** needs **P1**. Without it, MFA enforcement comes from security defaults (readable with `Policy.Read.All`) or legacy per-user MFA. Per-user MFA state was only exposed in Graph beta when this was written; verify before relying on it.
- **PIM** (eligible role assignments) needs **Entra ID P2** or **Entra ID Governance**. Without it, active role assignments still cover 3.1.5/3.1.6.
- **Risky users / Identity Protection** needs **P2**. Optional evidence only.
- **Intune** data exists only if they actually use Intune. Many small shops don't. Fall back to the interview plus uploaded screenshots.

## GCC High is a separate world

- Endpoints differ: `graph.microsoft.us`, `login.microsoftonline.us`. PowerShell uses its own GCC High environment names (above). GCC (not High) tenants use the commercial endpoints.
- A commercial multi-tenant app **cannot** be consented in a GCC High tenant. You need a **separate app registration in the US Government cloud**.
- **Not every Graph API exists there.** Check the national-cloud table on each API's reference page. Of the APIs above, the Purview audit log query is commercial-only. Conditional Access, sign-ins, directory audits, the MFA registration report, PIM, SharePoint settings, risky users and Secure Score all list US Gov L4 support.
- Your target customers handling CUI are disproportionately on GCC High. Support both clouds from the start, behind one collector interface that reports "not available in this cloud" as `unknown`, not as a failure.

## Consent flow

1. Customer's Global Admin (or Privileged Role Administrator) clicks your admin-consent URL.
2. Show this exact permission list with the "why" column before redirecting.
3. Have them assign the read-only role you chose (Global Reader or Security Reader) to your service principal for the Exchange / Security & Compliance checks. Detect when it's missing and say so in the report.
4. Store tenant ID only. Use certificate-based tokens and rotate the certificates. Keep private keys in a key vault or HSM, never in the database or repo. One app registration (and certificate) per cloud.
5. Give them a one-click "revoke" instruction (delete the enterprise app). It builds trust.

Verify current permission names and license requirements against Microsoft's Graph permissions reference before shipping. Microsoft renames and splits these periodically.

## Verification notes (2026-10-14)

Checked against the sources of Microsoft's own docs (`microsoftgraph/microsoft-graph-docs-contrib`, `MicrosoftDocs/entra-docs`, `MicrosoftDocs/office-docs-powershell` on GitHub):
- All permission names above exist in the Graph permissions reference.
- `/organization` and `/subscribedSkus` accept `Directory.Read.All`.
- `userRegistrationDetails` needs `AuditLog.Read.All`. Entra docs say the Usage & insights reports need P1/P2.
- `signInActivity` needs P1/P2 plus `AuditLog.Read.All`.
- National-cloud tables: the audit log query API is listed as global only; the other APIs named above list US Gov L4.
- Entra log retention: 7 / 30 / 30 days (Free / P1 / P2).
- `Exchange.ManageAsApp` on both resources, Global Reader and Security Reader supported for both Exchange Online and Security & Compliance app-only, and the GCC High connection parameters, all from Microsoft's app-only authentication article.

Not verified (from memory or not in those sources): the PIM P2 requirement (the docs page only links to Governance licensing), the GCC endpoint statement, the per-user MFA beta API, that audit records include message subjects, and which cmdlets Global Reader or Security Reader can run.
