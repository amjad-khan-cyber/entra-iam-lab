# Conditional Access Policy Design (Lab Tenant)

Author: Amjad Khan · Oct 24, 2026 · Lab tenant only, fake users

## Goal

Replace security defaults with Conditional Access so every sign-in is checked, without locking anyone out. Baseline: MFA for everyone, stronger protection for admins, no legacy authentication, and no sign-ins from countries the organization doesn't operate in.

## Policies

| Policy | Users included | Excluded | Target resources | Conditions | Grant | State | Why |
|---|---|---|---|---|---|---|---|
| CA001-Require-MFA-AllUsers | All users | Break Glass 01 | All resources | None | Require MFA | On | Replaces the MFA that security defaults provided. Turned on in the same sitting security defaults were disabled, so the tenant was never left without MFA |
| CA002-Block-Legacy-Auth | All users | Break Glass 01 | All resources | Client apps: Exchange ActiveSync, Other clients | Block | On | Legacy protocols can't do MFA, so attackers use them for password spraying. Report-only first to find anything still using them |
| CA003-Require-MFA-Admins | 7 directory roles: Global Admin, Privileged Role Admin, Security Admin, User Admin, Helpdesk Admin, Conditional Access Admin, Application Admin | Break Glass 01 | All resources | None | Require MFA | On | Admins stay protected even if CA001 changes. Targets roles, not people, so new admins are covered automatically. Will be upgraded to a phishing-resistant authentication strength in Step 4 |
| CA004-Block-Selected-Countries | All users | Break Glass 01 | All resources | Locations: Blocked-Countries named location (countries chosen as high-risk, by IP) | Block | On | Cuts down noise from regions the organization never works from. It's a speed bump, not a wall, because a VPN in an allowed country gets around it |
| CA005-Require-PhishResistant-Admins | Same 7 directory roles as CA003 | Break Glass 01 | All resources | None | Require authentication strength: Phishing-resistant MFA (built-in) | Report-only | Push and codes can be relayed by a fake login page; passkeys can't. Added as a new policy because a grant can't combine "Require MFA" with an authentication strength, and keeping CA003 lets the two be compared side by side |
| CA006-PIM-Activation-PhishResistant | All users | Break Glass 01 | Authentication context c1 (PIM Role Activation), not apps | None | Require authentication strength: Phishing-resistant MFA; session: sign-in frequency every time | On | PIM-eligible admins aren't admins at sign-in, so CA003 and CA005 can't see them, and PIM's Azure MFA option accepts push. Linked to User Admin, Helpdesk and Global Admin activation. Safe to target All users because it only fires when c1 is requested. Every time allows five minutes of clock skew, so a passkey sign-in just before activating isn't prompted twice |

## Design decisions

- **Break-glass excluded from every policy, by name.** Excluding the user directly, instead of through a group, means nobody can quietly change its exclusion by editing group membership.
- **Exclude wins over include.** Break-glass is a Global Administrator and matches CA003's include, but the exclusion overrides it.
- **Block wins over grant.** If CA001 (MFA) and CA004 (block) both apply, the sign-in is blocked. The most restrictive result is enforced.
- **Report-only before On.** Each new policy runs in report-only so its impact shows up in the sign-in logs before it can block anyone.
- **Numbered names.** CA001, CA002 and so on keep policies sorted and easy to reference.

## What If testing

| Scenario | Inputs | Policies that applied | Result at the time |
|---|---|---|---|
| Finance user in a blocked country | Priya Shah, Exchange Online, North Korea IP | CA001 (On), CA004 (Report-only) | MFA, then allowed; CA004 logs that it would block |
| Admin at home | Ethan Brooks (Helpdesk Admin through a role-assignable group), Exchange Online, US IP | CA001 (On), CA003 (Report-only) | MFA, then allowed; CA003 matched the role inherited through the group |
| Daily admin | admin@, Exchange Online | CA001, CA003, CA005 | MFA; admin@ already has two passkeys |
| Helpdesk admin | Ethan Brooks, Exchange Online | CA001, CA003, CA005 | CA005 caught him through the group-inherited role |
| Break-glass | Break Glass 01, Exchange Online | None | Excluded everywhere, as designed |
| Original personal account | Personal Microsoft account, Exchange Online | CA001, CA003, CA005 | Showed it still held Global Admin. Role removed; a fresh sign-in then showed CA003 and CA005 "Not applied" |

**CA006 test:** Ethan signed in with push, activated Helpdesk Administrator, and was sent to a sign-in screen for his passkey. CA006 showed Success with the SignInFrequency session control and a Phishing-resistant requirement.

**CA005 report-only results for Ethan:** a sign-in with weaker MFA showed "User action required"; after he registered a passkey with a TAP, his next sign-in showed "Success".

A real sign-in also confirmed CA001: Daniel Kim registered a passkey when prompted, and his sign-in log showed CA001, grant control MFA, result Success.

## Rollout plan

1. Break-glass account created, MFA registered, excluded from every policy.
2. Admins registered MFA before the switch.
3. Security defaults disabled and CA001 turned on in the same sitting.
4. CA002, CA003 and CA004 in report-only. Review the Report-only tab in sign-in logs for anyone they would affect.
5. Turn each one On once the logs show no unexpected impact. Done Oct 29 for CA002, CA003 and CA004 after 5 days in report-only. CA003 is On as a backup in case CA001 is ever loosened; it's redundant with CA001 today and will be retired when CA005 is On. The portal's offer to exclude the current admin was declined.
6. Step 4 (done): CA005 added in report-only with the Phishing-resistant MFA strength. Passkeys allowed for PILOT-Passkeys and ROLE-Helpdesk-Admins; admin@ and Ethan registered passkeys.
7. Before CA005 goes On: no Failure results in report-only, Passkey (FIDO2) widened to All users, admin self-service password reset turned off. Then retire CA003, since CA005 is stricter for the same roles.

## Known gaps

- Only one break-glass account (production should have two).
- No alert yet on break-glass sign-ins.
- No device compliance policy yet (needs Intune enrollment).
- Location blocking depends on IP geolocation and can be bypassed with a VPN.
- Passkeys are only allowed for two groups, so an admin given a role directly couldn't register one and would be locked out by CA005.
- Admins can still register a phone for self-service password reset, even with SMS off in the methods policy.
- CA003 and CA005 only see admin roles that are active at sign-in. PIM-eligible admins are covered at activation by CA006 instead.
- Passkey attestation is off, so a "device-bound only" rule for admins can't be enforced yet.
