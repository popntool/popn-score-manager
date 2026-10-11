import{requireDb}from"./supabase.js";
const halfSpace=value=>String(value??"").replaceAll("　"," ");
export async function importSongMaster(file){const client=requireDb(),lines=(await file.text()).replace(/^\ufeff/,"").split(/\r?\n/).filter(Boolean);if(lines.length<2)throw new Error("曲マスターデータが空です。");const hasVersion=lines[0].split("|").some(x=>["カテゴリ","登場バージョン"].includes(x.trim())),records=lines.slice(1).map(line=>{const values=line.split("|").map(halfSpace),[master_key,banner_url,genre,title,artist]=values,version_slug=hasVersion?values[5]:"",offset=hasVersion?6:5,[light,normal,hyper,ex]=values.slice(offset,offset+4),level=v=>/^\d{1,2}$/.test(v)?Number(v):null;return{master_key,banner_url,genre,title,artist,version_slug,light_level:level(light),normal_level:level(normal),hyper_level:level(hyper),ex_level:level(ex)};}).filter(x=>x.master_key&&x.genre&&x.title&&x.artist);let imported=0;for(let i=0;i<records.length;i+=500){const{data,error}=await client.rpc("import_song_master_v2",{p_records:records.slice(i,i+500)});if(error)throw error;imported+=Number(data)||0;}const{error:mergeError}=await client.rpc("merge_song_requests_into_master");if(mergeError)throw mergeError;return imported;}
export async function downloadSongMaster(){
 const client=requireDb(),rows=[],wikiRows=[];
 const {data:versions,error:versionsError}=await client.from("game_versions").select("id,slug");
 if(versionsError)throw versionsError;
 const versionSlugs=new Map((versions||[]).map(v=>[v.id,v.slug||""]));
 for(let from=0;;from+=1000){
  const{data,error}=await client.from("songs").select("id,master_key,banner_url,genre,title,artist,light_level,normal_level,hyper_level,ex_level,version_id").order("title").range(from,from+999);
  if(error)throw error;
  rows.push(...(data||[]));
  if(!data||data.length<1000)break;
 }
 for(let from=0;;from+=1000){
  const{data,error}=await client.from("song_wiki_difficulties").select("song_id,chart,difficulty_text").order("song_id").range(from,from+999);
  if(error){
   if(["42P01","PGRST205"].includes(String(error.code||"")))break;
   throw error;
  }
  wikiRows.push(...(data||[]));
  if(!data||data.length<1000)break;
 }
 const wikiMap=new Map(wikiRows.map(x=>[`${x.song_id}|${String(x.chart||"").toUpperCase()}`,x.difficulty_text||""]));
 const wiki=(songId,chart)=>wikiMap.get(`${songId}|${chart}`)||"";
 const csv=v=>{const text=String(v??"").replace(/\r?\n/g," ");return /[",\r\n]/.test(text)?`"${text.replaceAll('"','""')}"`:text;};
 const level=v=>v??"";
 const header=["曲ID","バナーURL","ジャンル名","曲名","アーティスト","カテゴリ","LIGHT","NORMAL","HYPER","EX","Wiki難易度 LIGHT","Wiki難易度 NORMAL","Wiki難易度 HYPER","Wiki難易度 EX"];
 const lines=[header,...rows.map(x=>[x.master_key,x.banner_url,x.genre,x.title,x.artist,versionSlugs.get(x.version_id)||"",level(x.light_level),level(x.normal_level),level(x.hyper_level),level(x.ex_level),wiki(x.id,"LIGHT"),wiki(x.id,"NORMAL"),wiki(x.id,"HYPER"),wiki(x.id,"EX")])].map(row=>row.map(csv).join(","));
 const text=lines.join("\r\n"),blob=new Blob(["\ufeff",text],{type:"text/csv;charset=utf-8"}),url=URL.createObjectURL(blob),link=document.createElement("a");
 link.href=url;link.download=`popn_song_master_${new Date().toISOString().slice(0,10).replaceAll("-","")}.csv`;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);return rows.length;
}
