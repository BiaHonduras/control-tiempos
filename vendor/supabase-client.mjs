// Pinned browser distribution, served locally to avoid external CDN failures.
import './supabase-2.38.0.min.js';
export const createClient = globalThis.supabase.createClient;
