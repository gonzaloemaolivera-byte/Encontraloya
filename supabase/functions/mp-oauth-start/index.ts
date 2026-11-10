import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods":"POST, OPTIONS", "Content-Type":"application/json; charset=utf-8", "Cache-Control":"no-store" };
const reply = (status:number, body:Record<string,unknown>) => new Response(JSON.stringify(body),{status,headers:cors});
const env = (name:string) => { const value=Deno.env.get(name); if(!value) throw new Error("Missing "+name); return value; };
const b64url = (bytes:Uint8Array) => { let s=""; for(const b of bytes)s+=String.fromCharCode(b); return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,""); };
const sha256 = async (s:string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s)))).map(b=>b.toString(16).padStart(2,"0")).join("");

Deno.serve(async (req:Request)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
 if(req.method!=="POST") return reply(405,{ok:false,mensaje:"Método no permitido"});
 try {
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!jwt) return reply(401,{ok:false,mensaje:"Iniciá sesión en el panel del comercio."});
  const url=env("SUPABASE_URL"), anon=env("SUPABASE_ANON_KEY");
  const authClient=createClient(url,anon,{global:{headers:{Authorization:`Bearer ${jwt}`}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:userData,error:userError}=await authClient.auth.getUser(jwt);
  if(userError||!userData.user) return reply(401,{ok:false,mensaje:"La sesión venció. Volvé a iniciar sesión."});
  const body=await req.json().catch(()=>({}));
  const comercioId=String(body.comercio_id||"");
  if(!/^[0-9a-f-]{36}$/i.test(comercioId)) return reply(400,{ok:false,mensaje:"Comercio inválido."});
  const admin=createClient(url,env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:shop,error:shopError}=await admin.from("comercios").select("id,propietario_id").eq("id",comercioId).maybeSingle();
  if(shopError||!shop||shop.propietario_id!==userData.user.id) return reply(403,{ok:false,mensaje:"No tenés permiso para vincular este comercio."});
  const state=b64url(crypto.getRandomValues(new Uint8Array(32)));
  const {error:stateError}=await admin.from("mercado_pago_oauth_states_privado").insert({state_hash:await sha256(state),comercio_id:comercioId,propietario_id:userData.user.id,expira_at:new Date(Date.now()+600000).toISOString()});
  if(stateError) throw stateError;
  const authUrl=new URL("https://auth.mercadopago.com.ar/authorization");
  authUrl.searchParams.set("client_id",env("MP_CLIENT_ID"));
  authUrl.searchParams.set("response_type","code");
  authUrl.searchParams.set("platform_id","mp");
  authUrl.searchParams.set("state",state);
  authUrl.searchParams.set("redirect_uri",env("MP_REDIRECT_URI"));
  return reply(200,{ok:true,authorization_url:authUrl.toString()});
 } catch(error) { console.error("mp-oauth-start",error); return reply(500,{ok:false,mensaje:"No pudimos iniciar la vinculación con Mercado Pago."}); }
});
