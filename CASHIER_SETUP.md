# Cashier account setup

The Admin tab can securely create and manage up to 15 active student cashier logins. Each completed checkout is already saved with the signed-in cashier's `staff_id`; the Admin tab uses that audit trail to show purchase count, sales total, last checkout, and item-level history.

## One-time Supabase setup

1. Run [`upgrade_cashier_accounts.sql`](./upgrade_cashier_accounts.sql) in **Supabase > SQL Editor** after `ADMIN_UPGRADE_RUN_ONCE.sql`.
2. Install the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) if it is not already available, then sign in and link this repository to the existing Supabase project.
3. Deploy the secure server function:

   ```sh
   supabase functions deploy create-cashier
   ```

4. Set the allowed website origin for the function:

   ```sh
   supabase secrets set SITE_ORIGIN=https://denverufb.github.io
   ```

5. In **Supabase > Authentication > URL Configuration**, add
   `https://denverufb.github.io/snack/` to **Redirect URLs**. This lets a
   cashier return to the app after using the administrator's password-reset
   email.

Supabase automatically supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to its deployed function. Never put the service-role key in `config.js`, GitHub, or browser code.

## Creating cashier accounts

1. Sign in with the administrator account and open **Admin**.
2. Under **Cashier accounts**, enter the student's name, login email, and a temporary password of at least 12 characters.
3. Create the account and share the temporary password privately.
4. At first sign-in, the cashier is required to replace the temporary password before the register opens.

Administrators can disable or re-enable a cashier without deleting their purchase history, send password-reset emails, and inspect every snack purchase attributed to a cashier. The database trigger enforces a maximum of 15 active regular cashier accounts; the administrator does not count toward that limit.

## Security model

- Only a valid, active administrator session can call the account-creation function.
- The Supabase service-role key stays inside the deployed Edge Function.
- Cashier passwords are sent over HTTPS to Supabase Auth and are not stored in the staff table or transaction records.
- Account management and cashier purchase reports are checked again by administrator-only database RPCs.
- Disabling a cashier immediately makes `is_staff()` fail and blocks that login from the app while preserving its audit history.
