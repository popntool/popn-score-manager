import{requireDb}from"./supabase.js";
import{loadScoreCatalog as loadScoreCatalogFresh}from"./scores.js?v=3.3.77";

const DB_NAME="popn-score-manager-cache";
const DB_VERSION=1;
const STORE="score_catalogs";
const CACHE_SCHEMA="v3377";
const MAX_ENTRIES=6;

function openCacheDb(){
 return new Promise((resolve,reject)=>{
  if(!("indexedDB" in window)){reject(new Error("IndexedDB unavailable"));return;}
  const request=indexedDB.open(DB_NAME,DB_VERSION);
  request.onupgradeneeded=()=>{
   const db=request.result;
   if(!db.objectStoreNames.contains(STORE))db.createObjectStore(STORE,{keyPath:"key"});
  };
  request.onsuccess=()=>resolve(request.result);
  request.onerror=()=>reject(request.error||new Error("IndexedDB open failed"));
 });
}
function transactionDone(tx){return new Promise((resolve,reject)=>{tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error||new Error("IndexedDB transaction failed"));tx.onabort=()=>reject(tx.error||new Error("IndexedDB transaction aborted"));});}
async function readCache(key){
 const db=await openCacheDb();
 try{
  const tx=db.transaction(STORE,"readonly"),request=tx.objectStore(STORE).get(key);
  const value=await new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result||null);request.onerror=()=>reject(request.error);});
  await transactionDone(tx);return value;
 }finally{db.close();}
}
async function writeCache(entry){
 const db=await openCacheDb();
 try{
  const tx=db.transaction(STORE,"readwrite"),store=tx.objectStore(STORE);store.put(entry);
  const allRequest=store.getAll();
  const entries=await new Promise((resolve,reject)=>{allRequest.onsuccess=()=>resolve(allRequest.result||[]);allRequest.onerror=()=>reject(allRequest.error);});
  entries.sort((a,b)=>(Number(b.cachedAt)||0)-(Number(a.cachedAt)||0));
  for(const stale of entries.slice(MAX_ENTRIES))store.delete(stale.key);
  await transactionDone(tx);
 }finally{db.close();}
}
async function revisionToken(){
 const{data,error}=await requireDb().rpc("get_score_catalog_revision_v3233");
 if(error)throw error;
 const row=Array.isArray(data)?data[0]:data;
 if(!row)throw new Error("キャッシュ更新番号を取得できませんでした。");
 return `${row.song_revision||0}:${row.game_version_revision||0}:${row.user_score_revision||0}`;
}
function cacheKey(userId,selectedVersion){return `${CACHE_SCHEMA}:${userId}:${selectedVersion?.id||"default"}`;}

async function attachCanonicalPsr(rows,selectedVersion){
 if(!selectedVersion?.id)return rows;
 const{data,error}=await requireDb().rpc("my_psr_values_v3377",{p_game_version_id:selectedVersion.id});
 if(error)throw new Error(`PSR集計を取得できませんでした：${error.message||error}`);
 const byChart=new Map((data||[]).map(item=>[`${item.song_id}|${item.chart}`,item]));
 for(const row of rows){
  const item=byChart.get(`${row.song_id}|${row.chart}`);
  row.psr_calculated=item?Number(item.pop_class):0;
  row.psr_selected=Boolean(item?.selected);
  row.psr_position=item?Number(item.position):0;
  if(item){row.version_score=Number(item.version_score);row.current_clear_status=item.current_clear_status;}
 }
 const total=Number(data?.[0]?.total??0);
 Object.defineProperty(rows,"psrTotal",{value:total,configurable:true});
 Object.defineProperty(rows,"psrCanonical",{value:true,configurable:true});
 return rows;
}
export async function loadScoreCatalogCached(userId,selectedVersion=null){
 if(!userId)return[];
 let revision;
 try{revision=await revisionToken();}catch(error){
  console.warn("Catalog revision check failed; loading fresh data.",error);
  return attachCanonicalPsr(await loadScoreCatalogFresh(userId,selectedVersion),selectedVersion);
 }
 const key=cacheKey(userId,selectedVersion);
 try{
  const cached=await readCache(key);
  if(cached?.revision===revision&&Array.isArray(cached.data))return attachCanonicalPsr(cached.data,selectedVersion);
 }catch(error){console.warn("Catalog cache read failed.",error);}
 const data=await loadScoreCatalogFresh(userId,selectedVersion);
 try{await writeCache({key,revision,cachedAt:Date.now(),data});}catch(error){console.warn("Catalog cache write failed.",error);}
 return attachCanonicalPsr(data,selectedVersion);
}
