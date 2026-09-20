import{requireDb}from"./supabase.js";

// An in-memory cache avoids another request when switching back to the user tab.
// Only current-session public summaries are kept; no persistent storage is used.
const TTL_MS=90_000;
const MAX_ENTRIES=12;
const entries=new Map();
let generation=0;

export function invalidateUserCache(){
 generation++;
 entries.clear();
}

export async function loadUsers(search="",gameVersionId=null){
 const query=String(search||"").trim(),key=JSON.stringify([query,gameVersionId]);
 const cached=entries.get(key);
 if(cached&&cached.expires>Date.now())return cached.promise;
 const token=generation;
 const promise=(async()=>{
   const{data,error}=await requireDb().rpc("list_user_summaries_v31",{
     p_search:query,p_game_version_id:gameVersionId
   });
   if(error)throw error;
   return data||[];
 })();
 entries.set(key,{promise,expires:Date.now()+TTL_MS});
 if(entries.size>MAX_ENTRIES)entries.delete(entries.keys().next().value);
 try{
   const result=await promise;
   // A delayed response must not repopulate a cache that was invalidated meanwhile.
   if(token!==generation&&entries.get(key)?.promise===promise)entries.delete(key);
   return result;
 }catch(error){
   if(entries.get(key)?.promise===promise)entries.delete(key);
   throw error;
 }
}
