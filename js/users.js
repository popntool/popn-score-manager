import{requireDb}from"./supabase.js";

export async function loadUsers(search=""){const client=requireDb();const{data,error}=await client.rpc("list_user_summaries",{p_search:String(search||"").trim()});if(error)throw error;return data||[];}

