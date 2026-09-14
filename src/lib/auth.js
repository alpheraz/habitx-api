import { verifySupabaseUser } from './supabase.js';

const DEV_TOKEN = process.env.HABITX_DEV_TOKEN ?? '';

export function bearerToken(req) {
  const header = req.header('authorization') || '';
  const match = header.match(/^Bearer\s+(\S+)/i);
  return match?.[1] ?? '';
}

export function sendError(res, status, code, message, requestId) {
  res.status(status).json({
    error: { code, message, requestId }
  });
}

export function asyncHandler(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

/**
 * Demo in-memory routes only. Prefer Supabase JWT when present.
 */
export async function requireAuth(req, res, next) {
  const token = bearerToken(req);
  if (!token) {
    return sendError(res, 401, 'UNAUTHORIZED', 'Authentication required', req.requestId);
  }

  if (DEV_TOKEN && token === DEV_TOKEN) {
    req.user = {
      id: 'user_demo',
      displayName: 'Jake',
      email: 'jake@habitx.local',
      auth: 'dev-token'
    };
    req.accessToken = token;
    return next();
  }

  const sbUser = await verifySupabaseUser(token);
  if (!sbUser) {
    return sendError(res, 401, 'UNAUTHORIZED', 'Invalid or expired session', req.requestId);
  }

  req.user = {
    id: sbUser.id,
    displayName: sbUser.user_metadata?.full_name ?? sbUser.user_metadata?.name ?? null,
    email: sbUser.email ?? null,
    auth: 'supabase'
  };
  req.accessToken = token;
  return next();
}

/** Q / scoring: Supabase JWT only. Never accept the demo token. */
export async function requireSupabaseUser(req, res, next) {
  const token = bearerToken(req);
  if (!token) {
    return sendError(res, 401, 'UNAUTHORIZED', 'Supabase access token required', req.requestId);
  }
  if (DEV_TOKEN && token === DEV_TOKEN) {
    return sendError(res, 401, 'UNAUTHORIZED', 'Demo token cannot call Q', req.requestId);
  }
  const sbUser = await verifySupabaseUser(token);
  if (!sbUser) {
    return sendError(res, 401, 'UNAUTHORIZED', 'Invalid or expired session', req.requestId);
  }
  req.user = {
    id: sbUser.id,
    displayName: sbUser.user_metadata?.full_name ?? sbUser.user_metadata?.name ?? null,
    email: sbUser.email ?? null,
    auth: 'supabase'
  };
  req.accessToken = token;
  return next();
}
