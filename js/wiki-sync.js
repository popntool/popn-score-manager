import{requireDb}from"./supabase.js";

const detailCache=new Map();
const keyOf=(songId,chart)=>`${songId}|${String(chart||"").toUpperCase()}`;

export function clearWikiDifficultyCache(){detailCache.clear();}

export async function loadWikiDifficulty(songId,chart){
  const key=keyOf(songId,chart);
  if(detailCache.has(key))return detailCache.get(key);
  const db=requireDb();
  const{data,error}=await db.from("song_wiki_difficulties")
    .select("song_id,chart,level,difficulty_text,difficulty_label,difficulty_value,difficulty_sigma,source_url,synced_at")
    .eq("song_id",songId).eq("chart",String(chart||"").toUpperCase()).maybeSingle();
  if(error){if(["42P01","PGRST205"].includes(String(error.code||"")))return null;throw error;}
  const value=data||null;detailCache.set(key,value);return value;
}

export async function loadWikiDifficultiesForSongs(songIds){
  const ids=[...new Set((songIds||[]).filter(Boolean))];
  if(!ids.length)return new Map();
  const{data,error}=await requireDb().from("song_wiki_difficulties")
    .select("song_id,chart,level,difficulty_text,difficulty_label,difficulty_value,difficulty_sigma,source_url,synced_at")
    .in("song_id",ids).order("chart");
  if(error){if(["42P01","PGRST205"].includes(String(error.code||"")))return new Map();throw error;}
  const map=new Map();
  for(const row of data||[]){
    if(!map.has(row.song_id))map.set(row.song_id,[]);
    map.get(row.song_id).push(row);
    detailCache.set(keyOf(row.song_id,row.chart),row);
  }
  return map;
}

export async function syncWikiDifficulties(level=50){
  const db=requireDb();
  const{data,error}=await db.functions.invoke("wiki-sync",{body:{level:Number(level)}});
  if(error){
    let message=error.message||String(error);
    try{const body=await error.context?.json?.();if(body?.error)message=body.error;}catch{}
    throw new Error(message);
  }
  if(!data?.ok)throw new Error(data?.error||"wiki同期に失敗しました。");
  clearWikiDifficultyCache();
  return data;
}
