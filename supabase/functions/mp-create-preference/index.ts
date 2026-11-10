import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors={ "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods":"POST, OPTIONS", "Content-Type":"application/json; charset=utf-8", "Cache-Control":"no-store" };
const reply=(status:number,body:Record<string,unknown>)=>new Response(JSON.stringify(body),{status,headers:cors});
const env=(name:string)=>{const value=Deno.env.get(name);if(!value)throw new Error("Missing "+name);return value;};
const fromB64=(s:string)=>{const v=s.replace(/-/g,"+").replace(/_/g,"/");return Uint8Array.from(atob(v+"=".repeat((4-v.length%4)%4)),c=>c.charCodeAt(0));};
const toB64=(b:Uint8Array)=>{let s="";for(const x of b)s+=String.fromCharCode(x);return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"");};
async function decrypt(value:string){const [n,c]=value.split(".");if(!n||!c)throw new Error("Token cifrado inválido");const raw=fromB64(env("MP_TOKEN_ENCRYPTION_KEY"));if(raw.length!==32)throw new Error("Clave de cifrado inválida");const key=await crypto.subtle.importKey("raw",raw,"AES-GCM",false,["decrypt"]);const plain=await crypto.subtle.decrypt({name:"AES-GCM",iv:fromB64(n)},key,fromB64(c));return new TextDecoder().decode(plain);}
async function encrypt(value:string){const raw=fromB64(env("MP_TOKEN_ENCRYPTION_KEY"));if(raw.length!==32)throw new Error("Clave de cifrado inválida");const key=await crypto.subtle.importKey("raw",raw,"AES-GCM",false,["encrypt"]);const iv=crypto.getRandomValues(new Uint8Array(12));const data=await crypto.subtle.encrypt({name:"AES-GCM",iv},key,new TextEncoder().encode(value));return toB64(iv)+"."+toB64(new Uint8Array(data));}
async function sellerToken(admin:any, row:any){
 let access=await decrypt(row.access_token_enc);
 if(new Date(row.expires_at).getTime()>Date.now()+30*24*60*60*1000)return access;
 const form=new URLSearchParams({client_id:env("MP_CLIENT_ID"),client_secret:env("MP_CLIENT_SECRET"),grant_type:"refresh_token",refresh_token:await decrypt(row.refresh_token_enc)});
 const response=await fetch("https://api.mercadopago.com/oauth/token",{method:"POST",headers:{"Accept":"application/json","Content-Type":"application/x-www-form-urlencoded"},body:form});
 const data=await response.json().catch(()=>({}));
 if(!response.ok||!data.access_token||!data.refresh_token)throw new Error("No se pudo renovar la autorización de Mercado Pago");
 const expiresAt=new Date(Date.now()+Number(data.expires_in||15552000)*1000).toISOString();
 const {error}=await admin.from("mercado_pago_tokens_privado").update({access_token_enc:await encrypt(String(data.access_token)),refresh_token_enc:await encrypt(String(data.refresh_token)),expires_at:expiresAt,public_key:data.public_key||row.public_key,live_mode:Boolean(data.live_mode),scope:data.scope||row.scope,actualizado_at:new Date().toISOString()}).eq("comercio_id",row.comercio_id);
 if(error)throw error;
 return String(data.access_token);
}

Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply(405,{ok:false,mensaje:"Método no permitido"});
 try{
  const body=await req.json().catch(()=>({}));
  const pedidoId=String(body.pedido_id||"");
  if(!/^[0-9a-f-]{36}$/i.test(pedidoId))return reply(400,{ok:false,mensaje:"Pedido inválido."});
  const admin=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:order,error:orderError}=await admin.from("pedidos").select("id,comercio_id,estado,total,moneda,pedido_productos(nombre_producto,cantidad,subtotal)").eq("id",pedidoId).maybeSingle();
  if(orderError||!order)return reply(404,{ok:false,mensaje:"No encontramos el pedido."});
  if(order.estado!=="pendiente")return reply(409,{ok:false,mensaje:"Este pedido ya no está pendiente de pago."});
  if(order.moneda!=="ARS"||Number(order.total)<=0)return reply(400,{ok:false,mensaje:"El pedido no tiene un total válido en pesos argentinos."});
  const {data:existing}=await admin.from("pagos").select("estado,datos_operativos").eq("pedido_id",pedidoId).eq("proveedor","mercado_pago").maybeSingle();
  const oldUrl=existing?.datos_operativos?.checkout_url;
  if(existing?.estado==="pendiente"&&typeof oldUrl==="string"&&oldUrl.startsWith("https://"))return reply(200,{ok:true,checkout_url:oldUrl,reutilizado:true});
  const {data:connection,error:connectionError}=await admin.from("conexiones_mercado_pago").select("estado,usuario_mercado_pago_id").eq("comercio_id",order.comercio_id).maybeSingle();
  if(connectionError||connection?.estado!=="conectado")return reply(409,{ok:false,mensaje:"Este comercio todavía no vinculó su cuenta de Mercado Pago."});
  const {data:tokenRow,error:tokenError}=await admin.from("mercado_pago_tokens_privado").select("*").eq("comercio_id",order.comercio_id).maybeSingle();
  if(tokenError||!tokenRow)return reply(409,{ok:false,mensaje:"La conexión de Mercado Pago necesita volver a autorizarse."});
  const {data:commission,error:commissionError}=await admin.from("comisiones").select("porcentaje,base_calculo,importe_comision").eq("pedido_id",pedidoId).maybeSingle();
  if(commissionError||!commission)return reply(500,{ok:false,mensaje:"No pudimos calcular la comisión de la plataforma."});
  const token=await sellerToken(admin,tokenRow);
  const items=(order.pedido_productos||[]).map((item:any)=>({id:undefined,title:String(item.nombre_producto||"Producto").slice(0,250)+(Number(item.cantidad)!==1?" x "+String(item.cantidad):""),quantity:1,currency_id:"ARS",unit_price:Number(Number(item.subtotal).toFixed(2))}));
  if(!items.length||items.some((item:any)=>!Number.isFinite(item.unit_price)||item.unit_price<=0))return reply(400,{ok:false,mensaje:"El pedido no tiene productos con importes válidos."});
  const site=env("SITE_URL").replace(/\/$/,"");
  const webhook=env("SUPABASE_URL").replace(/\/$/,"")+"/functions/v1/mp-payment-webhook";
  const preference={
   items,
   external_reference:pedidoId,
   marketplace_fee:Number(Number(commission.importe_comision).toFixed(2)),
   notification_url:webhook,
   back_urls:{success:site+"/index.html?pago=exito&pedido="+encodeURIComponent(pedidoId),pending:site+"/index.html?pago=pendiente&pedido="+encodeURIComponent(pedidoId),failure:site+"/index.html?pago=error&pedido="+encodeURIComponent(pedidoId)},
   auto_return:"approved",
   statement_descriptor:"ENCONTRALO YA",
   metadata:{pedido_id:pedidoId,comercio_id:order.comercio_id}
  };
  const response=await fetch("https://api.mercadopago.com/checkout/preferences",{method:"POST",headers:{"Authorization":"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify(preference)});
  const data=await response.json().catch(()=>({}));
  if(!response.ok||!data.id||!data.init_point) {
   console.error("Preference creation failed:",response.status,data.message||data.error||"sin detalle");
   return reply(502,{ok:false,mensaje:"Mercado Pago no pudo crear el checkout. Volvé a intentar."});
  }
  const checkoutUrl=tokenRow.live_mode?String(data.init_point):String(data.sandbox_init_point||data.init_point);
  const idempotency="mp-order-"+pedidoId;
  const {error:paymentError}=await admin.from("pagos").upsert({
   pedido_id:pedidoId,medio_pago:"mercado_pago",proveedor:"mercado_pago",estado:"pendiente",importe:Number(order.total),moneda:"ARS",referencia_externa:String(data.id),idempotencia:idempotency,
   datos_operativos:{preference_id:String(data.id),checkout_url:checkoutUrl,live_mode:Boolean(tokenRow.live_mode),marketplace_fee:Number(commission.importe_comision),created_at:new Date().toISOString()},
   actualizado_at:new Date().toISOString()
  },{onConflict:"idempotencia"});
  if(paymentError)throw paymentError;
  return reply(200,{ok:true,checkout_url:checkoutUrl,preference_id:String(data.id)});
 }catch(error){console.error("mp-create-preference",error);return reply(500,{ok:false,mensaje:"No pudimos preparar el pago. Intentá nuevamente."});}
});
