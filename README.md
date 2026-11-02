# Entra ID IAM Lab Scripts

I work in IT support and handle joiner/mover/leaver requests in Adaxes at my job. I built this lab to practice the parts of IAM I don't get to do much at work, mainly access reviews, finding access problems, and automating the user lifecycle.

Everything here runs against my own test tenant with fake users. Nothing touches a real company environment.

I used AI to help write the scripts. My part was designing how they should work, testing them, fixing what broke, and going through the code line by line so I can explain and change it. Some of the changes and bug fixes below are my own.

## The lab setup

- 12 test users across Finance, Sales, and IT (10 to start, plus Kevin and José who were created by the JML script), one service account (svc-backup), and my admin account
- 5 assigned security groups for access: Finance-Share, Sales-Share, IT-Admins, AP-Vendor-Create, AP-Payment-Approve
- DYN-Finance-Users: a dynamic security group with the rule (user.department -eq "Finance") -and (user.accountEnabled -eq true)
- ROLE-Helpdesk-Admins: a role-assignable security group holding the Helpdesk Administrator role, with Ethan Brooks as its member
- Finance Team: a Microsoft 365 group (shared mailbox, calendar and SharePoint site) owned by Daniel Kim
- Microsoft 365 E5 trial (includes Entra ID P2) with recurring billing off, licenses assigned to my admin and 10 active test users
- Managers and group owners set so there's someone to approve access (Daniel Kim for Finance, Marcus Reed for Sales)
- A few problems set up on purpose so the scripts have something to find
- Three apps in Entra for the permissions and SSO labs: Lab-App-01 (an app I registered), Microsoft Entra SAML Toolkit (a gallery app set up for SAML SSO), and Microsoft Graph Command Line Tools (what my PowerShell scripts sign in through)
- Two admin accounts: a native cloud-only admin (admin@<tenant>.onmicrosoft.com) with passkeys that I use for all lab work, and a break-glass account. My original account (the personal Microsoft account that created the tenant) no longer has any Entra role
- Conditional Access policies CA001 to CA006 and passkeys rolled out to a pilot group (see Conditional Access and authentication below)
- PIM for User Administrator, Helpdesk Administrator and Global Administrator; Ethan Brooks has no standing admin roles (see Privileged Identity Management below)
- An Azure subscription with a $5 monthly budget alert, a resource group (rg-iam-lab), and a user-assigned managed identity (mi-jml-automation) that has no permissions yet

## Admin accounts

