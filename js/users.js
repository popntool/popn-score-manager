import{requireDb}from"./supabase.js";

export async function loadUsers(search="",gameVersionId=null){const client=requireDb();const{data,error}=await client.rpc("list_user_summaries_v31",{p_search:String(search||"").trim(),p_game_version_id:gameVersionId});if(error)throw error;return data||[];}

