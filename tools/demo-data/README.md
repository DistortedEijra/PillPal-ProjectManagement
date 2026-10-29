# PillPal demo reset

Deletes **every account and all data** in the Firebase project, then creates two linked demo accounts with sample data.

| Account | Email | Password |
|---|---|---|
| Patient (Rosa Santos, 72) | `patient@pillpal.test` | `PillPal123` |
| Caregiver (Ana Santos, daughter) | `caregiver@pillpal.test` | `PillPal123` |

Sample data on the patient:
- **Medicines:** Losartan 8 AM (slot A), Metformin 8 AM + 8 PM (B), Atorvastatin 9 PM (C), Vitamin D3 Mon/Wed/Fri 9 AM (D), and Amoxicillin 8 AM + 2 PM + 8 PM (E) as a 7-day course that ends in a few days
- **History:** last 7 days, mostly taken, 3 missed (with caregiver alerts)
- **Reminders chat:** 3 messages from Ana, two marked Done

Both accounts are already email-verified and linked, so you can log in right away.

## Run it (Windows, Command Prompt in this folder)

1. **Get the admin key:** Firebase console → ⚙️ **Project settings** → **Service accounts** → **Generate new private key**. Save the file here as `serviceAccountKey.json`. Keep it private; it's in `.gitignore`.
2. Install once: `npm install` (needs Node.js; if `node -v` doesn't work, install the LTS from nodejs.org).
3. Run: `node reset_and_seed.js` and type `RESET` when asked.

Run it again any time to get a fresh demo (the history is always the 7 days before "now").

After the reset, log out of PillPal on each phone (or reinstall) and log in with a demo account. Open PillPal near the PillPalBox once so the box gets the new reminder list.
