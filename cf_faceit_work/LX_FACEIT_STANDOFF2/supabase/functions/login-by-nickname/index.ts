import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: cors });

type Profile = { id: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Метод не поддерживается" }, 405);

  try {
    const body = await req.json();
    const nick = String(body?.nickname || "").trim();
    const password = body?.password;

    if (!/^[A-Za-z0-9_-]{3,20}$/.test(nick)
      || typeof password !== "string"
      || password.length < 1
      || password.length > 128) {
      return json({ error: "Проверь никнейм, игровой ID и пароль" }, 400);
    }

    const url = Deno.env.get("SUPABASE_URL");
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !service || !anon) {
      return json({ error: "Не настроены секреты Supabase для функции входа" }, 500);
    }

    const admin = createClient(url, service, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const lookup = await admin.rpc("cf_auth_profile_by_nickname", { p_nickname: nick });
    if (lookup.error) {
      return json({ error: "Вход по нику не настроен. Установи SQL/38 и обнови Edge Function." }, 500);
    }

    const profile = lookup.data as Profile | null;
    if (!profile?.id) {
      return json({ error: "Неверный никнейм или пароль" }, 401);
    }

    const { data: userData, error: userError } = await admin.auth.admin.getUserById(profile.id);
    const email = userData?.user?.email;
    if (userError || !email) {
      return json({ error: "Неверный никнейм или пароль" }, 401);
    }

    const client = createClient(url, anon, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.auth.signInWithPassword({ email, password });
    if (error || !data.session) {
      const message = String(error?.message || "").toLowerCase();
      if (message.includes("email not confirmed")) {
        return json({ error: "Почта не подтверждена. Открой письмо от Supabase и подтверди адрес." }, 401);
      }
      return json({ error: "Неверный никнейм или пароль" }, 401);
    }

    return json({
      access_token: data.session.access_token,
      refresh_token: data.session.refresh_token,
    });
  } catch {
    return json({ error: "Ошибка входа. Проверь данные и попробуй ещё раз." }, 400);
  }
});