| Account | Purpose | Type | Roles | MFA | Notes |
|---|---|---|---|---|---|
| admin@<tenant>.onmicrosoft.com | Daily lab administration | Internal, cloud-only Member | Global Administrator; Azure Owner on the subscription with a condition (can't assign Owner, User Access Administrator or RBAC Administrator) | Microsoft Authenticator push, device-bound passkey in Authenticator, synced passkey in my password manager | Department IT, usage location US, E5 license, in PILOT-Passkeys |
| bg-emergency01@<tenant>.onmicrosoft.com | Break-glass, emergency use only | Internal, cloud-only Member | Global Administrator, permanently active (not PIM eligible) | Microsoft Authenticator | 32-character random password in my password manager, no license, signed in once to register MFA and verify |
| Original account (personal Microsoft account) | Azure subscription owner | External identity, Member | No Entra roles (Global Administrator removed in Step 4); Azure subscription Owner | Its own Microsoft account sign-in, outside my tenant's control | Not used for lab work. The E5 trial was bought with admin@, and personal accounts can't sign in to the Microsoft 365 admin center anyway |

Global Administrator is now exactly 2 native accounts: admin@ and the break-glass account.

Break-glass rules I'm following: cloud-only on the onmicrosoft.com domain, permanent Global Administrator, long random password stored offline, not tied to daily use, no license, and excluded by name from every Conditional Access policy. Gaps compared to production: there's only one break-glass account (production should have two), its MFA is on the same phone as my admin account (production should use a FIDO2 key kept in a safe), and sign-in alerts aren't set up yet.

## Conditional Access and authentication

Full design, What If results and rollout plan: `CA_Policy_Design.md`.

| Policy | Who | Requires | State |
|---|---|---|---|
| CA001-Require-MFA-AllUsers | All users | MFA | On |
| CA002-Block-Legacy-Auth | All users | Block legacy protocols | On (Oct 29) |
| CA003-Require-MFA-Admins | 7 admin roles | MFA | On (Oct 29); backup if CA001 ever changes, retire once CA005 is On |
| CA004-Block-Selected-Countries | All users | Block named high-risk countries | On (Oct 29) |
| CA005-Require-PhishResistant-Admins | 7 admin roles | Phishing-resistant MFA authentication strength | Report-only |
| CA006-PIM-Activation-PhishResistant | All users, only when authentication context c1 (PIM Role Activation) is requested | Phishing-resistant MFA, sign-in frequency every time | On |

Break-glass is excluded by name from all six. When turning policies On, the portal offered to exclude my own admin account; I declined, since break-glass is the safety net and an excluded daily admin would be the weakest point. Security defaults were turned off in the same sitting CA001 was turned on.

**Authentication methods (Step 4):**

- **Passkeys (FIDO2):** were enabled for All users by default. Narrowed to PILOT-Passkeys (admin@, Daniel Kim, Priya Shah) and ROLE-Helpdesk-Admins, using the Default passkey profile (device-bound and synced allowed, attestation off). Production order would be the other way: pilot first, then All users.
- **Microsoft Authenticator:** stays on for All users, since CA001 depends on it. Changed "Show application name" and "Show geographic location" from Microsoft managed to Enabled so the setting is documented and can't drift. Number matching is enforced by Microsoft.
- **SMS and Voice call:** already off tenant-wide, stricter than the step required.
- **Passwordless onboarding:** issued Priya a 1-hour Temporary Access Pass, she registered a device-bound passkey in Authenticator, then the TAP was deleted. Did the same for Ethan Brooks (Helpdesk Admin).
- **CA005 proof:** Ethan's sign-in with weaker MFA showed "Report-only: User action required"; his sign-in with the passkey showed "Report-only: Success". So the admin can meet the rule before it's enforced.

**Before CA005 is switched On:** a few days of report-only data with no Failure results, Passkey (FIDO2) widened to All users so a future admin outside these groups can register one, and admin self-service password reset turned off (see below).

**Why SMS is weak and passkeys aren't (NIST SP 800-63B):** SMS codes travel over the carrier network, so they can be stolen with a SIM swap or tricked out of the user by a fake login page. NIST SP 800-63B classifies SMS as a restricted authenticator: if an organization keeps it, it must offer an alternative and accept the risk. A passkey is a key pair: the private key stays on the user's device, and the website keeps the public key to verify its signatures. The passkey is tied to the real website's domain and the browser checks it, so a fake login page can't use it even if the user is fooled. In my lab, I issued Temporary Access Passes so users could register passkeys, confirmed SMS was disabled, and required phishing-resistant MFA for admins in a report-only Conditional Access policy.

## Privileged Identity Management (Step 5)

**Role settings:**

| Role | Max activation | On activation | Approval | Eligible assignments | Active assignments |
|---|---|---|---|---|---|
| User Administrator | 2 hours | Authentication context (CA006), justification | No | Max 1 year, no permanent | Max 15 days, MFA + justification, no permanent |
| Helpdesk Administrator | 2 hours | Authentication context (CA006), justification | No | Max 1 year, no permanent | Max 15 days, MFA + justification, no permanent |
| Global Administrator | 1 hour | Authentication context (CA006), justification | Yes, admin@ approves | Microsoft defaults | Permanent still allowed, because break-glass needs permanent Global Admin |

Activation alerts for all three go to an inbox I read, in addition to the default admin recipients.

**What I tested:**

- **Eligible isn't the same as having the role:** Ethan was made eligible for User Administrator. Before activating, creating a user failed with "Insufficient privileges". After activating for 1 hour, it worked. After the hour, it failed again with nobody removing anything.
- **Approval for Global Admin:** Ethan requested Global Admin with the reason "daily tasks". I denied it as admin@ ("not an appropriate justification"). He resubmitted with a specific change, I confirmed with him over Teams and approved with an incident number. The audit log shows the request, approval and activation with the same Correlation ID, and the activation expired an hour after approval. Ethan's Global Admin eligibility was removed afterwards.
- **Helpdesk from permanent to eligible:** ROLE-Helpdesk-Admins had Helpdesk Administrator as a permanent active assignment. I added an eligible assignment for the group first, then removed the permanent one, so Ethan was never without a working path. Resetting Priya's password failed before activation and worked after.
- **Step-up at activation (CA006):** CA003 and CA005 target admin roles at sign-in, but a PIM-eligible admin isn't an admin when they sign in, and PIM's "Azure MFA" option accepts any MFA, including push. I created an authentication context (c1, PIM Role Activation), a CA policy requiring phishing-resistant MFA every time for that context, and linked it to all three roles. Ethan signed in with push, clicked Activate, and was sent to a sign-in screen for his passkey (QR code to the phone). When he had signed in with a passkey a minute earlier, he wasn't prompted again, because "every time" allows five minutes of clock skew.

Result: no account has standing Helpdesk, User Administrator or Global Admin except admin@ and break-glass, and becoming an admin takes a fresh passkey, a reason, and for Global Admin a second person.

## Scripts

### 1. Export-UserGroupMembership.ps1

Pulls every user with their department, job title, manager, whether the account is enabled, and what groups they're in. Saves it to a CSV, one row per user per group. This is basically the list you'd hand a manager during an access review. I also use it to verify changes after the JML script runs.

I added the JobTitle column to the on-screen table myself.

### 2. Find-AccessRisks.ps1

Checks every user against a set of rules and only lists the ones that break them:

- Disabled accounts that still have group access
- Service accounts with no owner (checked through the Manager field, since Entra user objects don't have owners)
- Service accounts in an admin group
- Access that doesn't match the user's department (usually someone who moved roles)
- Segregation of duties conflicts (same person in AP-Vendor-Create and AP-Payment-Approve)
- Users with no department set (I wrote this rule myself, see below)

The rules are at the top of the script so they can be changed without touching the logic.

### 3. Invoke-JML.ps1

Reads a CSV that stands in for an HR feed and handles joiners, movers, and leavers:

- **Join:** create the account, set department, title, and manager, add the groups that department gets by default
- **Move:** take a snapshot of the user's current groups, update department, title, and manager, add the new department's groups, then remove the old department's groups
- **Leave:** disable the account, revoke sign-in sessions, remove all groups

Each department gets certain groups automatically (birthright access). Sensitive groups like IT-Admins and the AP groups are never given out automatically, they'd need a separate approved request. When someone moves, the script removes old department groups on its own but only flags requested access for the group owner to review, since the person might still need it in the new role. Leavers lose everything since there's no role left.

It runs in preview mode by default and only shows what it would do. It only makes changes if you add `-Apply`. Every step gets written to jml-log.csv with a timestamp and whether it was a preview or a real change.

**Handling the HR feed:** After a real run, rows that finished get moved to hr-feed-processed.csv with the date. Rows that failed or had bad data (user not found, department not in the rules, unknown action) stay in hr-feed.csv so a person can fix them and run it again. Preview mode never touches the files. I started out doing this by hand and had the script do it once I saw how easy it was to forget.

**First test feed:**

```
Action,DisplayName,Department,JobTitle,Manager
Join,Kevin Patel,Finance,Staff Accountant,Daniel Kim
Move,Priya Shah,Finance,Financial Analyst,Daniel Kim
Leave,Tyler Nguyen,,,
```

**What happened:**

1. Ran the preview first and checked every line matched what I expected
2. Ran it with `-Apply`
3. Ran the export script to confirm the changes actually happened

- **Kevin** was created in Finance with Daniel as his manager and added to Finance-Share
- **Priya** moved from Sales to Finance, got Daniel as her manager, was added to Finance-Share and **removed from Sales-Share automatically**
- **Tyler** was disabled, signed out of everything, and removed from all groups

Priya's move is the one I care about most. At my job, when someone changes roles we add the new groups but nobody removes the old ones. The script fixes that by design.

**Second test:** Added José Díaz as a new hire to test my fix for accented names (see below). He came out as jose.diaz, got Marcus as his manager and Sales-Share, and his row moved to the processed file on its own.

**Tyler vs James:** Both are disabled, but James was disabled by hand earlier and is still in Finance-Share, never had his sessions revoked, and has no record of what was done. Tyler went through the script and has no groups left, plus every step is in the log. Find-AccessRisks.ps1 still flags James but not Tyler. That's the whole argument for automating offboarding, steps get missed when it's done by hand.

## What the scripts found

I set up these problems on purpose:

- **Sofia** moved from Finance to Sales but was still in Finance-Share, and her manager was still Daniel (Finance). Classic access creep.
- **James** is disabled but still in Finance-Share. If someone re-enabled him, all his old access would come back.
- **Aisha** is in both AP groups, so she could create a vendor and approve payments to it.
- **svc-backup** was created as a regular user with no owner (no manager set) and was in IT-Admins.

Find-AccessRisks.ps1 caught all of them (5 findings).

**What I've fixed so far:** I gave svc-backup an owner by setting Ethan (IT) as its manager and took it out of IT-Admins. That dropped it to 3 findings. I'm leaving Sofia, James, and Aisha for now so I can clean them up through an actual Entra access review with Daniel as the reviewer, then rerun the script to confirm it's at 0.

## Things I ran into

- My first export gave 16 rows when I expected 17. I'd forgotten to add Aisha to Finance-Share. Now I check the count against what I expect instead of assuming the setup is right.
- I typo'd a group as "Finance-SHare". Entra wouldn't rename it straight to "Finance-Share" because it ignores case and thought the name was taken. Had to rename it to something else first, then back.
- The first version of the export script broke on PowerShell 7 because it used `.Clone()` on an ordered hashtable, which doesn't exist there. Switched to building each row directly.
- I added the "missing department" rule after noticing the department check skips anyone with a blank department. It caught my own admin account. I fixed it by setting the department only. I'd also added myself to IT-Admins while I was in there, then took it back out because nothing needed it.
- First time adding the rule, I put it after the loop's closing brace, so it would have only checked the last user. Moved it inside the loop.
- I kept typing script changes into the PowerShell window instead of the file. Console is for testing one command, changes go in the .ps1 file.
- Copying a script out of the chat window pulled extra text into the top of the file and broke it. Downloading the file instead fixed it.
- **Accented names:** Reading through the JML script I noticed accented names lose letters in the sign-in name. José Díaz would have become jos.daz because é and í got stripped out. Fixed it by converting accents to plain letters first (é to e) before removing anything else. Tested it in the console, then in preview, then for real. Now José Díaz becomes jose.diaz.
- The CSV had to be saved as UTF-8 or the accents came through garbled.
- Rerunning the feed with rows that were already done made the script repeat steps, like changing Priya's department from Finance to Finance and disabling Tyler again. Nothing broke but it cluttered the log. That's why finished rows now get moved out of the feed.
- Notepad couldn't save the CSV because Excel had it open and locked. Close Excel before editing or running the scripts.
- When I made hr-feed-processed.csv by hand, the last line didn't end with a line break (and had a stray character). The script's append stuck José's row onto the end of Tyler's line. Fixed the file and made sure it ends with a blank line. Files edited by both people and scripts need to be clean.
- **SAML Toolkit app errors:** I set up SAML SSO for the Microsoft Entra SAML Toolkit test app. Signing in sent me to Microsoft and back, but the app showed an error. I decoded the SAML response it printed: Status was Success, Destination matched my Reply URL, Audience matched my Identifier, and the claims matched what I'd configured. So Entra did its part and the problem was inside the app. A second try as Daniel Kim gave "Object reference not set to an instance of an object," which is a code crash in the app, not a trust or certificate failure. Opening the /SAML/Consume address directly gave a 404 because that address only accepts tokens posted by Entra.
- **My admin account is an external identity:** The first decoded token showed my admin's sign-in name with #EXT# and an identity provider of live.com. My tenant was created with my personal Microsoft account, so that account signs in through Microsoft's consumer system instead of my tenant, even though its User type is Member. Daniel's token showed a normal internal account.
- **Defender portal sent me to the wrong tenant:** Signing in to security.microsoft.com with that original admin gave "Selected user account does not exist in tenant 'Microsoft Services'." Adding ?tid=<my tenant ID> to the URL worked around it. The real fix was creating a native cloud-only admin account; with that account the portal finds my tenant on its own.
- **Licenses failed for 10 users:** Assigning E5 failed with "License assignment cannot be done for user with invalid usage location." Only my new admin had a usage location set. That's a gap in Invoke-JML.ps1: Join needs to set UsageLocation or new hires can't be licensed.
- **Wrong PowerShell:** Connect-MgGraph wasn't recognized because I'd opened Windows PowerShell 5.1 instead of PowerShell 7. They keep modules in different folders. $PSVersionTable shows which one is open.
- **Graph module version mismatch:** Get-MgSubscribedSku was "found but could not be loaded" after I installed Microsoft.Graph.Identity.DirectoryManagement, because it was newer than the Graph modules already loaded. I worked around it with Invoke-MgGraphRequest against v1.0/subscribedSkus, then assigned licenses with Set-MgUserLicense. The proper fix is updating all Graph modules to the same version and opening a fresh session.
- **Didn't license disabled accounts:** James and Tyler are disabled, so I left them off. Licensed disabled accounts are paying for people who have left, which is a common audit finding.
- **Dynamic group included a disabled user:** The first rule, department equals Finance, pulled in James because he's disabled but still has Department = Finance. I added accountEnabled -eq true to the rule and he dropped out.
- **A personal account still had Global Admin:** What If showed CA003 and CA005 applying to my original account, the personal Microsoft account that created the tenant. Its sign-in log showed "Redirected to external provider" with no method recorded, so my tenant couldn't see or enforce how it did MFA. I checked Global Admin already had admin@ and break-glass, removed the role, and kept the audit log entry ("Remove member from role"). It's still Owner on the Azure subscription, because Azure RBAC is separate from Entra roles. A fresh sign-in afterwards showed CA003 and CA005 as "Not applied".
- **"Previously satisfied" fooled me:** One sign-in showed CA005 "Success" for that account even though it uses push MFA. Authentication details said "Previously satisfied" for both factors, so no new MFA happened in that sign-in. Each sign-in also creates several log rows; only the first shows the real MFA. Now I check Authentication details and retest with a fresh session before drawing conclusions.
- **CA005 covered an admin who couldn't register a passkey:** Ethan gets Helpdesk Admin through ROLE-Helpdesk-Admins, so CA005 targets him, but passkeys were only allowed for PILOT-Passkeys. If CA005 had been On, he'd have been locked out. I first added the group to CA005 by mistake, which changed nothing, then undid it and added ROLE-Helpdesk-Admins to the Passkey (FIDO2) targets instead.
- **Admins can still register a phone:** With SMS and Voice off, Priya (no role) was only offered passkeys and Authenticator. Ethan and admin@ were also offered Phone, Email and Hardware token, with Email labeled "reset your password". Admin roles get Microsoft's own self-service password reset policy, which doesn't follow the authentication methods policy, so a SIM-swapped admin phone could still reset an admin password.
- **Approval turned on by accident:** Helpdesk Administrator's settings showed "Require approval: Yes" with "Approvers: None". With no approvers picked, PIM falls back to Global and Privileged Role Admins. Turned it off; a role used many times a day shouldn't wait on approvals.
- **Expired assignments was empty after an activation ended:** That tab lists eligibilities that ended, not activations. Ethan's eligibility was still valid; only his 1-hour activation ended.
- **Two audit fields misled me at first:** On the denied request, "Requestor" was my admin account (the one that performed the denial) and "Status: Succeeded" meant the denial succeeded. The Action line says what actually happened.
- **No passkey prompt on one activation:** Ethan had just signed in with a passkey, so CA006 didn't prompt again. "Every time" allows five minutes of clock skew. Signing in with push first forces the prompt.
- **Admin view vs user view:** The admin "Add authentication method" panel on Priya's account still offers Phone number, but Priya's own Security info doesn't. Admins can store a phone number on a user; the methods policy decides whether the user can use it.

## Things I learned

- **`-Property` on Get-MgUser:** Graph only sends back a few fields by default, so you have to ask for the specific ones you need, like Department and AccountEnabled. Otherwise they come back blank.
- **try/catch:** Looking up a manager throws an error when someone doesn't have one. Without try/catch the script would stop at that user. In the JML script, try/catch logs a failure for one person and keeps going with the rest.
- **Filtering on `@odata.type`:** Get-MgUserMemberOf returns groups and admin roles mixed together. My admin account came back as `#microsoft.graph.directoryRole`, Aisha's came back as `#microsoft.graph.group`. The scripts filter to groups only.
- **Managers and group members are links, not text:** In Entra the manager field points to another user object, so the script looks up the manager's account to get their Id and links to that. Same with group membership.
- **UPN:** The user's sign-in name. Looks like an email and has to be unique in the tenant.
- **Double vs single quotes:** Double quotes fill in variables, single quotes keep the text exactly as typed. `"$nickname@$Domain"` gives kevin.patel@..., `'$nickname@$Domain'` gives literally $nickname@$Domain.
- **Saving vs showing a variable:** `$x = something` stores it quietly. Typing `$x` on its own shows it.
- **break vs continue:** break stops working on that person and moves to the next person in the CSV. continue skips the current group and moves to the next group for the same person.
- **Snapshot before changing:** The Move step saves the user's current groups before touching anything, so it knows what to remove and what they already have.
- **Disable vs revoke sessions:** Disabling blocks new sign-ins, but a device that's already signed in can keep working until its token expires, often up to about an hour. Revoking sessions closes that gap.
- **Preview first:** Every change in the JML script goes through one function that logs the step and only runs it if `-Apply` was used. So a mistake in preview mode doesn't change anything.
- **Checking before changing:** Join skips anyone who already exists so running it twice doesn't create duplicates. Move and Leave skip anyone who doesn't exist. Anyone whose department isn't in the rules gets skipped instead of created with no access.
- **Birthright vs requested access:** Everyone in a department gets some access automatically. Anything sensitive should go through a request and approval.
- **Least privilege:** Fix what the finding says and nothing more.
- **Delegated vs application permissions:** The scopes in `Connect-MgGraph -Scopes` are delegated permissions. The scripts act as me, so they can never do more than my own account is allowed to do. Application permissions would let an app act as itself with no user signed in, usually across the whole tenant, and only an admin can consent to them.
- **Where the consent lives:** PowerShell signs in through a Microsoft-built app called Microsoft Graph Command Line Tools. My tenant only has its enterprise application (service principal), not an app registration, since Microsoft owns the app. The scopes I've consented to show up under Enterprise applications, Microsoft Graph Command Line Tools, Permissions, all as Delegated.
- **Removing a permission isn't revoking it:** I added User.Read.All (Application) to a test app, granted admin consent, then removed it from the app registration. It still showed under "Other permissions granted" and the app still had the access. It was only gone after I revoked admin consent. The real granted access is on the enterprise application, so that's where to check what an app can actually do.
- **User consent settings:** My tenant was set to "Let Microsoft manage your consent settings." I changed it to allow user consent only for apps from verified publishers, for permissions classified as low impact, and classified openid, profile, email, offline_access, and User.Read as low impact. Application permissions can never go on that list since only an admin can approve them. Anything outside the list goes through an admin consent request, with me as the reviewer, so users have a way to ask instead of working around IT.
- **IdP vs SP:** Entra is the identity provider and checks who the user is. The app is the service provider and trusts what Entra tells it. The user's password never goes to the app.
- **The SAML trust exchange:** Both sides have to know each other first. Entra needs the app's Identifier and Reply URL. The app needs Entra's Login URL, Entra Identifier, and signing certificate. The token Entra sends is signed XML, and the app checks the signature with that certificate.
- **Reply URL is a security control:** Entra only sends tokens to reply URLs that are configured on the app, so a token can't be redirected to someone else's site. It's required, and Save stays greyed out without it.
- **Claims:** Attributes & Claims decides what Entra puts inside the token (name, email, UPN). The Unique User Identifier is how the app recognizes who signed in.
- **Signing certificate expiration:** The SAML signing certificate has an expiration date, and when it expires SSO breaks for everyone using that app. The notification email should go to a team mailbox, not one person.
- **Assignment:** Users and groups on the enterprise app decides who can sign in to it. On the Free license I can only assign individual users; assigning groups needs P1.
- **Troubleshooting SSO:** Check the identity side first. If Entra's sign-in logs show Success and the SAML response has the right status, audience, recipient, and claims, the problem is in the app, and the SAML response is the evidence to take to the vendor. Don't put raw SAML responses in a repo, since they include the tenant ID.
- **Gallery apps vs consent-based apps:** Adding an app from the gallery (like the SAML Toolkit) creates my own copy of it, so it shows up under both App registrations and Enterprise applications. A multi-tenant app that arrives through consent (like Microsoft Graph Command Line Tools) only gets an enterprise application in my tenant; its app registration stays in the vendor's tenant.
- **Managed identities:** An identity Azure gives a resource so it can call other services with no stored password or secret. My svc-backup account had a password someone would have to store and rotate; a managed identity doesn't. A new one starts with zero permissions until something is granted to it.
- **System-assigned vs user-assigned:** System-assigned belongs to one resource and is deleted with it. User-assigned is its own resource, can be shared, and survives the resources using it. I made mi-jml-automation user-assigned so its identity and permissions survive if an automation job gets rebuilt.
- **A managed identity is a service principal with no app registration:** mi-jml-automation shows up in Enterprise applications (filter Application type to Managed Identities) with its Object ID matching the Principal ID in Azure, and its Application ID matching the Client ID. It does not appear under App registrations, and its certificate expiry says "Managed by Microsoft."
- **Entra vs Azure:** Entra ID is the identity system (who). Azure is the cloud platform (what). They have separate role systems: Entra roles like Global Administrator control identity, and Azure RBAC roles like Owner or Reader control resources. I'm Global Admin in Entra and separately Owner of the Azure subscription.
- **User type vs where the identity comes from:** These are two separate properties. User type (Member or Guest) controls default directory access; guests are restricted. Where the identity comes from (internal or external) decides which system signs the user in. My original admin is external but a Member. A B2B invite like a vendor's company account is external and a Guest by default.
- **Native admin account:** I created admin@<tenant>.onmicrosoft.com as a cloud-only Member with Global Administrator, set Department to IT and Usage location to United States (so my missing-department rule doesn't flag it and licenses can be assigned), and registered MFA on first sign-in. Admin accounts should be internal, separate from everyday accounts, and protected with MFA.
- **Global Admin doesn't grant Azure access:** Signed in as the new Global Admin, Subscriptions was empty. Entra roles control identity; Azure resources need an Azure RBAC role.
- **Azure RBAC role assignments:** Every assignment is who (a security principal, targeted by its Entra Object ID), what (the role), and where (the scope). I gave the new admin Owner at subscription scope from my original account, which was the existing Owner.
- **Owner vs Contributor vs User Access Administrator vs Reader:** Reader can only view. Contributor can manage resources but can't grant access. User Access Administrator can only manage access. Owner can do both. I used Owner because I'll need to assign roles to my managed identity later; in a company most admins would get Contributor.
- **Role assignment conditions:** I picked "assign all roles except Owner, User Access Administrator and RBAC Administrator," so the new admin can hand out normal roles but can't create more Owners. That blocks a compromised account from creating a backdoor Owner.
- **Elevate access is for break-glass only:** A Global Admin can turn on "Access management for Azure resources" to get User Access Administrator over all of Azure. That's far broader than needed, so it's only for when no Owner exists, and it should be turned off right after.
- **Three role systems:** Entra roles control identity, Azure RBAC controls Azure resources, and billing roles control purchases and payment methods. My new admin is Global Admin and subscription Owner but has no billing role, so the billing account (owned by my original account) shows a warning.
- **Trials and recurring billing:** The E5 trial needed a payment method. I confirmed recurring billing is Off so it expires instead of converting to paid, and set a reminder before the end date to export lab evidence.
- **Usage location:** Microsoft needs a user's country before it can license them, because some services aren't available everywhere.
- **Group-based licensing:** Adding a group in the license screen licenses everyone in it. I didn't use my access groups for that, because removing someone from an access group would silently remove their license too. A dedicated licensing group is cleaner.
- **Security vs Microsoft 365 groups:** Security groups control access. Microsoft 365 groups are for collaboration and come with a shared mailbox, calendar and SharePoint site. Turning on E5 also created a few Microsoft 365 groups automatically (All Company, Viva Engage), which is how group sprawl starts.
- **Dynamic groups:** Membership comes from a rule on user attributes. Priya moved into Finance and joined on her own; Sofia moved to Sales and wasn't included, unlike Finance-Share where she's still a member. Rules only check what you tell them to check, so leaving out accountEnabled kept a disabled user in.
- **Role-assignable groups:** The setting that lets a group hold Entra roles can only be turned on when the group is created, the group can't be dynamic, and only Global Admins or Privileged Role Admins can change its membership. Otherwise anyone who could edit the group could make someone an admin.
- **Assigned roles vs Roles and administrators on a group:** Assigned roles shows what the group's members get (Helpdesk Administrator). Roles and administrators shows who has admin rights over the group itself, which is empty unless someone is assigned to manage that specific group.
- **Helpdesk Administrator is privileged:** It can reset passwords for non-admin users, and resetting a password means being able to take over the account, so Entra labels it Privileged. It belongs in PIM as an eligible role rather than permanently active.
- **Authentication methods policy vs Conditional Access:** The methods policy decides who is allowed to set up each method. Conditional Access decides who must use which method and when. Before requiring a method, everyone in the policy's scope has to be allowed to register it, and has to have actually registered it.
- **Passwordless vs phishing-resistant:** The built-in Passwordless MFA strength includes Authenticator phone sign-in; Phishing-resistant MFA doesn't. Phone sign-in removes the password, but the phone doesn't know which website started the sign-in, so a fake page in the middle can relay it. A passkey only signs for the real domain.
- **Downgrade attacks:** A passkey doesn't help if weaker methods are still accepted, because a fake page just asks for password and push instead. That's why the authentication strength in CA005 is the other half of the rollout.
- **Authentication strengths:** Built-in strengths can't be edited, and a CA grant can't use "Require MFA" and "Require authentication strength" together, which is why CA005 is a new policy instead of an edit to CA003.
- **Device-bound vs synced passkeys:** Device-bound keys never leave the device. Synced passkeys copy between devices through a provider like a password manager, so whoever gets into that account gets the key.
- **Attestation:** Proof from the key's manufacturer of what the key is. Without it, Entra trusts the passkey's own claim about its type, so a "device-bound only" rule can't really be enforced. Entra warns about this on the passkey profile.
- **Passkey profiles:** New in Entra. Up to 10 sets of passkey rules, each assigned to groups, so admins could be limited to device-bound keys with attestation while regular users can use synced passkeys.
- **Temporary Access Pass:** A short-lived pass an admin issues so a user can sign in and register a passkey without a password. It satisfies MFA for that sign-in and should be deleted once it's served its purpose.
- **Report-only results:** Success means the sign-in already met the rule, User action required means the user would have been prompted for more, and Failure means they would have been blocked. Failure is the one to watch before turning a policy On.
- **Personal accounts sign in at home:** A personal Microsoft account added to the tenant is redirected to Microsoft's consumer sign-in, so the tenant's methods policy, passkey rules and SMS settings don't apply to how it authenticates. Admin roles belong on native tenant accounts.
- **Eligible vs active:** Eligible means the user can turn the role on when needed (activate, MFA, reason, for a set number of hours). Active means the role is already on. An activated eligible role shows as "Activated"; a role given directly shows as "Assigned".
- **Two clocks:** Activation maximum duration (2 hours) is how long each activation lasts. "Expire active assignments after" (15 days) is the longest anyone can be given the role directly. Unchecking "Allow permanent" for both stops temporary access from becoming permanent by accident.
- **Role settings are enforced by the portal:** After I turned off permanent eligible assignments, the Add assignments screen didn't offer "Permanent" at all and set the end date to exactly one year.
- **Break-glass needs permanent Global Admin:** That's why Global Admin keeps "Allow permanent active assignment" on, even though User Admin and Helpdesk don't.
- **Approval is only a control if the approver questions the request:** A reason like "daily tasks" should be denied. A good approval verifies with the requester through another channel and links a ticket.
- **Notifications need someone reading them:** By default activation alerts go to Global and Privileged Role Admins. In this tenant that's admin@ and a break-glass account with no mailbox, so I added an address I check. In production it should be a shared security mailbox.
- **Authentication context:** A label (c1) that an app or PIM can ask Conditional Access to check. A CA policy that targets only an authentication context does nothing until something requests it, so targeting All users is safe.
- **Step-up at activation:** CA checks roles at sign-in, but PIM admins become admins after sign-in. Requiring an authentication context on activation makes the CA check happen at the moment someone becomes an admin.
- **AWS comparison:** A managed identity is Azure's version of an IAM role on an EC2 instance. Both get short-lived credentials from a local metadata endpoint instead of stored access keys. An app registration secret is closer to IAM user access keys, the thing to avoid.

## Running the scripts

Requires PowerShell 7 and the Microsoft Graph modules:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions -Scope CurrentUser
```

The scripts use **delegated** permissions through interactive sign-in. They run as the signed-in admin and are limited to what that account can do.

The first two scripts only read data:

```powershell
Connect-MgGraph -TenantId <yourtenant>.onmicrosoft.com -Scopes "User.Read.All","GroupMember.Read.All"
.\Export-UserGroupMembership.ps1
.\Find-AccessRisks.ps1
```

The JML script makes changes, so it needs write permissions:

```powershell
Connect-MgGraph -TenantId <yourtenant>.onmicrosoft.com -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All","User.RevokeSessions.All"
.\Invoke-JML.ps1 -Domain <yourtenant>.onmicrosoft.com          # preview only
.\Invoke-JML.ps1 -Domain <yourtenant>.onmicrosoft.com -Apply   # makes the changes
```

Save hr-feed.csv as UTF-8 and close Excel before running.

Sign-in is interactive. No passwords or secrets are stored in any of the scripts, and the JML script never shows or logs the passwords it generates for new accounts.

## Screenshots

Tenant ID, tenant domain, personal email, TAP codes and temporary passwords are hidden in every screenshot.

**Scripts**
- Full export: `screenshots/Export-Output.png`
- 5 findings before any fixes: `screenshots/findings-before.png`
- 3 findings after fixing the service account: `screenshots/findings-after-svc-fix.png`
- My missing department rule catching the admin account: `screenshots/findings-rule6-missing-department.png`
- JML preview: `screenshots/jml-preview.png`
- JML applied: `screenshots/jml-applied.png`
- Export confirming the JML changes: `screenshots/jml-verified.png`

**Conditional Access (Step 3)**
- What If: Finance user signing in from a blocked country: `screenshots/whatif-finance-blocked-country.png`
- What If: Helpdesk admin at home, CA003 matching the role inherited through the group: `screenshots/whatif-admin-home.png`

**Passkeys and authentication methods (Step 4)**
- PILOT-Passkeys group members: `screenshots/pilot-passkeys-group.png`
- Pilot user's sign-in method choices after a Temporary Access Pass sign-in (no phone option): `screenshots/pilot-user-add-method.png`
- Admin can store a phone, user can't use it: `screenshots/sms-admin-vs-user.png`
- CA005 for Ethan, User action required vs Success: `screenshots/ca005-before-after-ethan.png`

**PIM (Step 5)**
- User Administrator eligible: user creation failed, then succeeded after activation: `screenshots/pim-user-admin-before-after.png`
- Ethan's My roles showing Activated (User Admin) vs Assigned/Permanent (Helpdesk, before it was moved to eligible): `screenshots/pim-activated-vs-assigned.png`
- Global Admin request denied for "daily tasks": `screenshots/pim-ga-request-denied.png`
- Global Admin request approved and activated: `screenshots/pim-ga-request-approved.png`
- Helpdesk eligible: password reset refused, then allowed after activation: `screenshots/pim-helpdesk-eligible.png`

**Not captured yet:** screenshots for the app permissions, consent, SAML, managed identity, Azure RBAC, licensing, group and CA006 labs. I'll recapture the ones that still exist before the E5 trial ends on Nov 23.

## Next

- [x] Review Invoke-JML.ps1 line by line, run the preview, then run it for real
- [x] Fix the accented name bug
- [x] Move finished HR feed rows to a processed file automatically
- [ ] Skip steps that are already done (like disabling an account that's already disabled) so reruns don't repeat work
- [x] Start the Entra ID P2 trial and run an access review on Finance-Share and the AP groups (Nov 1: reviewers are each user's manager, admin@ as fallback so nobody reviews themselves; waiting on the denied access to be removed)
- [ ] Rerun Find-AccessRisks.ps1 after the review and get to 0 findings
- [x] Set up PIM so admin roles are only active when needed (User Admin, Helpdesk, Global Admin with approval)
- [x] Add Conditional Access and MFA policies (CA001 On, CA002 to CA005 report-only)
- [x] Scope passkeys to a pilot group, onboard users with TAP, require phishing-resistant MFA for admins (report-only)
- [x] Remove Global Administrator from the personal Microsoft account
- [x] Switch CA002 to CA004 On after 5 days in report-only (Oct 29)
- [ ] Switch CA005 On, then retire CA003
- [ ] Widen Passkey (FIDO2) to All users before CA005 is On
- [ ] Turn off self-service password reset for admins (Graph authorization policy allowedToUseSSPR) and test on Ethan
- [ ] Passkey profile for admins: device-bound only with attestation enforced
- [ ] Clean up stored phone numbers on accounts so they can't come back if SMS is re-enabled
- [ ] Download the JSON for CA001 to CA006 into the repo
- [ ] Recapture the missing screenshots (permissions, SAML, managed identity, RBAC, licensing, groups, CA006) before Nov 23
- [ ] Use an approver group instead of one person for Global Admin
- [ ] Require ticket information on Global Admin activation
- [ ] Bring the other admin roles in CA003/CA005 under PIM with the same settings
- [ ] Review PIM alerts (roles assigned outside PIM, too many Global Admins)
- [ ] Scripts for stale sign-ins (90+ days) and users without MFA (need P1/P2 data)
- [ ] Run Invoke-JML.ps1 unattended the way it would run in production: an Azure Automation runbook using mi-jml-automation with only the Graph application permissions it needs, so there's no secret or certificate to manage
- [x] Create a native cloud-only admin account with MFA and give it Owner on the subscription with a condition
- [x] Start the Microsoft 365 E5 trial (includes Entra ID P2, Defender for Cloud Apps, Defender XDR and Intune) as the new admin, recurring billing off
- [x] Assign licenses to active test users
- [x] Create a dynamic group, a role-assignable group and a Microsoft 365 group
- [ ] Fix Invoke-JML.ps1 so Join sets UsageLocation
- [ ] Update all Microsoft Graph PowerShell modules to the same version
- [ ] Create a dedicated licensing group and move to group-based licensing
- [ ] Scope Helpdesk Administrator to an administrative unit instead of the whole directory
- [x] Make Helpdesk Administrator eligible in PIM instead of permanently active
- [x] Create a break-glass emergency admin account (bg-emergency01), sign in once and register MFA
- [x] Exclude bg-emergency01 from every Conditional Access policy (Step 3)
- [ ] Alert on any sign-in by bg-emergency01 (needs sign-in logs sent to Log Analytics)
- [ ] Add a second break-glass account and move break-glass MFA to a FIDO2 key
- [ ] Script to list every enterprise app's SAML signing certificate and its expiration date, and flag anything expiring within 60 days (expired SAML certs break SSO for everyone using that app)
