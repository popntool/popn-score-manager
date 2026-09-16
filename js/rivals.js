import{requireDb}from'./supabase.js';
const db=()=>requireDb();
export async function loadRivals(){const{data,error}=await db().rpc('my_rivals');if(error)throw error;return data||[];}
export async function toggleRival(id){const{data,error}=await db().rpc('toggle_my_rival',{p_target:id});if(error)throw error;return Boolean(data);}
export async function saveVisibility(settings){const{error}=await db().rpc('update_my_visibility',{p_poptomo_id:settings.poptomo_id||null,p_poptomo_public:settings.poptomo_public,p_highest_clear_public:settings.highest_clear_public,p_popn_class_public:settings.popn_class_public,p_psr_public:settings.psr_public,p_rival_scores_public:settings.rival_scores_public,p_rival_medals_public:settings.rival_medals_public});if(error)throw error;}
export async function rivalSongScores(songId,chart){const{data,error}=await db().rpc('rival_song_scores',{p_song_id:songId,p_chart:chart});if(error)throw error;return data||[];}
