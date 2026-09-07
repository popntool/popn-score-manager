/* pop'n music スコア同期 v2.0.0
 * e-amusementへログインし、曲データのレベル別ページでConsoleから実行してください。
 * レベル別一覧で全譜面を集め、曲詳細から「歴代」と「VERSION（今作）」を取得します。
 */
(async()=>{
  'use strict';
  const RETURN_URL='https://popntool.github.io/popn-score-manager/';
  const MIN_LV=1,MAX_LV=50,LIST_CONCURRENCY=8,DETAIL_CONCURRENCY=10,MAX_PAGE=200;
  if(location.hostname!=='p.eagate.573.jp'){alert('e-amusementの曲データページで実行してください。');return;}
  if(window.__POPN_SCORE_SYNC_RUNNING__){alert('同期処理は実行中です。');return;}
  window.__POPN_SCORE_SYNC_RUNNING__=true;
  const state={cancelled:false,pages:0,records:[],started:Date.now()};
  const box=document.createElement('div');
  Object.assign(box.style,{position:'fixed',top:'12px',right:'12px',zIndex:2147483647,width:'min(400px,calc(100vw - 24px))',padding:'14px',border:'3px solid #334b93',borderRadius:'14px',background:'#fff9df',color:'#17244d',font:'bold 14px/1.5 sans-serif',boxShadow:'0 6px 24px #0006'});
  box.innerHTML='<b>ポップン スコア同期</b><div data-status>準備中…</div><progress max="50" value="0" style="width:100%"></progress><button style="margin-top:8px">中止</button>';
  document.body.appendChild(box);
  const status=box.querySelector('[data-status]'),progress=box.querySelector('progress'),cancel=box.querySelector('button');
  cancel.onclick=()=>{state.cancelled=true;cancel.disabled=true;};
  const clean=v=>String(v??'').replace(/\u00a0/g,' ').replace(/[\t\r\n ]+/g,' ').trim();
  const normalize=v=>clean(v).normalize('NFKC').replace(/[\u00AD\u200B-\u200D\u2060\uFEFF]/g,'').toLocaleLowerCase('ja-JP');
  async function masterKey({genre,title,artist}){const source=[normalize(genre),normalize(title),normalize(artist)].join('|');const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(source));return [...new Uint8Array(bytes)].map(v=>v.toString(16).padStart(2,'0')).join('');}
  function code(img,prefix){const src=img?.getAttribute('src')||'';const file=src.split('/').pop()?.split('?')[0]||'';return file.replace(/\.[^.]+$/,'').replace(new RegExp(`^${prefix}(?:_big)?_`,'i'),'');}
  function number(text){const value=clean(text);return /^\d{1,6}$/.test(value)?Number(value):0;}
  function listUrl(lv,page){const u=new URL('/game/popn/popn29/playdata/mu_lv.html',location.origin);u.search=new URLSearchParams({page:String(page),version:'-1',bemani:'0',category:'0',keyword:'',sort:'none',lv:String(lv)});return u;}
  async function getDoc(url,label){const r=await fetch(url,{credentials:'include',cache:'no-store'});if(!r.ok)throw new Error(`${label}: HTTP ${r.status}`);const text=await r.text();if(/ログインしてください|コースへの加入が必要/.test(text))throw new Error('ログイン状態を確認してください。');return new DOMParser().parseFromString(text,'text/html');}
  async function parseList(doc){
    const rows=[],anchors=[...doc.querySelectorAll('a[href*="mu_detail.html"]')].filter(a=>/[?&]no=/.test(a.getAttribute('href')||''));
    for(const a of anchors){
      const li=a.closest('li');if(!li)continue;const d=[...li.children].filter(e=>e.tagName==='DIV');if(d.length<4)continue;
      const info=[...d[0].querySelectorAll('p')].map(p=>clean(p.textContent));
      const item={level:Number(clean(d[2].textContent)),genre:info[0]||'',title:clean(a.textContent),artist:info[1]||'',chart:clean(d[1].textContent).toUpperCase(),detail_url:new URL(a.getAttribute('href'),location.origin).href};
      if(!item.title||!item.genre||!item.artist||!['LIGHT','NORMAL','HYPER','EX'].includes(item.chart)||!Number.isFinite(item.level))continue;
      rows.push({master_key:await masterKey(item),...item});
    }
    return {rows,signature:anchors.map(a=>a.getAttribute('href')).sort().join('\n')};
  }
  async function scanLevel(lv){const seen=new Set();for(let page=0;page<MAX_PAGE&&!state.cancelled;page++){const parsed=await parseList(await getDoc(listUrl(lv,page),`Lv.${lv} page=${page}`));if(!parsed.rows.length||seen.has(parsed.signature))break;seen.add(parsed.signature);state.records.push(...parsed.rows);state.pages++;}}
  function parseDetail(doc,detailUrl){
    const result=new Map(),ids={LIGHT:'light',NORMAL:'normal',HYPER:'hyper',EX:'ex'};
    for(const [chart,id] of Object.entries(ids)){
      const section=doc.querySelector(`#${id}`);if(!section)continue;const tables=[...section.querySelectorAll('table')];if(tables.length<2)continue;
      const historyRow=tables[0].querySelector('tr.score:nth-of-type(2)')||tables[0].querySelectorAll('tr.score')[1];
      const versionRow=tables[1].querySelector('tr.score:nth-of-type(2)')||tables[1].querySelectorAll('tr.score')[1];
      const images=[...(historyRow?.querySelectorAll('img')||[])];
      result.set(`${detailUrl}|${chart}`,{score:number(historyRow?.querySelector('td.play_value')?.textContent),version_score:number(versionRow?.querySelector('td.play_value')?.textContent),medal_code:code(images.find(i=>/meda_/i.test(i.getAttribute('src')||'')),'meda')||'none',rank_code:code(images.find(i=>/rank_/i.test(i.getAttribute('src')||'')),'rank')||'none'});
    }
    return result;
  }
  async function mapLimit(items,limit,worker,onDone){let cursor=0,done=0;const out=new Array(items.length);await Promise.all(Array.from({length:Math.min(limit,items.length)},async()=>{while(!state.cancelled){const index=cursor++;if(index>=items.length)return;out[index]=await worker(items[index],index);done++;onDone?.(done,items.length);}}));return out;}
  function toBase64(bytes){let binary='';for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));return btoa(binary);}
  const levels=Array.from({length:MAX_LV-MIN_LV+1},(_,i)=>MIN_LV+i);let cursor=0,done=0;
  try{
    await Promise.all(Array.from({length:LIST_CONCURRENCY},async()=>{while(!state.cancelled){const i=cursor++;if(i>=levels.length)return;await scanLevel(levels[i]);done++;progress.value=done;status.textContent=`一覧 ${done}/50レベル・${state.pages}ページ・${state.records.length}譜面`;}}));
    if(state.cancelled)throw new Error('中止しました。');
    const base=[...new Map(state.records.map(r=>[`${r.master_key}|${r.chart}`,r])).values()];
    const detailUrls=[...new Set(base.map(r=>r.detail_url))];progress.max=detailUrls.length;progress.value=0;
    const parsed=await mapLimit(detailUrls,DETAIL_CONCURRENCY,async url=>parseDetail(await getDoc(url,'曲詳細'),url),(count,total)=>{progress.value=count;status.textContent=`曲詳細 ${count}/${total}・歴代/今作スコアを取得中`;});
    if(state.cancelled)throw new Error('中止しました。');
    const details=new Map();for(const map of parsed)for(const [key,value] of map)details.set(key,value);
    const rows=base.map(row=>({...row,...details.get(`${row.detail_url}|${row.chart}`)})).filter(row=>Number(row.score)>0).map(({detail_url,...row})=>row);
    status.textContent=`${rows.length}譜面を圧縮中…`;
    const raw=new TextEncoder().encode(JSON.stringify({type:'POPN_SCORE_SYNC',version:2,records:rows}));
    const compressed=new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    status.textContent=`取得完了：${rows.length}譜面。サイトへ戻ります…`;
    location.href=RETURN_URL+'#popn-sync-gzip='+encodeURIComponent(toBase64(compressed));
  }catch(e){status.textContent=`エラー：${e?.message||e}`;cancel.textContent='閉じる';cancel.disabled=false;cancel.onclick=()=>box.remove();console.error(e);window.__POPN_SCORE_SYNC_RUNNING__=false;}
})();
