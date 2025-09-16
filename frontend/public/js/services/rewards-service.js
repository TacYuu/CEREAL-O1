import { getClient, selectTable, rpc } from '../api-client.js';

export async function listAllRewards(){
  return await selectTable({ table:'rewards', columns:'id,name,description,cost,stock,active,category_id', order:{ column:'cost', asc:true }, limit:500 });
}

export async function createReward({ name, description, cost, stock, category }){
  const sb = await getClient();
  const payload = { name, description, cost, stock, active:true };
  if(typeof category !== 'undefined') payload.category_id = category || null;
  const { error } = await sb.from('rewards').insert(payload);
  if(error) throw error; return true;
}

export async function toggleRewardActive(id, active){
  const sb = await getClient();
  const { error } = await sb.from('rewards').update({ active }).eq('id', id);
  if(error) throw error; return true;
}

export async function redeemReward(rewardId){
  // Use RPC to perform atomic redeem with stock decrement and claim record
  const data = await rpc('redeem_reward', { reward_id: rewardId });
  return data;
}

export async function updateRewardStock(id, delta){
  const sb = await getClient();
  // Fetch current
  const { data:rows, error:err1 } = await sb.from('rewards').select('stock').eq('id', id).limit(1).maybeSingle();
  if(err1) throw err1; const current = rows?.stock ?? 0;
  const next = Math.max(0, current + (parseInt(delta||0,10)));
  const { error } = await sb.from('rewards').update({ stock: next }).eq('id', id);
  if(error) throw error; return next;
}

export { selectTable };
