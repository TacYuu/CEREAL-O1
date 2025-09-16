import { getClient, selectTable, rpc } from '../api-client.js';

export async function listAllRewards(){
  return await selectTable({ table:'rewards', columns:'id,name,description,cost,stock,active,category_id', order:{ column:'cost', asc:true }, limit:500 });
}

export async function createReward({ name, description, cost, stock, category }){
  const sb = await getClient();
  const { error } = await sb.from('rewards').insert({ name, description, cost, stock, active:true, category_id: category||null });
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

export { selectTable };
