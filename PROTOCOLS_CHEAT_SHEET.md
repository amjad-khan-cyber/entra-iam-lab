# SAML vs OIDC vs OAuth vs SCIM

One-page cheat sheet, written from what I captured in my lab (Step 10): a SAML response from the Microsoft Entra SAML Toolkit and an OIDC ID token from my own app registration, both for the same test user.

## The one-line version

| Protocol | Answers | Token or message | Typical use |
|---|---|---|---|
| **SAML 2.0** | Who is this user? (authentication) | XML assertion, signed, posted by the browser | SSO into older or enterprise web apps (Salesforce, ServiceNow, Workday) |
| **OIDC** | Who is this user? (authentication) | ID token, a JWT (JSON), signed | SSO into modern web, mobile and single-page apps |
| **OAuth 2.0** | What may this app do? (authorization) | Access token, plus a refresh token | An app calling an API on a user's behalf, like my scripts calling Microsoft Graph |
| **SCIM 2.0** | Does the account exist in the app? (provisioning) | REST calls with JSON (create, update, deactivate) | Entra creating and removing accounts in SaaS apps |

OIDC is built on top of OAuth: OAuth says what an app may do, OIDC adds the ID token that says who signed in.

## Same user, two protocols

| What it means | OIDC ID token | SAML response |
|---|---|---|
| Who made it | `iss`: login.microsoftonline.com/{tenant}/v2.0 | `<Issuer>`: sts.windows.net/{tenant}/ |
| Who it's for | `aud`: the app's client ID | `<Audience>`: the app's Entity ID |
| Who it's about | `sub` (unique per app), `oid` | `<NameID>` (here the UPN, in the email format the app requires) |
| Same user everywhere | `oid` | `objectidentifier` attribute (same value as `oid`) |
| Valid until | `exp`, Unix time | `<Conditions NotOnOrAfter>`, with NotBefore 5 minutes early for clock skew |
| Tied to this sign-in | `nonce` (sent by the app, returned in the token) | `InResponseTo` (the ID of the app's SAML request) |
| How it's signed | `kid` points to Microsoft's signing key | `<Signature>` with the token signing certificate from the app's SSO page |
| MFA happened | `amr` | `authnmethodsreferences` = multipleauthn |
| When the user actually signed in | `auth_time` | `AuthnInstant` (19 minutes before the assertion was issued: the session was reused) |
| Lifetime I saw | 65 minutes | 65 minutes |

Neither one is encrypted by default: anyone holding it can read it. Apps trust it only after checking the signature, issuer, audience and expiry.

## How each one travels

- **SAML:** the app sends a SAML request through the browser to Entra (SP-initiated) or the user starts at Entra (IdP-initiated). Entra sends the signed assertion back through the browser as a form POST to the app's Reply URL (ACS). Entra and the app never talk directly.
- **OIDC / OAuth:** the app sends the browser to Entra's authorize endpoint with its client ID, redirect URI and scopes. Modern apps get a one-time code and swap it privately for tokens (authorization code flow, with PKCE for browser and mobile apps). The implicit flow, where the token comes back in the URL, is the old way; I used it only to decode a token at jwt.ms, then turned it off.
- **SCIM:** no browser. Entra's provisioning service calls the app's SCIM API when a user is assigned, changed or unassigned.

## Where each one fits in joiner, mover, leaver

| | Joiner | Mover | Leaver |
|---|---|---|---|
| HR to Entra | My JML script or HR-driven provisioning creates the account | Updates department and title | Disables the account, revokes sessions |
| Entra to SaaS (SCIM) | Creates the app account | Updates attributes in the app | Deactivates the app account |
| Sign-in (SAML/OIDC) | First SSO works because the account exists | Claims carry the new department | SSO blocked because the Entra account is disabled |

Without SCIM, a leaver can't sign in through SSO, but the app account still exists, still uses a license, and any local password or API token may still work.

## Troubleshooting I actually ran into

| Symptom | Cause | Where I saw it |
|---|---|---|
| The SSO tile opens the app's home page instead of signing in | Sign on URL pointed at the home page, not the app's SP-initiated login URL | SAML Toolkit, fixed by setting `/SAML/Login/22637` |
| Entra sends a valid assertion, then the app errors | The NameID doesn't match any account in the app (not provisioned) | SAML Toolkit: Priya signed in, but only another user was registered in the app |
| "Need admin approval" vs a consent screen | The app asks for permissions outside what users may consent to | OIDC app: Priya could consent herself to openid, profile, email |
| Token rejected by an app | Wrong `aud` / Audience, expired, or wrong issuer | What the signature, audience and expiry checks are for |

## Things to check first in a SAML ticket

1. Identifier (Entity ID) and Reply URL match exactly what the app expects
2. NameID attribute and format match how the app identifies users
3. The user is assigned in Entra and exists in the app
4. The signing certificate hasn't expired, and expiry notices go to a shared mailbox
5. Capture the response with SAML-tracer and read Issuer, Audience, NameID and the time conditions
