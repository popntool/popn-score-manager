import{requireDb}from"./supabase.js";

// Public user summaries change far less often than search text. Fetch the version's
// public list once, cache it briefly, and filter username searches locally. This
// avoids a full RPC response for every search keystroke and every tab revisit.
const TTL_MS=5*60_000;
const MAX_ENTRIES=4;
const entries=new Map();
let generation=0;

export function invalidateUserCache(){
 generation++;
 entries.clear();
}

function normalized(value){return String(value||"").trim().toLocaleLowerCase("ja-JP");}

async function loadBaseList(gameVersionId){
 const key=String(gameVersionId||"");
 const cached=entries.get(key);
 if(cached&&cached.expires>Date.now())return cached.promise;
 const token=generation;
 const promise=(async()=>{
   const{data,error}=await requireDb().rpc("list_user_summaries_v31",{
     p_search:"",p_game_version_id:gameVersionId
   });
   if(error)throw error;
   return data||[];
 })();
 entries.set(key,{promise,expires:Date.now()+TTL_MS});
 if(entries.size>MAX_ENTRIES)entries.delete(entries.keys().next().value);
 try{
   const result=await promise;
   if(token!==generation&&entries.get(key)?.promise===promise)entries.delete(key);
   return result;
 }catch(error){
   if(entries.get(key)?.promise===promise)entries.delete(key);
   throw error;
 }
}

export async function loadUsers(search="",gameVersionId=null){
 const rows=await loadBaseList(gameVersionId),query=normalized(search);
 if(!query)return rows;
 return rows.filter(row=>normalized(row.username).includes(query));
}
