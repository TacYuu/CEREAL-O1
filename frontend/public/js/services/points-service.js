import { getClient, rpc } from '../api-client.js';

export async function adminAdjustPoints({ userId, delta, reason }){
  // Uses RPC to adjust points and create transaction + log
  const data = await rpc('admin_adjust_points', { target_user: userId, delta, reason });
  return data;
}

export async function getRecentClaimsCount(days){
  const sb = await getClient(); const since = new Date(Date.now() - days*86400000).toISOString();
  const { count } = await sb.from('reward_claims').select('id', { count: 'exact', head: true }).gte('created_at', since);
  return count || 0;
}
