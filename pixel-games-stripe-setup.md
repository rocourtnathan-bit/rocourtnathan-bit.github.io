# Turning on buying in the Online Shop (Stripe)

The game never decides that someone paid. Stripe takes the money on its own page, tells a small server function, the function writes the payment into your database, and the game gives the player their purchase the next time it checks. Your card details, bank details and Stripe secret key never go in the game, the repo or a chat.

**Do this in TEST MODE first** (the switch at the top of the Stripe dashboard). Nothing real is charged in test mode.

## 0. Before you start
- A Stripe account has to belong to someone old enough to hold one (18 in most countries). If you're younger, a parent or guardian opens it and owns the payout bank account. Check Stripe's sign-up page for your country.
- Stripe takes a fee on each sale (roughly 3% plus a small fixed amount; check their pricing page). On a $5 item that's close to 10%.
- You need a way to deal with refunds and complaints.

## 1. Make a payment link for each shop item
Stripe dashboard → **Payment links** → **New**.
- Pick or create a product with the **same price** as the item in your shop (the server refuses a payment that is less than the shop price).
- Turn **off** "let customers adjust quantity".
- Create it and copy the link (looks like `https://buy.stripe.com/test_...`).

## 2. Put the link in the game
Open the creator panel → **Online Shop items** → paste the link in that item's **Payment link** box → **Save the shop**. An item without a link still says "Under development". Test-mode links and live-mode links are different: swap them when you go live.

## 3. Run the newest `pixel-games-hub.sql`
Supabase → SQL Editor → paste the whole file → Run. (It adds the purchases table and the functions the game uses.)

## 4. Put the function on Supabase
Install the Supabase CLI, then in a folder:
```
supabase login
supabase link --project-ref YOUR_PROJECT_REF
mkdir -p supabase/functions/stripe-webhook
cp pixel-games-stripe-webhook.ts supabase/functions/stripe-webhook/index.ts
supabase functions deploy stripe-webhook --no-verify-jwt
```
(`--no-verify-jwt` is needed because Stripe, not a logged-in player, calls it. The function checks Stripe's signature itself.)

## 5. Tell Stripe where to call
Stripe dashboard → **Developers → Webhooks → Add endpoint**
- URL: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/stripe-webhook`
- Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `charge.refunded`
- Copy the **Signing secret** (`whsec_...`).

Then give the function its two secrets (from Stripe → Developers → API keys, and the signing secret):
```
supabase secrets set STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_...
```

## 6. Try it
Open the game → Online Shop → Buy. On Stripe's page use the test card `4242 4242 4242 4242`, any future date, any 3 digits. Come back to the game: within a few seconds it says "Purchase received" and the levels / credits / outfit are there. The creator panel's **Purchases** list shows it as "given".

## 7. Going live
Switch Stripe to live mode, make live payment links, paste them in the panel, add the endpoint again in live mode, and set the live `sk_live_...` key and the new `whsec_...` with `supabase secrets set`. Add your payout bank account in Stripe (the money goes to that bank account after Stripe's fee).

## Good to know
- A payment the server can't match (an item you deleted, a link someone edited, a price that was too low) is shown in the Purchases list as red "unmatched": the money is in Stripe, so you sort it out there.
- A refund in Stripe takes the purchase back only if the player hasn't been given it yet. After that, take the levels away in the creator panel's player editor.
- Anyone who knows another player's id could claim that player's waiting purchase. Ids are long random strings and only shown in Settings, so this is unlikely, but it's the reason purchases are given to whoever claims first.
- Rebuilding or editing the game file can't give anyone free things: only a payment Stripe confirmed creates a row.
