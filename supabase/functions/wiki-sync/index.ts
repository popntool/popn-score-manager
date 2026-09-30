import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json; charset=utf-8"}});

function decodeEntities(value:string){
  const named:Record<string,string>={amp:"&",lt:"<",gt:">",quot:'"',apos:"'",nbsp:" ",dagger:"†",Delta:"Δ",delta:"δ"};
  return value.replace(/&(#x?[0-9a-f]+|[a-zA-Z]+);/g,(_,code)=>{
    if(code[0]==="#"){
      const hex=code[1]?.toLowerCase()==="x",n=parseInt(code.slice(hex?2:1),hex?16:10);
      return Number.isFinite(n)?String.fromCodePoint(n):_;
    }
    return named[code]??_;
  });
}
function textOf(html:string){return decodeEntities(html.replace(/<br\s*\/?\s*>/gi," ").replace(/<[^>]+>/g,"").replace(/\s+/g," ").trim());}
function normalize(value:string){return String(value||"").replace(/[Ⓤⓤ]/g,"").normalize("NFKC").toLowerCase().replace(/\(\s*upper\s*\)/g,"").replace(/[　\s]+/g,"").replace(/[〜～]/g,"~").trim();}
function relaxed(value:string){return normalize(value).replace(/[・･\-‐‑–—~'"“”‘’.,:：!！?？()（）\[\]【】]/g,"");}
function parseDifficulty(text:string){
  const m=text.match(/^(入門|弱|中|強|別格)\(\s*([+-]?\d+(?:\.\d+)?)\s*(?:±\s*(\d+(?:\.\d+)?))?\s*\)$/);
  if(!m)return null;
  return{label:m[1],value:Number(m[2]),sigma:m[3]==null?null:Number(m[3])};
}
function parseRows(html:string,level:number){
  const rows=[] as Array<{genre:string;title:string;chart:string;difficulty_text:string;difficulty_label:string;difficulty_value:number;difficulty_sigma:number|null}>;
  for(const match of html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)){
    const cells=[...match[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(x=>textOf(x[1]));
    if(cells.length<3)continue;
    const difficultyIndex=cells.findIndex(c=>/^(?:入門|弱|中|強|別格)\(/.test(c));
    if(difficultyIndex<0)continue;
    let typeIndex=-1,chart="";
    for(let i=0;i<difficultyIndex;i++){
      const m=cells[i].match(/\((LIGHT|NORMAL|HYPER|EX|N|H)\)\s*$/i);
      if(m){typeIndex=i;chart=({N:"NORMAL",H:"HYPER"} as Record<string,string>)[m[1].toUpperCase()]||m[1].toUpperCase();break;}
    }
    if(typeIndex<0||typeIndex+1>=cells.length)continue;
    const parsed=parseDifficulty(cells[difficultyIndex]);if(!parsed)continue;
    const genre=cells[typeIndex].replace(/\((LIGHT|NORMAL|HYPER|EX|N|H)\)\s*$/i,"").trim();
    rows.push({genre,title:cells[typeIndex+1].trim(),chart,difficulty_text:cells[difficultyIndex],difficulty_label:parsed.label,difficulty_value:parsed.value,difficulty_sigma:parsed.sigma});
  }
  return rows;
}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({ok:false,error:"POST only"},405);
  try{
    const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth=req.headers.get("Authorization");if(!auth)return json({ok:false,error:"ログインが必要です。"},401);
    const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
    const{data:isAdmin,error:adminError}=await userDb.rpc("is_admin");
    if(adminError||!isAdmin)return json({ok:false,error:"管理者権限が必要です。"},403);
    const body=await req.json().catch(()=>({}));const level=Number(body?.level||50);
    if(level!==50)return json({ok:false,error:"現在の試験運用ではLv50のみ同期できます。"},400);
    const sourceUrl=`https://popn.wiki/%E9%9B%A3%E6%98%93%E5%BA%A6%E8%A1%A8/lv${level}`;
    const response=await fetch(sourceUrl,{headers:{"User-Agent":"PopnScoreManager-WikiSync/1.0 (+admin manual sync)"}});
    if(!response.ok)throw new Error(`popn.wiki の取得に失敗しました（HTTP ${response.status}）。`);
    const html=await response.text(),parsed=parseRows(html,level);
    if(parsed.length<5)throw new Error("難易度表を正しく解析できませんでした。ページ構造が変わっている可能性があります。");

    const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
    const chartColumns={LIGHT:"light_level",NORMAL:"normal_level",HYPER:"hyper_level",EX:"ex_level"} as const;
    const candidates:any[]=[];
    for(const chart of [...new Set(parsed.map(x=>x.chart))]){
      const column=chartColumns[chart as keyof typeof chartColumns];if(!column)continue;
      const{data,error}=await service.from("songs").select(`id,genre,title,${column}`).eq(column,level);
      if(error)throw error;candidates.push(...(data||[]).map(x=>({...x,chart})));
    }
    const matched:any[]=[],unmatched:any[]=[];
    for(const row of parsed){
      const pool=candidates.filter(x=>x.chart===row.chart);
      const titleKey=normalize(row.title),genreKey=normalize(row.genre);
      let hits=pool.filter(x=>normalize(x.title)===titleKey&&normalize(x.genre)===genreKey);
      if(hits.length!==1)hits=pool.filter(x=>normalize(x.title)===titleKey);
      if(hits.length!==1){const relaxedTitle=relaxed(row.title);hits=pool.filter(x=>relaxed(x.title)===relaxedTitle);}
      if(hits.length===1){matched.push({...row,song_id:hits[0].id});}else unmatched.push({genre:row.genre,title:row.title,chart:row.chart,difficulty:row.difficulty_text,candidates:hits.length});
    }
    if(matched.length){
      const now=new Date().toISOString();
      const payload=matched.map(x=>({song_id:x.song_id,chart:x.chart,level,difficulty_text:x.difficulty_text,difficulty_label:x.difficulty_label,difficulty_value:x.difficulty_value,difficulty_sigma:x.difficulty_sigma,source_url:sourceUrl,synced_at:now}));
      const{error}=await service.from("song_wiki_difficulties").upsert(payload,{onConflict:"song_id,chart"});if(error)throw error;
    }
    return json({ok:true,level,source_url:sourceUrl,parsed:parsed.length,matched:matched.length,unmatched_count:unmatched.length,unmatched});
  }catch(error){console.error(error);return json({ok:false,error:error instanceof Error?error.message:String(error)},500);}
});
