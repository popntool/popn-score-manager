import{requireDb}from"./supabase.js";

export async function submitSongRequest(values){const client=requireDb(),{data,error}=await client.rpc("submit_song_request_v2",{p_genre:values.genre.trim(),p_title:values.title.trim(),p_artist:values.artist.trim(),p_chart:values.chart,p_level:Number(values.level),p_note:values.note.trim()});if(error)throw error;return data;}
export async function submitFeedback(values){const message=String(values.message||"").trim();if(!message)throw new Error("内容を入力してください。");const client=requireDb();const{error}=await client.from("feedback_reports").insert({category:values.category,message,page_url:location.href,user_agent:navigator.userAgent});if(error)throw error;}
