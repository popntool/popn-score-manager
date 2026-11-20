import{requireDb}from"./supabase.js";

// Public user summaries change far less often than search text. Fetch the version's
// public list once, cache it briefly, and filter username searches locally. This
// avoids a full RPC response for every search keystroke and every tab revisit.
const TTL_MS=5*60_000;
const MAX_ENTRIES=4;
const RETRY_DELAYS_MS=[700,1600];
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
   // A timed-out RPC may be transient while the database refills invalidated
   // summary caches. Retry only this read-only request; never retry writes.
   for(let attempt=0;;attempt++){
     const{data,error}=await requireDb().rpc("list_user_summaries_v31",{
       p_search:"",p_game_version_id:gameVersionId
     });
     if(!error)return data||[];
     const message=String(error.message||"").toLowerCase();
     const transient=error.code==="57014"||message.includes("statement timeout")||message.includes("canceling statement")||message.includes("timeout");
     if(!transient||attempt>=RETRY_DELAYS_MS.length)throw error;
     await new Promise(resolve=>setTimeout(resolve,RETRY_DELAYS_MS[attempt]));
   }
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

// Refresh invalidated or older-revision summaries without blocking the list.
// Search prioritizes the requested username; the unfiltered list refills gradually.
// A single background worker per version avoids competing writes.
const warmAttempts=new Map();
const warming=new Set();
export function warmMissingUserSummaries(gameVersionId,rows,onUpdated,search=''){
 const version=String(gameVersionId||'');
 const query=String(search||'').trim();
 const key=`${version}|${normalized(query)}`;
 if(!version||!rows.some(r=>Number(r.pop_class)===-1)||warming.has(version))return;
 const maxAttempts=query?12:6;
 const already=warmAttempts.get(key)||0;
 if(already>=maxAttempts)return;
 warming.add(version);
 (async()=>{
  try{
   let count=already;
   while(count<maxAttempts){
    const {data,error}=await requireDb().rpc('refresh_user_summaries_batch_v363',{
      p_search:query,p_game_version_id:gameVersionId
    });
    if(error)throw error;
    count++;warmAttempts.set(key,count);
    if(Number(data)<=0)break;
    entries.delete(version);
    if(typeof onUpdated==='function')await onUpdated();
    await new Promise(resolve=>setTimeout(resolve,300));
   }
  }catch(error){
   console.warn('PSR background refresh failed',error);
   warmAttempts.set(key,maxAttempts);
  }finally{warming.delete(version);}
 })();
}
