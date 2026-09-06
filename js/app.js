import{isConfigured}from"./supabase.js";
import{currentUser,currentUsername,login,logout,onAuthChange,register}from"./auth.js";
import{importSongMaster,searchSongs}from"./songs.js";
import{loadMyScores,saveScore,syncScores}from"./scores.js";
import{loadUsers}from"./users.js";
import{filterScores,renderScores,renderStats,renderUsers,setTheme,showTab}from"./ui.js";

let scores=[],authMode="login",selectedSong=null;
const $=selector=>document.querySelector(selector);
const wait=(fn,delay=250)=>{let timer;return(...args)=>{clearTimeout(timer);timer=setTimeout(()=>fn(...args),delay);};};

async function refreshAuth(){const user=await currentUser();$("#playerName").textContent=user?await currentUsername(user):"GUEST";$("#authButton").hidden=Boolean(user);$("#logoutButton").hidden=!user;scores=user?await loadMyScores(user.id):[];renderScores(scores);renderStats(scores);}
function applyFilters(){renderScores(filterScores(scores));}
function toggleTheme(){setTheme(document.documentElement.dataset.theme==="dark"?"light":"dark");}
function populateLevels(){const select=$("#levelFilter");for(let level=50;level>=1;level--){const option=document.createElement("option");option.value=String(level);option.textContent=`Lv.${level}`;select.append(option);}}
async function importHash(){const marker="#popn-sync-gzip=";if(!location.hash.startsWith(marker))return;try{const binary=atob(decodeURIComponent(location.hash.slice(marker.length))),bytes=Uint8Array.from(binary,char=>char.charCodeAt(0)),text=await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).text(),payload=JSON.parse(text);if(payload.type!=="POPN_SCORE_SYNC"||!Array.isArray(payload.records))throw new Error("同期データが不正です。");const result=await syncScores(payload.records);history.replaceState(null,"",location.pathname+location.search);alert(`${result.saved}譜面を保存しました。曲マスター未登録：${result.unmatched}譜面`);await refreshAuth();}catch(error){alert(`同期に失敗しました：${error.message||error}`);}}

populateLevels();setTheme(localStorage.getItem("popn-theme")==="dark"?"dark":"light");$("#setupNotice").hidden=isConfigured;
for(const button of document.querySelectorAll("[data-dialog-close]"))button.addEventListener("click",()=>button.closest("dialog").close());
$("#themeButton").addEventListener("click",toggleTheme);$("#settingsThemeButton").addEventListener("click",toggleTheme);
for(const button of document.querySelectorAll(".tabs button"))button.addEventListener("click",async()=>{showTab(button.dataset.tab);if(button.dataset.tab==="users"&&isConfigured){try{renderUsers(await loadUsers($("#userSearchInput").value));}catch(error){alert(error.message||error);}}});
for(const selector of["#searchInput","#chartFilter","#levelFilter","#medalFilter"])$(selector).addEventListener(selector==="#searchInput"?"input":"change",applyFilters);
$("#authButton").addEventListener("click",()=>$("#authDialog").showModal());$("#logoutButton").addEventListener("click",async()=>{await logout();await refreshAuth();});
$("#authModeButton").addEventListener("click",()=>{authMode=authMode==="login"?"register":"login";$("#authTitle").textContent=authMode==="login"?"ログイン":"新規登録";$("#authModeButton").textContent=authMode==="login"?"新規登録へ":"ログインへ";$("#authForm button[type=submit]").textContent=authMode==="login"?"ログイン":"登録";});
$("#authForm").addEventListener("submit",async event=>{event.preventDefault();const form=new FormData(event.currentTarget);try{if(authMode==="login")await login(form.get("username"),form.get("password"));else await register(form.get("username"),form.get("password"));$("#authDialog").close();await refreshAuth();}catch(error){$("#authError").textContent=error.message||error;}});
$("#manualButton").addEventListener("click",()=>$("#manualDialog").showModal());$("#syncHelpButton").addEventListener("click",()=>$("#syncDialog").showModal());
$("#songSearchInput").addEventListener("input",wait(async event=>{selectedSong=null;const box=$("#songSuggestions"),query=event.target.value.trim();if(!query){box.innerHTML="";return;}try{const rows=await searchSongs(query);box.innerHTML=rows.map((row,index)=>`<button type="button" data-index="${index}">${row.title} / ${row.chart} Lv.${row.level}</button>`).join("");box.querySelectorAll("button").forEach(button=>button.addEventListener("click",()=>{selectedSong=rows[Number(button.dataset.index)];$("#songSearchInput").value=`${selectedSong.title} / ${selectedSong.chart} Lv.${selectedSong.level}`;box.innerHTML="";}));}catch(error){box.textContent=error.message||error;}}));
$("#manualForm").addEventListener("submit",async event=>{event.preventDefault();if(!selectedSong){$("#manualError").textContent="曲マスターから譜面を選択してください。";return;}const form=new FormData(event.currentTarget);try{await saveScore(selectedSong.id,form.get("score"),form.get("medal_code"));$("#manualDialog").close();event.target.reset();selectedSong=null;await refreshAuth();}catch(error){$("#manualError").textContent=error.message||error;}});
$("#masterFileInput").addEventListener("change",async event=>{const file=event.target.files?.[0];if(!file)return;try{const count=await importSongMaster(file);alert(`${count}譜面を曲マスターへ登録・更新しました。`);}catch(error){alert(`曲マスター投入に失敗しました：${error.message||error}`);}finally{event.target.value="";}});
$("#userSearchInput").addEventListener("input",wait(async event=>{try{renderUsers(await loadUsers(event.target.value));}catch(error){console.error(error);}},350));
onAuthChange(refreshAuth);await refreshAuth();await importHash();
