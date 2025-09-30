/**
 * Lightweight config bootstrapping for the browser.
 * Fallback order (stable / static first):
 *  1. /supabase.json (committed static file for predictable builds)
 *  2. <meta name="supabase-url" / name="supabase-anon-key"> tags
 *  3. Window globals (NEXT_PUBLIC_*) injected by hosting platform
 *  4. Serverless function /api/supabase-config (optional dynamic override)
 * If everything fails we throw an explicit error early so UI does not silently show 0 data.
 */
(function(){
  const cache = {};
  async function fetchConfig(){
    if(cache.cfg) return cache.cfg;

    // 1. Static JSON (preferred for fallback stability)
    try {
      const rStatic = await fetch('/supabase.json', { cache:'no-store' });
      if(rStatic.ok){
        const j = await rStatic.json();
        if(j.url && j.anonKey){ cache.cfg = { url:j.url, anonKey:j.anonKey }; expose(cache.cfg); return cache.cfg; }
      }
    } catch {}

    // 2. Meta tags
    const metaUrl = (typeof document!=='undefined' && document.querySelector('meta[name="supabase-url"]'))?.content;
    const metaAnon = (typeof document!=='undefined' && document.querySelector('meta[name="supabase-anon-key"]'))?.content;
    if(metaUrl && metaAnon){ cache.cfg = { url:metaUrl, anonKey:metaAnon }; expose(cache.cfg); return cache.cfg; }

    // 3. Window globals
    const envUrl = window.NEXT_PUBLIC_SUPABASE_URL || window.SUPABASE_URL;
    const envAnon = window.NEXT_PUBLIC_SUPABASE_ANON_KEY || window.SUPABASE_ANON_KEY;
    if(envUrl && envAnon){ cache.cfg = { url:envUrl, anonKey:envAnon }; expose(cache.cfg); return cache.cfg; }

    // 4. Serverless function (last because on purely static deploys it 404s)
    try {
      const res = await fetch('/api/supabase-config', { cache:'no-store' });
      if(res.ok){
        const { url, anonKey } = await res.json();
        if(url && anonKey){ cache.cfg = { url, anonKey }; expose(cache.cfg); return cache.cfg; }
      }
    } catch {}

    throw new Error('Supabase configuration could not be resolved (checked supabase.json, meta tags, env globals, api function).');
  }

  function expose(cfg){
    window.SUPABASE_URL = cfg.url;
    window.SUPABASE_ANON_KEY = cfg.anonKey;
  }

  window.__getSupabaseConfig = fetchConfig;
})();
