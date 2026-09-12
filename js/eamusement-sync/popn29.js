/* pop'n music スコア同期 v2.8.5
 * e-amusementへログインし、同期用ブックマークから実行してください。
 * 実行時に「レベル範囲」または「バージョン」を選択して同期します。
 */
(async()=>{
  'use strict';
  const RETURN_URL='https://popntool.github.io/popn-score-manager/';
  const LIST_CONCURRENCY=16,DETAIL_CONCURRENCY=32,MAX_PAGE=200;
  const VERSION_OPTIONS=[
    ['ALL','-1'],["pop'n 家庭用",'0'],["pop'n music",'1'],["pop'n music 2",'2'],["pop'n music 3",'3'],["pop'n music 4",'4'],["pop'n music 5",'5'],["pop'n music 6",'6'],["pop'n music 7",'7'],["pop'n music 8",'8'],["pop'n music 9",'9'],["pop'n music 10",'10'],["pop'n music 11",'11'],["pop'n music 12 いろは",'12'],["pop'n music 13 カーニバル",'13'],["pop'n music 14 FEVER！",'14'],["pop'n music 15 ADVENTURE",'15'],["pop'n music 16 PARTY♪",'16'],["pop'n music 17 THE MOVIE",'17'],["pop'n music 18 せんごく列伝",'18'],["pop'n music 19 TUNE STREET",'19'],["pop'n music 20 fantasia",'20'],["pop'n music Sunny Park",'21'],["pop'n music ラピストリア",'22'],["pop'n music éclale",'23'],["pop'n music うさぎと猫と少年の夢",'24'],["pop'n music peace",'25'],["pop'n music 解明リドルズ",'26'],["pop'n music UniLab",'27'],["pop'n music Jam&Fizz",'28'],["pop'n music High☆Cheers!!",'29'],['BEMANI','BEMANI']
  ];
  if(location.hostname!=='p.eagate.573.jp'){alert('e-amusementの曲データページで実行してください。');return;}
  if(window.__POPN_SCORE_SYNC_RUNNING__){alert('同期処理は実行中です。');return;}
  window.__POPN_SCORE_SYNC_RUNNING__=true;

  const state={cancelled:false,pages:0,records:[],started:Date.now()};
  const box=document.createElement('div');
  Object.assign(box.style,{position:'fixed',top:'12px',right:'12px',zIndex:2147483647,width:'min(430px,calc(100vw - 24px))',padding:'14px',border:'3px solid #334b93',borderRadius:'14px',background:'#fff9df',color:'#17244d',fontFamily:'Arial, "Noto Sans JP", "Yu Gothic", Meiryo, sans-serif',fontSize:'14px',fontWeight:'700',lineHeight:'1.5',boxShadow:'0 6px 24px #0006'});
  box.className='popn-score-sync-box';
  const style=document.createElement('style');
  style.textContent='.popn-score-sync-box,.popn-score-sync-box *{font-family:Arial,"Noto Sans JP","Yu Gothic",Meiryo,sans-serif;box-sizing:border-box}.popn-score-sync-box button,.popn-score-sync-box select,.popn-score-sync-box input{font:inherit}.popn-score-sync-box button{font-weight:700}';
  document.head.appendChild(style);
  document.body.appendChild(box);

  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const clean=v=>String(v??'').replace(/\u00a0/g,' ').replace(/[\t\r\n ]+/g,' ').trim();
  const normalize=v=>clean(v).normalize('NFKC').replace(/[\u00AD\u200B-\u200D\u2060\uFEFF]/g,'').toLocaleLowerCase('ja-JP');
  async function masterKey({genre,title,artist}){const source=[normalize(genre),normalize(title),normalize(artist)].join('|');const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(source));return [...new Uint8Array(bytes)].map(v=>v.toString(16).padStart(2,'0')).join('');}
  function code(img,prefix){const src=img?.getAttribute('src')||'';const file=src.split('/').pop()?.split('?')[0]||'';return file.replace(/\.[^.]+$/,'').replace(new RegExp(`^${prefix}(?:_big)?_`,'i'),'');}
  function number(text){const match=clean(text).replace(/,/g,'').match(/\d{1,6}/);return match?Number(match[0]):0;}
  async function getDoc(url,label,retry=2){for(let attempt=0;;attempt++){const r=await fetch(url,{credentials:'include',cache:'no-store'});if(r.ok){const text=await r.text();if(/ログインしてください|コースへの加入が必要/.test(text))throw new Error('ログイン状態を確認してください。');return new DOMParser().parseFromString(text,'text/html');}if(attempt>=retry||![429,500,502,503,504].includes(r.status))throw new Error(`${label}: HTTP ${r.status}`);await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));}}

  function chooseScope(){
    const levelOptions=Array.from({length:50},(_,i)=>`<option value="${i+1}">${i+1}</option>`).join('');
    const versions=VERSION_OPTIONS.map(([name,value])=>`<option value="${esc(value)}">${esc(name)}</option>`).join('');
    box.innerHTML=`<b style="font-size:16px">ポップン スコア同期</b><div style="margin:8px 0 10px;font-weight:normal">同期するレベルかバージョンを選択してください。</div>
      <label style="display:flex;align-items:center;gap:8px;margin:8px 0"><input type="radio" name="popn-sync-mode" value="level" checked>レベル
        <select data-min style="margin-left:auto;padding:4px">${levelOptions}</select><span>～</span><select data-max style="padding:4px">${levelOptions}</select>
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin:8px 0"><input type="radio" name="popn-sync-mode" value="version">バージョン
        <select data-version style="margin-left:auto;max-width:260px;padding:4px">${versions}</select>
      </label>
      <div style="display:flex;align-items:center;width:100%;gap:8px;margin-top:12px"><button data-cancel type="button">中止</button><button data-start type="button" style="margin-left:auto">同期する</button></div>`;
    const minSel=box.querySelector('[data-min]'),maxSel=box.querySelector('[data-max]'),versionSel=box.querySelector('[data-version]');
    minSel.value='1';maxSel.value='50';
    const setMode=mode=>{box.querySelector(`input[value="${mode}"]`).checked=true;};
    const rebuildMax=()=>{const min=Number(minSel.value),previous=Math.max(min,Number(maxSel.value)||min);maxSel.innerHTML=Array.from({length:51-min},(_,i)=>{const v=min+i;return `<option value="${v}" ${v===previous?'selected':''}>${v}</option>`;}).join('');};
    minSel.addEventListener('change',()=>{setMode('level');rebuildMax();});
    maxSel.addEventListener('change',()=>setMode('level'));
    versionSel.addEventListener('change',()=>setMode('version'));
    return new Promise(resolve=>{
      box.querySelector('[data-cancel]').onclick=()=>{state.cancelled=true;box.remove();window.__POPN_SCORE_SYNC_RUNNING__=false;resolve(null);};
      box.querySelector('[data-start]').onclick=()=>{const mode=box.querySelector('input[name="popn-sync-mode"]:checked')?.value||'level';resolve(mode==='level'?{mode,min:Number(minSel.value),max:Number(maxSel.value)}:{mode,value:versionSel.value});};
    });
  }

  function listUrl(target,page){
    const isLevel=target.kind==='level';
    // レベル指定は mu_lv.html、バージョン/BEMANI指定は公式画面と同じ mu_top.html を使う。
    const u=new URL(`/game/popn/popn29/playdata/${isLevel?'mu_lv':'mu_top'}.html`,location.origin);
    const params={
      page:String(page),
      version:String(target.version??-1),
      bemani:String(target.bemani??0),
      category:'0',
      keyword:'',
      sort:isLevel?'none':'music'
    };
    if(isLevel)params.lv=String(target.lv);
    else params.sort_type='up';
    u.search=new URLSearchParams(params);
    return u;
  }

  function historyCell(cell){
    const images=[...(cell?.querySelectorAll('img')||[])];
    const text=clean(cell?.querySelector('.play_value')?.textContent||cell?.querySelector('p')?.textContent||cell?.textContent||'');
    const match=text.replace(/,/g,'').match(/(?:^|\D)(\d{1,6})(?:\D|$)/);
    return {
      score:match?Math.min(100000,Number(match[1])||0):0,
      medal_code:code(images.find(i=>/meda_/i.test(i.getAttribute('src')||'')),'meda')||'none',
      rank_code:code(images.find(i=>/rank_/i.test(i.getAttribute('src')||'')),'rank')||'none'
    };
  }

  async function parseList(doc){
    const anchors=[...doc.querySelectorAll('a[href*="mu_detail.html"]')].filter(a=>/[?&]no=/.test(a.getAttribute('href')||''));
    const items=[];
    const seenLi=new Set();
    for(const a of anchors){
      const li=a.closest('li');if(!li||seenLi.has(li))continue;seenLi.add(li);
      const d=[...li.children].filter(e=>e.tagName==='DIV');
      const info=[...d[0]?.querySelectorAll('p')||[]].map(p=>clean(p.textContent));
      const base={genre:info[0]||'',title:clean(a.textContent),artist:info[1]||'',detail_url:new URL(a.getAttribute('href'),location.origin).href};
      if(!base.title||!base.genre||!base.artist)continue;

      // バージョン/BEMANI一覧(mu_top.html)は、1曲につき LIGHT/NORMAL/HYPER/EX の4セルを持つ。
      // 各セルの medal/rank/score をそのまま歴代データとして取得する。
      // mu_top.html は曲情報の直後に「でっかポップ君」列があり、その後に
      // LIGHT / NORMAL / HYPER / EX の4列が並ぶ。末尾4セルだけを譜面として扱う。
      const songCells=d.slice(-4);
      if(d.length>=6&&songCells.length===4&&songCells.every(cell=>cell.querySelector('img[src*="meda_"]'))){
        for(const [index,chart] of ['LIGHT','NORMAL','HYPER','EX'].entries()){
          const history=historyCell(songCells[index]);
          items.push({...base,level:0,chart,...history});
        }
        continue;
      }

      // レベル一覧(mu_lv.html)は従来どおり1行=1譜面。
      if(d.length<4)continue;
      const history=historyCell(d[3]);
      const item={...base,level:Number(clean(d[2].textContent)),chart:clean(d[1].textContent).toUpperCase(),...history};
      if(!['LIGHT','NORMAL','HYPER','EX'].includes(item.chart)||!Number.isFinite(item.level))continue;
      items.push(item);
    }
    const keys=await Promise.all(items.map(masterKey));
    return {rows:items.map((item,i)=>({master_key:keys[i],...item})),signature:anchors.map(a=>a.getAttribute('href')).sort().join('\n')};
  }

  async function scanTarget(target,onPage){const seen=new Set();for(let page=0;page<MAX_PAGE&&!state.cancelled;page++){const parsed=await parseList(await getDoc(listUrl(target,page),`${target.label} page=${page}`));if(!parsed.rows.length||seen.has(parsed.signature))break;seen.add(parsed.signature);state.records.push(...parsed.rows);state.pages++;onPage?.();}}
  function parseDetail(doc){const result=new Map(),ids={LIGHT:'light',NORMAL:'normal',HYPER:'hyper',EX:'ex'};for(const [chart,id] of Object.entries(ids)){const section=doc.querySelector(`#${id}`);if(!section)continue;const tables=[...section.querySelectorAll('table')];if(tables.length<2)continue;const versionTable=tables.find(table=>/VERSION/i.test(table.previousElementSibling?.textContent||''))||tables[1],versionRow=versionTable?.querySelector('tr.score td.play_value')?.closest('tr'),counts={play:0,clear:0,full_combo:0,perfect:0};for(const tr of versionTable?.querySelectorAll('tr')||[]){const label=clean(tr.querySelector('th,td')?.textContent).replace(/[ 　]/g,''),value=number(tr.querySelector('td.play_value')?.textContent||tr.lastElementChild?.textContent);if(/PERFECT回数/i.test(label))counts.perfect=value;else if(/FULLCOMBO回数/i.test(label))counts.full_combo=value;else if(/クリア回数/.test(label))counts.clear=value;else if(/プレー回数/.test(label))counts.play=value;}const current_clear_status=counts.perfect>0?'perfect':counts.full_combo>0?'full_combo':counts.clear>0?'clear':'failed';result.set(chart,{version_score:number(versionRow?.querySelector('td.play_value')?.textContent),current_clear_status,version_counts:counts});}return result;}
  async function mapLimit(items,limit,worker,onDone){let cursor=0,done=0;const out=new Array(items.length);await Promise.all(Array.from({length:Math.min(limit,items.length)},async()=>{while(!state.cancelled){const index=cursor++;if(index>=items.length)return;out[index]=await worker(items[index],index);done++;onDone?.(done,items.length);}}));return out;}
  function toBase64(bytes){let binary='';for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));return btoa(binary);}

  try{
    const scope=await chooseScope();if(!scope)return;
    let targets;
    if(scope.mode==='level')targets=Array.from({length:scope.max-scope.min+1},(_,i)=>({kind:'level',lv:scope.min+i,version:-1,bemani:0,label:`Lv.${scope.min+i}`}));
    else if(scope.value==='BEMANI')targets=Array.from({length:10},(_,i)=>({kind:'filter',version:-1,bemani:i+1,label:`BEMANI ${i+1}`}));
    else targets=[{kind:'filter',version:Number(scope.value),bemani:0,label:VERSION_OPTIONS.find(([,value])=>value===scope.value)?.[0]||`version=${scope.value}`}];

    box.innerHTML='<b>ポップン スコア同期</b><div data-status>一覧を取得中…</div><progress value="0" style="width:100%"></progress><button data-cancel style="margin-top:8px">中止</button>';
    const status=box.querySelector('[data-status]'),progress=box.querySelector('progress'),cancel=box.querySelector('[data-cancel]');
    cancel.onclick=()=>{state.cancelled=true;cancel.disabled=true;};
    progress.max=Math.max(1,targets.length);
    let cursor=0,done=0;
    await Promise.all(Array.from({length:Math.min(LIST_CONCURRENCY,targets.length)},async()=>{while(!state.cancelled){const i=cursor++;if(i>=targets.length)return;await scanTarget(targets[i],()=>{status.textContent=`一覧 ${done}/${targets.length}カテゴリ・${state.pages}ページ・${state.records.length}譜面`;});done++;progress.value=done;status.textContent=`一覧 ${done}/${targets.length}カテゴリ・${state.pages}ページ・${state.records.length}譜面`;}}));
    if(state.cancelled)throw new Error('中止しました。');

    const base=[...new Map(state.records.map(r=>[`${r.master_key}|${r.chart}`,r])).values()];
    const detailGroupMap=new Map();
    for(const row of base){const url=new URL(row.detail_url);url.hash='';const no=url.searchParams.get('no'),detailKey=no?`${url.pathname}?no=${no}`:url.href;let group=detailGroupMap.get(detailKey);if(!group){group={url:url.href,rows:[]};detailGroupMap.set(detailKey,group);}group.rows.push(row);}
    const allDetailGroups=[...detailGroupMap.values()];
    // レベル範囲同期では一覧の歴代スコアを使って未プレー曲の詳細取得を省略する。
    // バージョン/BEMANI同期では一覧側で個人スコア欄が空になるページがあるため、
    // 対象曲の詳細ページをすべて確認して今作スコア・今作クリア状況を取得する。
    const detailGroups=scope.mode==='level'
      ? allDetailGroups.filter(group=>group.rows.some(row=>Number(row.score)>0))
      : allDetailGroups;
    progress.max=Math.max(1,detailGroups.length);progress.value=0;
    status.textContent=scope.mode==='level'
      ? `一覧から${base.filter(row=>Number(row.score)>0).length}譜面を確認・詳細取得 ${detailGroups.length}/${allDetailGroups.length}曲`
      : `対象${base.length}譜面を確認・詳細取得 ${detailGroups.length}曲`;
    const parsed=await mapLimit(detailGroups,DETAIL_CONCURRENCY,async group=>({rows:group.rows,values:parseDetail(await getDoc(group.url,'曲詳細'))}),(count,total)=>{progress.value=count;status.textContent=`曲詳細 ${count}/${total}曲・今作スコアを取得中`;});
    if(state.cancelled)throw new Error('中止しました。');
    const details=new Map();for(const group of parsed)for(const row of group.rows){const value=group.values.get(row.chart);if(value)details.set(`${row.master_key}|${row.chart}`,value);}
    const rows=base.map(row=>{const detail=details.get(`${row.master_key}|${row.chart}`)||{};return {...row,version_score:Number(detail.version_score)||0,current_clear_status:detail.current_clear_status||'failed'};})
      .filter(row=>Number(row.score)>0||row.medal_code!=='none'||row.rank_code!=='none'||Number(row.version_score)>0||row.current_clear_status!=='failed')
      .map(({detail_url,...row})=>row);
    status.textContent=`${rows.length}譜面を圧縮中…`;
    const raw=new TextEncoder().encode(JSON.stringify({type:'POPN_SCORE_SYNC',version:3,records:rows})),compressed=new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    status.textContent=`取得完了：${rows.length}譜面。サイトへ戻ります…`;
    location.href=RETURN_URL+'#popn-sync-gzip='+encodeURIComponent(toBase64(compressed));
  }catch(e){const status=box.querySelector('[data-status]');if(status)status.textContent=`エラー：${e?.message||e}`;const cancel=box.querySelector('[data-cancel]');if(cancel){cancel.textContent='閉じる';cancel.disabled=false;cancel.onclick=()=>box.remove();}console.error(e);window.__POPN_SCORE_SYNC_RUNNING__=false;}
})();
