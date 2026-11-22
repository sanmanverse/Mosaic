import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: corsHeaders });

  const authHeader = req.headers.get('Authorization');
  const token = authHeader?.replace(/^Bearer\s+/i, '');
  if (!token) return Response.json({ error: 'Authentication required' }, { status: 401, headers: corsHeaders });

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return Response.json({ error: 'Server configuration missing' }, { status: 500, headers: corsHeaders });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error: authError } = await admin.auth.getUser(token);
  if (authError || !user) return Response.json({ error: 'Invalid session' }, { status: 401, headers: corsHeaders });
  const lastSignIn = user.last_sign_in_at ? new Date(user.last_sign_in_at).getTime() : 0;
  if (!lastSignIn || Date.now() - lastSignIn > 15 * 60 * 1000) {
    return Response.json({ error: 'Please sign in again before deleting your account' }, { status: 403, headers: corsHeaders });
  }

  // Remove the user's cover/avatar files before deleting the auth identity.
  while (true) {
    const { data: files, error } = await admin.storage.from('article-covers').list(user.id, { limit: 100, offset: 0 });
    if (error) return Response.json({ error: 'Could not remove account media' }, { status: 500, headers: corsHeaders });
    if (!files?.length) break;
    const paths = files.filter((f) => f.name && Boolean(f.id)).map((f) => `${user.id}/${f.name}`);
    if (!paths.length) break;
    const { error: removeError } = await admin.storage.from('article-covers').remove(paths);
    if (removeError) return Response.json({ error: 'Could not remove account media' }, { status: 500, headers: corsHeaders });
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) return Response.json({ error: 'Account deletion failed' }, { status: 500, headers: corsHeaders });
  return Response.json({ deleted: true }, { headers: corsHeaders });
});
