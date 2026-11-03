// Supabase Edge Function: stripe-webhook   (deploy with:  supabase functions deploy stripe-webhook --no-verify-jwt)
//
// Stripe calls this after someone pays. It checks the call really came from Stripe (the signature), works out WHO paid and for WHAT,
// and writes a row in px_purchases. The game then gives the player their levels / credits / outfit the next time it checks.
// It uses the server's secret key, which never goes in the game or the repo. Secrets it needs (set with `supabase secrets set`):
//   STRIPE_SECRET_KEY      sk_test_... (testing) or sk_live_... (real money)
//   STRIPE_WEBHOOK_SECRET  whsec_...   (shown when you add the endpoint in Stripe)
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to every Edge Function automatically.)
import Stripe from 'https://esm.sh/stripe@14.21.0?target=denonext';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, { apiVersion: '2024-06-20', httpClient: Stripe.createFetchHttpClient() });
const crypto = Stripe.createSubtleCryptoProvider();
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const OK = () => new Response('ok', { status: 200 });

Deno.serve(async (req) => {
  const body = await req.text(); // (the signature is over the exact text Stripe sent: don't parse it before checking)
  let event: Stripe.Event;
  try { event = await stripe.webhooks.constructEventAsync(body, req.headers.get('stripe-signature') ?? '', Deno.env.get('STRIPE_WEBHOOK_SECRET')!, undefined, crypto); }
  catch (_e) { return new Response('bad signature', { status: 400 }); } // not from Stripe: ignore

  // a refund in Stripe: if the player hasn't been given it yet, take it back
  if (event.type === 'charge.refunded') {
    const ch = event.data.object as Stripe.Charge;
    if (ch.payment_intent) {
      const found = await stripe.checkout.sessions.list({ payment_intent: String(ch.payment_intent), limit: 1 });
      for (const s of found.data) await db.from('px_purchases').update({ status: 'refunded' }).eq('provider_ref', s.id).eq('status', 'paid');
    }
    return OK();
  }

  if (event.type !== 'checkout.session.completed' && event.type !== 'checkout.session.async_payment_succeeded') return OK();
  const s = event.data.object as Stripe.Checkout.Session;
  if (s.payment_status !== 'paid') return OK(); // (a bank payment that hasn't cleared yet: Stripe calls again when it does)

  const paid = (s.amount_total ?? 0) / 100;
  // the game puts "<player id>-<item id>" on the payment link
  const ref = s.client_reference_id ?? '', cut = ref.indexOf('-'), uid = ref.slice(0, cut), itemId = ref.slice(cut + 1);
  const { data: cfg } = await db.from('px_mod_cfg').select('shop').eq('id', 1).single();
  const item = Array.isArray(cfg?.shop) ? cfg!.shop.find((x: { id: string }) => x.id === itemId) : null;
  const goodUid = /^[a-z0-9]{8,32}$/.test(uid);

  // anything odd is still written down (as "unmatched") so the creator can see the money arrived and sort it out
  const row = (goodUid && item && paid + 0.001 >= Number(item.price))
    ? { uid, item_id: item.id, name: item.name, kind: item.kind, amount: item.amount, ref: item.ref, price: paid, status: 'paid' }
    : { uid: goodUid ? uid : 'unknown', item_id: (itemId || '?').slice(0, 20), name: item ? item.name + ' (paid too little)' : 'UNKNOWN ITEM ' + itemId, kind: 'other', amount: 0, ref: '', price: paid, status: 'unmatched' };
  const { error } = await db.from('px_purchases').upsert({ ...row, provider: 'stripe', provider_ref: s.id }, { onConflict: 'provider_ref', ignoreDuplicates: true }); // (the same payment twice is recorded once)
  if (error) return new Response('db error', { status: 500 }); // Stripe retries a 500 for a few days
  return OK();
});
