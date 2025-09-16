/**
 * Lightweight config bootstrapping for the browser.
 * Attempts to fetch Supabase URL and anon key from the serverless function
 * at /api/supabase-config. Falls back to window env if present.
 */
(function(){
  const cache = {};
  async function fetchConfig(){
    if(cache.cfg) return cache.cfg;
    try {
      const res = await fetch('/api/supabase-config', { cache:'no-store' });
      if(!res.ok) throw new Error('Failed to load Supabase config');
      const { url, anonKey } = await res.json();
      if(!url || !anonKey) throw new Error('Incomplete Supabase config');
      cache.cfg = { url, anonKey };
    } catch {
      const url = window.NEXT_PUBLIC_SUPABASE_URL || window.SUPABASE_URL;
      const anonKey = window.NEXT_PUBLIC_SUPABASE_ANON_KEY || window.SUPABASE_ANON_KEY;
      if(!url || !anonKey) throw new Error('Supabase config missing. Ensure Vercel integration or expose NEXT_PUBLIC_SUPABASE_*');
      cache.cfg = { url, anonKey };
    }
    // expose globals for optional direct use
    window.SUPABASE_URL = cache.cfg.url;
    window.SUPABASE_ANON_KEY = cache.cfg.anonKey;
    return cache.cfg;
  }
  window.__getSupabaseConfig = fetchConfig;
})();
