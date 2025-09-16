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
      // Try optional static JSON fallback first
      try {
        const r2 = await fetch('/supabase.json', { cache:'no-store' });
        if(r2.ok){
          const { url, anonKey } = await r2.json();
          if(url && anonKey){ cache.cfg = { url, anonKey }; window.SUPABASE_URL=url; window.SUPABASE_ANON_KEY=anonKey; return cache.cfg; }
        }
      } catch {}
      // Fallbacks: meta tags, then window globals
      const metaUrl = (typeof document!=='undefined' && document.querySelector('meta[name="supabase-url"]'))?.content;
      const metaAnon = (typeof document!=='undefined' && document.querySelector('meta[name="supabase-anon-key"]'))?.content;
      const url = metaUrl || window.NEXT_PUBLIC_SUPABASE_URL || window.SUPABASE_URL;
      const anonKey = metaAnon || window.NEXT_PUBLIC_SUPABASE_ANON_KEY || window.SUPABASE_ANON_KEY;
      if(!url || !anonKey) throw new Error('Supabase config missing. Ensure Vercel integration has NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY, or add /supabase.json, or add <meta name="supabase-url"> & <meta name="supabase-anon-key"> tags.');
      cache.cfg = { url, anonKey };
    }
    // expose globals for optional direct use
    window.SUPABASE_URL = cache.cfg.url;
    window.SUPABASE_ANON_KEY = cache.cfg.anonKey;
    return cache.cfg;
  }
  window.__getSupabaseConfig = fetchConfig;
})();
