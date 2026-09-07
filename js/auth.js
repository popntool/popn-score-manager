import{db,requireDb}from"./supabase.js";

const USERNAME_DOMAIN="users.popn-score-manager.local";
const clean=value=>String(value||"").trim();
async function usernameToEmail(username){const bytes=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(clean(username)));const hex=[...new Uint8Array(bytes)].map(value=>value.toString(16).padStart(2,"0")).join("");return`u_${hex}@${USERNAME_DOMAIN}`;}

export async function register(username,password){const client=requireDb(),name=clean(username);if(!name||Array.from(name).length>32)throw new Error("アカウント名は1～32文字で入力してください。");const{data,error}=await client.auth.signUp({email:await usernameToEmail(name),password,options:{data:{username:name}}});if(error)throw error;return data;}
export async function login(username,password){const client=requireDb();const{data,error}=await client.auth.signInWithPassword({email:await usernameToEmail(username),password});if(error)throw error;return data;}
export async function logout(){if(!db)return;const{error}=await db.auth.signOut();if(error)throw error;}
export async function currentUser(){if(!db)return null;const{data}=await db.auth.getUser();return data.user||null;}
export async function currentUsername(user){if(!db||!user)return"";const{data}=await db.from("profiles").select("username").eq("id",user.id).maybeSingle();return String(data?.username||user.user_metadata?.username||"PLAYER");}
export async function changeUsername(username){const client=requireDb(),name=clean(username);if(!name||Array.from(name).length>32)throw new Error("ユーザー名は1～32文字で入力してください。");const{error}=await client.rpc("change_my_username",{p_username:name,p_login_email:await usernameToEmail(name)});if(error)throw error;return name;}
export async function changePassword(password){if(String(password||"").length<6)throw new Error("パスワードは6文字以上で入力してください。");const{error}=await requireDb().auth.updateUser({password});if(error)throw error;}
export async function loadMyProfile(){const user=await currentUser();if(!user)return null;const{data,error}=await requireDb().from("profiles").select("username,poptomo_id,poptomo_public").eq("id",user.id).single();if(error)throw error;return data;}
export async function savePoptomo(id,isPublic){const value=String(id||"").trim();if(value&&!/^\d{12}$/.test(value))throw new Error("ポプともIDは12桁の数字で入力してください。");const{error}=await requireDb().rpc("update_my_poptomo",{p_poptomo_id:value||null,p_is_public:Boolean(isPublic)});if(error)throw error;}
export function onAuthChange(callback){if(!db)return()=>{};const{data}=db.auth.onAuthStateChange(()=>callback());return()=>data.subscription.unsubscribe();}
