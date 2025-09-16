import { getClient, selectTable } from '../api-client.js';

export async function listUsers(){
  const rows = await selectTable({ table:'profiles', columns:'id,email,name,role,points,avatar_url' , order:{ column:'points', asc:false }, limit:500 });
  return rows.map(r=>({ ...r }));
}

export async function setUserRole(userId, role){
  const sb = await getClient();
  const { error } = await sb.from('profiles').update({ role }).eq('id', userId);
  if(error) throw error; return true;
}

export async function ensureSessionRedirect(opts){
  const { ensureSessionRedirect } = await import('../auth.js');
  return await ensureSessionRedirect(opts);
}
