import{requireDb}from"./supabase.js";

export async function loadMyScores(userId){if(!userId)return[];const client=requireDb();const{data,error}=await client.from("user_scores").select("id,score,medal_code,updated_at,songs!inner(id,master_key,level,genre,title,artist,chart,banner_url)").eq("user_id",userId).order("updated_at",{ascending:false}).limit(5000);if(error)throw error;return(data||[]).map(row=>({...row,...row.songs}));}
export async function saveScore(songId,score,medalCode){const client=requireDb();const{data:{user}}=await client.auth.getUser();if(!user)throw new Error("ログインしてください。");const{error}=await client.from("user_scores").upsert({user_id:user.id,song_id:songId,score:Math.max(0,Math.min(100000,Number(score)||0)),medal_code:medalCode||"none",rank_code:"none",source:"manual"},{onConflict:"user_id,song_id"});if(error)throw error;}
export async function syncScores(records){const client=requireDb();const{data,error}=await client.rpc("sync_my_scores",{p_records:records});if(error)throw error;return data?.[0]||{saved:0,unmatched:records.length};}

