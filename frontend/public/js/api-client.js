// Shared API client helpers for auth and DB access
export async function getClient(){ return await window.getSupabase(); }

export async function getSession(){ const sb = await getClient(); const { data } = await sb.auth.getSession(); return data.session; }
export async function signIn(email, password){
  const sb = await getClient();
  const { data, error } = await sb.auth.signInWithPassword({ email, password });
  if(error) throw error; return data;
}
export async function signInWithProvider(provider){ const sb = await getClient(); const { data, error } = await sb.auth.signInWithOAuth({ provider, options:{ redirectTo: location.origin + '/pages/user-dashboard.html' } }); if(error) throw error; return data; }
export async function signUp({ name, email, password }){
  const sb = await getClient();
  const { data, error } = await sb.auth.signUp({ email, password, options: { data: { name } } }); if(error) throw error; return data;
}
export async function signOut(){ const sb = await getClient(); await sb.auth.signOut(); }

export async function selectTable({ table, columns='*', filters=[], order=null, limit=null }){
  const sb = await getClient(); let q = sb.from(table).select(columns);
  for(const f of (filters||[])) q = q.eq(f.column, f.value);
  if(order) q = q.order(order.column, { ascending: !!order.asc });
  if(limit) q = q.limit(limit);
  const { data, error } = await q; if(error) throw error; return data || [];
}

// Admin email shortcut
const ADMIN_EMAIL = 'seerealthesis@gmail.com';
export async function isMyEmailAdmin(){ const sb = await getClient(); const { data } = await sb.auth.getUser(); return data?.user?.email === ADMIN_EMAIL; }
export async function fetchMyProfile(){ const sb = await getClient(); const { data: u } = await sb.auth.getUser(); if(!u?.user) return null; const { data } = await sb.from('profiles').select('id,name,role,points,avatar_url').eq('id', u.user.id).maybeSingle(); return data; }
export async function fetchProfileRole(){ const p = await fetchMyProfile(); return p?.role || null; }

export async function determineHome(){
  // If admin email, send to admin dash; otherwise user dash
  const adminByEmail = await isMyEmailAdmin();
  if(adminByEmail) return 'pages/admin/admin-dashboard.html';
  // Fallback to profile role check
  const role = await fetchProfileRole();
  if(role === 'admin') return 'pages/admin/admin-dashboard.html';
  return 'pages/user-dashboard.html';
}

// Generic RPC helpers
export async function rpc(name, params){ const sb = await getClient(); const { data, error } = await sb.rpc(name, params||{}); if(error) throw error; return data; }

// Convenience wrappers used in pages
export async function getUser(){ const sb = await getClient(); const { data, error } = await sb.auth.getUser(); if(error) throw error; return data.user; }
