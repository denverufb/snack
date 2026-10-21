# Snack Pass: Fast Barcode Checkout

A complete school snack store app with a real database, staff login, instant in-browser barcode lookup, and atomic checkout transactions. Designed for common USB barcode scanners (including the Honeywell Hyperion 1300g).

## What it does

- Register, edit, deactivate/reactivate students by student-ID barcode.
- Register, edit, deactivate/reactivate snacks by UPC/barcode; set prices to **1 or 2 points**.
- **$1 = 1 point**: staff confirms a payment, then clicks **+$5** or **+$10** to add points. **This records payment, but does not process credit cards or collect money.**
- Scan a student ID, then scan snack after snack in the **same box**. No checkout button.
- Points are only deducted after the database checks the balance and inventory.
- Prevents negative balances and out-of-stock purchases.
- Manual signed point adjustments, with a required explanation.
- Refund any of the recent purchases once, restoring points and tracked inventory.
- Recent transaction history, CSV export, and 30-second background sync.
- Staff-only Supabase authentication and row-level security.

## Project files

| File | Purpose |
| --- | --- |
| `index.html` | Web app layout, colors, and all forms |
| `app.js` | Barcode logic, displays, Supabase connection, checkout workflow |
| `config.js` | Your Supabase URL and **publishable/anon** key |
| `schema.sql` | Database tables, security policies, transaction-safe server functions |

## Setup (about 6 steps)

### 1. Create a free Supabase project

Go to [supabase.com](https://supabase.com) and create a project. Save the database password in a secure location.

### 2. Create the database

Open **SQL Editor > New query**. Paste **all** of `schema.sql`, then click **Run**. The database will create `students`, `snacks`, `transactions`, and `staff` tables with secure functions.

**Important:** This code is for a *new* Supabase project. Do not run it against an existing database if those table names are already in use for something different.

### 3. Create a staff login

In Supabase, open **Authentication > Users > Add user > Create new user**. Enter a staff email and password. Copy the user's UUID from the users page.

Next, open **SQL Editor** and run:

```sql
insert into public.staff (id, display_name)
values ('PASTE-THE-AUTH-USER-UUID', 'School Store Staff');
```

To add another authorized cashier later, create another Auth user and add another row to `public.staff`. In **Authentication > Providers > Email**, disable public sign-ups if enabled. Do not share staff passwords with students.

### 4. Connect the website

Go to your Supabase project's **Project Settings > API Keys** or **Connect** section. Copy the **Project URL** and **publishable** key (or legacy `anon` key). Open `config.js` and replace these two placeholders:

```js
window.SNACK_PASS_CONFIG = {
  supabaseUrl: "https://YOUR-PROJECT-ID.supabase.co",
  supabaseAnonKey: "YOUR-SUPABASE-PUBLISHABLE-OR-ANON-KEY"
};
```

**Never paste a `service_role` or secret key into a website**, GitHub, or `config.js`. Publishable/anon keys are meant to be public; access is controlled by authenticated staff status and database RLS.

### 5. Publish your site on GitHub Pages

Create a **private or public repo** (GitHub Pages availability depends on your plan and repository settings), then upload `index.html`, `app.js`, and `config.js` to the repository root. `schema.sql` can stay on your computer; it is not required by the live website.

Go to **Settings > Pages** and select **Deploy from a branch**, usually `main` and `/ (root)`. Open the Pages URL that GitHub gives you. Sign in with the staff credentials from Step 3.

If you're using your existing school snack-pass repository, back up the current `index.html` before replacing it. This is a **replacement app**, not a small patch to your prior Google Sheets script. It uses Supabase instead of Apps Script/Google Sheets.

### 6. Set up your scanner

1. Plug the USB Honeywell Hyperion 1300g into your Mac or PC.
2. Open Snack Pass and select **Students**. Click the Student ID field, then scan a student ID. It should type the full barcode, including leading zeroes.
3. Save a student. Select **Snacks** and scan product UPCs to register snacks at 1 or 2 points.
4. Return to **Checkout**. Scan a student ID and then scan a snack. The input should clear automatically after each Enter.
5. If the scanner does not submit the barcode, configure its **suffix to Enter/Carriage Return (CR)** in the scanner manual. You can also type a barcode manually and press Enter.
6. Add 5 or 10 points only after staff has collected payment separately.

## Optional: instant cross-device updates

The app already refreshes the student/snack rosters every 30 seconds and updates the local checkout immediately after each purchase. For updates from other cash registers to appear faster, enable Supabase Realtime / Postgres Changes on `students`, `snacks`, and `transactions` under **Database > Publications**. The UI is also functional without this optional setting.

## Speed and reliability

Barcode identification takes place from in-memory maps already loaded in the browser; there is no remote lookup on every scan. Every purchase still needs a secure database confirmation, so **a one-second response is a goal, not a guarantee**. Actual latency depends on school Wi-Fi, Supabase project location, and database load.

Each checkout has a unique request ID. The database checks this ID to prevent accidental duplicate transactions for the same request. If the connection fails during a checkout, the app flags the result as **unconfirmed** instead of claiming success. Check the student's balance and transaction history before scanning the same product again.

There is **no offline checkout**. Do not attempt to sell snacks on a disconnected device.

## Notes on data and access

- Student barcodes are strings, not numbers, so barcodes with leading zeros work.
- Deactivation preserves student history and does not delete purchased records.
- Tracked stock starts at the quantity you enter; a blank stock field means unlimited/not tracked.
- Transaction records are audit logs; ordinary staff cannot directly edit them.
- The default app shows at most **1,000 students, 1,000 snacks and 200 recent transactions**. If you exceed those limits, add pagination.
- To fully remove a staff member's access, set `active=false` on their `public.staff` row or remove their Auth user.
- The app does not store payment card details and does not automatically charge students' accounts through a payment processor.

## Quick troubleshooting

**Login says not authorized:** Authentication user exists, but you haven't inserted their UUID into `public.staff` (or the staff row is inactive).

**Barcode scans but nothing checks out:** Make sure the student's barcode is saved in Students, snack UPC saved in Snacks, both are active, the student has points, and the scanner sends Enter.

**Scanned barcode is missing its leading zeroes:** Save/scan the ID as *text*, not as a number or Excel value.

**"Failed to fetch" or "NetworkError":** Check Wi-Fi, Supabase URL, and whether your project is paused. A purchase with an uncertain result should be verified in Activity before attempting it again.

**CORS or blank website:** Access it from your published HTTPS GitHub Pages URL. Confirm the Supabase script CDN is not being blocked by the school network.

**Different registers show different balances temporarily:** Turn on Realtime. The database is authoritative and serializes purchases even if a display briefly lags.
