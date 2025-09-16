export default function handler(req, res){
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
  if(!url || !anonKey){
    res.status(404).json({ error:'Missing Supabase env vars' });
    return;
  }
  res.setHeader('Cache-Control','no-store');
  res.status(200).json({ url, anonKey });
}
