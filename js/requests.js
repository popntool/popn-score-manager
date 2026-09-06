import{requireDb}from"./supabase.js";

export async function submitSongRequest(values){const client=requireDb();const{error}=await client.from("song_requests").insert({genre:values.genre.trim(),title:values.title.trim(),artist:values.artist.trim(),chart:values.chart,level:Number(values.level),note:values.note.trim()});if(error)throw error;}
export async function submitFeedback(values){const client=requireDb();const{error}=await client.from("feedback_reports").insert({category:values.category,message:values.message.trim(),page_url:location.href,user_agent:navigator.userAgent});if(error)throw error;}
