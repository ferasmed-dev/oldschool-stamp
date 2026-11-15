# Digital stamp card (Old School Pub)

A loyalty stamp card that works in the phone's browser. Students don't need to install an app,
and you don't need Apple or Google developer accounts.

- `index.html`: the student's card. They scan the QR, sign up, and staff add stamps with a PIN.
- `owner.html`: the owner's page. Visits per night, customer list, regulars, people who haven't come back, monthly report, QR poster and settings.
- `supabase.sql`: the database (free Supabase account).
- `config.js`: your Supabase keys go here. If it's left empty, the app runs in **demo mode**.

## How visits are tracked
Every stamp is saved with the date and time, and **1 stamp = 1 visit**. A wait time (3 hours by default)
stops anyone getting two stamps on the same night. From this the owner's page works out:
- visits tonight, this week and this month, plus new customers
- who comes back (2+ visits), the regulars (3+) and who hasn't come in 14+ days
- contacts of customers who accepted offers, so you can win them back (for example on WhatsApp)

## Go live (about 20 min, free)
1. **Supabase:** make a free account at supabase.com, then *New project* (region: EU).
2. **SQL Editor:** paste all of `supabase.sql` and click **Run**.
3. **Change the PINs straight away.** Run this in the SQL Editor with your own numbers:
   ```sql
   update bars set
     staff_pin_hash = extensions.crypt('NEW_STAFF_PIN', extensions.gen_salt('bf')),
     owner_pin_hash = extensions.crypt('NEW_OWNER_PIN', extensions.gen_salt('bf'))
   where slug = 'old-school';
   ```
   (You can also change the staff PIN later from the owner's page.)
4. **Keys:** go to *Project Settings → API* and copy the **Project URL** and the **anon / publishable key** into `config.js`.
5. **Hosting (free):** create a GitHub repo (e.g. `ferasmed-dev/oldschool-card`), upload all the files,
   then *Settings → Pages → Deploy from branch → main*. Your link will be
   `https://ferasmed-dev.github.io/oldschool-card/`. (Netlify Drop also works: drag the folder in.)
6. Open `owner.html`, sign in with the owner PIN, then **Print poster** to get the QR for the tables.

## Updating it
- **Reward, stamps needed, staff PIN:** change them from the owner's page with no code.
- **Design or text changes:** edit the file on GitHub and save. The site updates itself within a minute.
- **Another bar:** add a row to `bars` (copy the `insert` at the end of `supabase.sql` with a new
  `slug`). Its card is at `index.html?bar=slug` and its panel at `owner.html?bar=slug`. Same app, new client.

## Privacy (GDPR)
It stores only the name, contact and visits, with a required consent box. Offers are a separate,
optional box. Contacts only appear on the owner's page if the customer accepted offers. If someone
asks to be deleted: `delete from cards where contact = '+34...';`
