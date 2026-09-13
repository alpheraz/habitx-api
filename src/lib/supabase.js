/**
 * Supabase admin client for HabitX API / Q / QLE.
 * Uses the service-role key (VPS only). Never import this from iOS.
 */

import { createClient } from '@supabase/supabase-js';

export function getSupabaseConfig() {
  const url = process.env.SUPABASE_URL ?? '';
  const serviceKey = process.env.SUPABASE_SECRET_KEY ?? '';
  return {
    url,
    configured: Boolean(url && serviceKey)
  };
}

/** @type {import('@supabase/supabase-js').SupabaseClient | null} */
let adminClient = null;

export function getSupabaseAdmin() {
  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!url || !serviceKey) return null;
  if (!adminClient) {
    adminClient = createClient(url, serviceKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
  }
  return adminClient;
}

/**
 * Verify a user Supabase access token. Returns auth user or null.
 * Never trust a client-supplied user_id.
 */
export async function verifySupabaseUser(accessToken) {
  const admin = getSupabaseAdmin();
  if (!admin || !accessToken) return null;
  const { data, error } = await admin.auth.getUser(accessToken);
  if (error || !data?.user?.id) return null;
  return data.user;
}
