/**
 * Supabase clients for HabitX API / Q / QLE.
 * Service-role key stays on the VPS. Never import this from iOS.
 */

import { createClient } from '@supabase/supabase-js';

function lookLikeServiceRole(key) {
  if (!key) return false;
  if (key.startsWith('sb_publishable_') || key.startsWith('sb_anon_')) return false;
  if (key.startsWith('sb_secret_') || key.startsWith('sb_service_')) return true;
  const parts = key.split('.');
  if (parts.length === 3) {
    try {
      const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
      return payload.role === 'service_role';
    } catch {
      return false;
    }
  }
  return false;
}

export function getSupabaseConfig() {
  const url = process.env.SUPABASE_URL ?? '';
  const secret = process.env.SUPABASE_SECRET_KEY ?? '';
  const publishable = process.env.SUPABASE_PUBLISHABLE_KEY ?? '';
  const serviceKey = lookLikeServiceRole(secret) ? secret : '';
  const anonKey = publishable || (!serviceKey ? secret : '');
  return {
    url,
    configured: Boolean(url && (serviceKey || anonKey)),
    hasServiceRole: Boolean(url && serviceKey),
    hasAnonKey: Boolean(url && anonKey)
  };
}

/** @type {import('@supabase/supabase-js').SupabaseClient | null} */
let adminClient = null;

export function getSupabaseAdmin() {
  const { url, hasServiceRole } = getSupabaseConfig();
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!url || !hasServiceRole) return null;
  if (!adminClient) {
    adminClient = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
  }
  return adminClient;
}

export function getSupabaseAnon() {
  const cfg = getSupabaseConfig();
  const key = process.env.SUPABASE_PUBLISHABLE_KEY
    || (!lookLikeServiceRole(process.env.SUPABASE_SECRET_KEY ?? '')
      ? process.env.SUPABASE_SECRET_KEY
      : '');
  if (!cfg.url || !key) return null;
  return createClient(cfg.url, key, {
    auth: { persistSession: false, autoRefreshToken: false }
  });
}

/**
 * User-scoped client: PostgREST + RLS using the caller's JWT.
 */
export function getSupabaseForUser(accessToken) {
  const cfg = getSupabaseConfig();
  const secret = process.env.SUPABASE_SECRET_KEY ?? '';
  const key = process.env.SUPABASE_PUBLISHABLE_KEY
    || (lookLikeServiceRole(secret) ? '' : secret);
  if (!cfg.url || !key || !accessToken) return null;
  return createClient(cfg.url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } }
  });
}

/**
 * Verify a user Supabase access token. Returns auth user or null.
 * Never trust a client-supplied user_id.
 */
export async function verifySupabaseUser(accessToken) {
  if (!accessToken) return null;
  const verifier = getSupabaseAdmin() ?? getSupabaseAnon();
  if (!verifier) return null;
  const { data, error } = await verifier.auth.getUser(accessToken);
  if (error || !data?.user?.id) return null;
  return data.user;
}
