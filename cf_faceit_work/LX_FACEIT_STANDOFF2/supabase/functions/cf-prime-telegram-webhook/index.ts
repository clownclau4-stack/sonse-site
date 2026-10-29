import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST required', { status: 405 });
  const expectedSecret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET');
  const suppliedSecret = req.headers.get('X-Telegram-Bot-Api-Secret-Token');
  if (!expectedSecret || suppliedSecret !== expectedSecret) return new Response('Forbidden', { status: 403 });
  const botToken = Deno.env.get('TELEGRAM_BOT_TOKEN');
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!botToken || !url || !serviceKey) return new Response('Missing server secrets', { status: 500 });
  const update = await req.json();
  const answer = async (method: string, data: unknown) => fetch(`https://api.telegram.org/bot${botToken}/${method}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(data) });
  if (update.pre_checkout_query) {
    const q = update.pre_checkout_query;
    const payload = String(q.invoice_payload || '').split(':');
    const valid = payload.length === 3 && payload[0] === 'cfprime' && q.currency === 'XTR' && q.total_amount === 300;
    await answer('answerPreCheckoutQuery', { pre_checkout_query_id: q.id, ok: valid, ...(valid ? {} : { error_message: 'Неверный счёт FACEIT PRIME. Открой покупку заново на сайте.' }) });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  const payment = update.message?.successful_payment;
  if (payment) {
    const parts = String(payment.invoice_payload || '').split(':');
    if (parts.length !== 3 || parts[0] !== 'cfprime' || !/^[0-9a-f-]{36}$/i.test(parts[1]) || payment.currency !== 'XTR' || payment.total_amount !== 300 || !payment.telegram_payment_charge_id) {
      return new Response('Invalid successful_payment payload', { status: 400 });
    }
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { error } = await admin.rpc('cf_prime_apply_payment', { p_user_id: parts[1], p_telegram_charge_id: payment.telegram_payment_charge_id, p_amount: payment.total_amount, p_currency: payment.currency });
    if (error) { console.error('cf_prime_apply_payment failed', error.message); return new Response('Failed to apply payment', { status: 500 }); }
  }
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
});
