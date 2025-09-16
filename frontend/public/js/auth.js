// Auth utilities shared by pages
import { getClient, getSession, signOut, determineHome } from './api-client.js';

export async function redirectIfSession(){ const s = await getSession(); if(s){ const dest = await determineHome(); window.location.href = dest; } }
export async function ensureSessionRedirect({ redirectIf=false, target='index.html' }={}){
  const sb = await getClient();
  const { data } = await sb.auth.getSession();
  const session = data.session;
  if(!session && redirectIf){ window.location.href = target; return null; }
  return session;
}
export async function logout({ redirect=false, to='index.html' }={}){ try{ await signOut(); } finally { if(redirect) window.location.href = to; } }

// Ensure admin credentials route on login page if used directly
if(document.currentScript && document.currentScript.type === 'module'){
  // no-op JS module marker to allow import side-effects in some pages
}
