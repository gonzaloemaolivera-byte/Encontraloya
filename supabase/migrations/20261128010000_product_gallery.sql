-- Galería de hasta ocho fotos por publicación.
-- Migración nueva: la migración original de imagen_url ya está aplicada en producción.
alter table public.productos
  add column if not exists imagenes_urls jsonb not null default '[]'::jsonb;

update public.productos
set imagenes_urls = pg_catalog.jsonb_build_array(imagen_url)
where imagen_url is not null
  and imagenes_urls = '[]'::jsonb;

create schema if not exists ey_private;
revoke all on schema ey_private from public, anon, authenticated;
grant usage on schema ey_private to authenticated;

create or replace function ey_private._actualizar_imagenes_publicacion(
  p_publicacion_id uuid,
  p_imagenes_urls jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_comercio_id uuid;
  v_prefix text;
  v_url text;
  v_first_url text;
begin
  if v_uid is null then
    return pg_catalog.jsonb_build_object('ok',false,'mensaje','Iniciá sesión para guardar las fotos.');
  end if;

  if p_imagenes_urls is null
     or pg_catalog.jsonb_typeof(p_imagenes_urls) <> 'array'
     or pg_catalog.jsonb_array_length(p_imagenes_urls) > 8 then
    return pg_catalog.jsonb_build_object('ok',false,'mensaje','La galería debe contener hasta 8 fotos.');
  end if;

  select p.comercio_id into v_comercio_id
  from public.productos p
  join public.comercios c on c.id = p.comercio_id
  where p.id = p_publicacion_id
    and c.propietario_id = v_uid;

  if v_comercio_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'mensaje','No encontramos esa publicación en tu comercio.');
  end if;

  v_prefix := 'https://egvchkzktjaitskcqlnr.supabase.co/storage/v1/object/public/productos/'
    || v_comercio_id::text || '/' || p_publicacion_id::text || '/';

  for v_url in select pg_catalog.jsonb_array_elements_text(p_imagenes_urls)
  loop
    if v_url is null
       or pg_catalog.length(v_url) > 1000
       or pg_catalog.left(v_url,pg_catalog.length(v_prefix)) <> v_prefix
       or v_url !~ '[.](jpg|jpeg|png|webp)$' then
      return pg_catalog.jsonb_build_object('ok',false,'mensaje','Una de las direcciones de foto no es válida para esta publicación.');
    end if;
  end loop;

  v_first_url := case
    when pg_catalog.jsonb_array_length(p_imagenes_urls) > 0 then p_imagenes_urls ->> 0
    else null
  end;

  update public.productos
  set imagenes_urls = p_imagenes_urls,
      imagen_url = v_first_url
  where id = p_publicacion_id
    and comercio_id = v_comercio_id;

  return pg_catalog.jsonb_build_object('ok',true,'mensaje','Galería de fotos guardada.');
end;
$$;

revoke all on function ey_private._actualizar_imagenes_publicacion(uuid,jsonb) from public,anon;
grant execute on function ey_private._actualizar_imagenes_publicacion(uuid,jsonb) to authenticated;

create or replace function public.actualizar_imagenes_publicacion(
  p_publicacion_id uuid,
  p_imagenes_urls jsonb
) returns jsonb
language sql
security invoker
set search_path=''
as $$
  select ey_private._actualizar_imagenes_publicacion(p_publicacion_id,p_imagenes_urls);
$$;

revoke all on function public.actualizar_imagenes_publicacion(uuid,jsonb) from public,anon;
grant execute on function public.actualizar_imagenes_publicacion(uuid,jsonb) to authenticated;
