// Global Supabase client bootstrap used by all pages
(function(){
  let clientPromise = null;
  window.getSupabase = async function getSupabase(){
    if(clientPromise) return clientPromise;
    clientPromise = (async ()=>{
      const cfg = await (window.__getSupabaseConfig? window.__getSupabaseConfig(): Promise.reject(new Error('config.js not loaded')));
      const { createClient } = window.supabase || {};
      if(!createClient) throw new Error('Supabase JS not loaded');
      const sb = createClient(cfg.url, cfg.anonKey, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
        global: { headers: { 'x-client-info': 'cereal-frontend/1.0' } }
      });
      window.supabaseClient = sb;
      return sb;
    })();
    return clientPromise;
  }
})();
