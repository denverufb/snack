# Panther Pantry: Administrator and Regular Staff Setup

The frontend and backend changes are published to the existing GitHub Pages website. **The new permissions do not take effect until you run the SQL migration in Supabase.**

## Before running the upgrade
Ensure the following earlier migrations were already executed in your Supabase project:
1. `upgrade_finance.sql`
2. `upgrade_snack_catalog.sql`
3. `upgrade_purchase_pin.sql`
4. `upgrade_activity_inventory.sql`

Existing students, snack barcodes, stock counts, points, and transactions are preserved.

## Install in one run
Open [ADMIN_UPGRADE_RUN_ONCE.sql](./ADMIN_UPGRADE_RUN_ONCE.sql). In Supabase **Authentication > Users**, locate **your own staff login** and copy its User UID. Replace the one `REPLACE_WITH_YOUR_AUTH_USER_UUID` placeholder in the SQL with your exact Auth user UUID, then run the full SQL in **SQL Editor**. Do not use another employee's UUID.

The update is wrapped in one database transaction, so a SQL error rolls back that upgrade.

Only the Auth user UUID you explicitly select in the SQL is set to **admin**. Every other row in `public.staff` becomes **staff**, and the role defaults to `staff` for new authorized accounts. A Supabase Authentication login must also be enrolled in `public.staff` by an administrator; creating an Auth login alone does not authorize cashier access.

## After the SQL runs
1. Refresh [Snack Pass](https://denverufb.github.io/snack/) using Command+Shift+R.
2. Sign in with the primary administrator account.
3. Open the new **Admin** tab.
4. If no student ID is linked, press **Scan my student barcode to link my account**. Scan your existing student ID. This link is required to use tab mode or authorize removal.
5. Choose **Prepaid points** or **Running tab: charge me later**. This switch applies only to the linked administrator student account. Every other student remains on points.
6. Confirm a test purchase. In points mode it deducts the student points. In tab mode it adds the selling price to the tab ledger without changing points. Stock is reduced once in either mode.
7. Record tab payments only once cash was actually collected. These are tracked separately from point reloads so sales are not counted twice.
8. Sign in with another staff account to check that it can check out, add new students, and view stock, but cannot see the Activity, Finance, or Admin tabs or change snacks.

## Removing activity or products
The administrator must be signed in and scan their *linked student ID barcode* when prompted for removal. The same scanner prompt is used for removing a snack, student, Activity row, tab charge, or tab payment.

The server validates both the authenticated administrator login and the scanned barcode value. As with keyboard-emulating barcode scanners, the site cannot distinguish a physical scan from a manually typed matching value; treat the account login as the stronger security factor.

Activity removals archive records and exclude them from financial totals without reversing existing point balances or stock. Tab charge removals reduce the tab balance and financial revenue, subject to avoiding overpaid balances. Permanent snack removals preserve historic transaction totals.

## Admin and staff roles
- **Administrator:** finance and activity, snack pricing and inventory adjustments, student account management, administrator account-mode switching, and barcode-confirmed removal.
- **Regular staff:** checkout, point reloads, new student registration, student selection, and read-only stock/catalog browsing.

## Troubleshooting
- **Admin tab missing:** the SQL migration has not run successfully, the admin is signed into the wrong Auth account, or the browser still has cached files.
- **Barcode not recognized:** the administrator's linked student barcode is missing or was changed. Use the **Admin** tab to link it the first time.
- **Account tab mode unavailable:** the administrator student ID must be linked first.
- **Regular users cannot sign in:** make sure their Auth user UUID has an active row in `public.staff`.
- **Database migration fails:** copy the exact SQL error so the failed statement can be corrected before using the new features.

## Security note
Do **not** put a Supabase service-role key, database password, administrator barcode, or PIN into GitHub Pages source files. The site should use only the public Supabase publishable key. Server permissions are validated by Supabase functions and Row Level Security.
