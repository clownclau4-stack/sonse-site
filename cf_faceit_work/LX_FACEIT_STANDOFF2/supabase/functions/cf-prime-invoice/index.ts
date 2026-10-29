import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Content-Type': 'application/json' };
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'POST required' }), { status: 405, headers: cors });
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const botToken = Deno.env.get('TELEGRAM_BOT_TOKEN');
  if (!botToken) return new Response(JSON.stringify({ error: 'TELEGRAM_BOT_TOKEN is not configured' }), { status: 503, headers: cors });
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } });
  const { data: { user }, error } = await userClient.auth.getUser(token);
  if (error || !user) return new Response(JSON.stringify({ error: 'Sign in required' }), { status: 401, headers: cors });
  const payload = `cfprime:${user.id}:${crypto.randomUUID()}`;
  const response = await fetch(`https://api.telegram.org/bot${botToken}/createInvoiceLink`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: 'FACEIT PRIME · 30 дней', description: 'Статус FACEIT PRIME в LX FACEIT на 30 дней.', payload, currency: 'XTR', prices: [{ label: 'FACEIT PRIME (30 дней)', amount: 300 }] })
  });
  const result = await response.json();
  if (!response.ok || !result.ok || !result.result) return new Response(JSON.stringify({ error: result.description || 'Telegram invoice creation failed' }), { status: 502, headers: cors });
  return new Response(JSON.stringify({ invoice_link: result.result, amount: 300, currency: 'XTR' }), { status: 200, headers: cors });
});
