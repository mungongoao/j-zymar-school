-- Corrige a referência ambígua a usage_date na função de heartbeat.
-- Seguro para executar após a migração inicial; não altera dados existentes.
CREATE OR REPLACE FUNCTION public.teacher_usage_heartbeat()
RETURNS TABLE(
  enabled boolean,
  allowed_weekdays smallint[],
  used_seconds integer,
  limit_seconds integer,
  remaining_seconds integer,
  session_active boolean,
  usage_date date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Africa/Luanda')::date;
  v_usage public.teacher_daily_usage%ROWTYPE;
  v_access public.teacher_access_control%ROWTYPE;
  v_elapsed integer := 0;
  v_limit integer := public.teacher_daily_limit_seconds(now());
BEGIN
  IF v_user_id IS NULL OR NOT public.has_role(v_user_id, 'professor') THEN
    RAISE EXCEPTION 'Sem permissão.';
  END IF;

  SELECT *
    INTO v_access
    FROM public.teacher_access_control AS access_row
   WHERE access_row.user_id = v_user_id;

  IF NOT FOUND
     OR NOT v_access.enabled
     OR NOT (
       extract(isodow FROM now() AT TIME ZONE 'Africa/Luanda')::smallint
       = ANY(v_access.allowed_weekdays)
     ) THEN
    RAISE EXCEPTION 'Acesso não autorizado hoje.';
  END IF;

  SELECT *
    INTO v_usage
    FROM public.teacher_daily_usage AS usage_row
   WHERE usage_row.user_id = v_user_id
     AND usage_row.usage_date = v_today
   FOR UPDATE;

  IF NOT FOUND OR NOT v_usage.session_active THEN
    RAISE EXCEPTION 'Sessão não activa.';
  END IF;

  IF v_usage.last_heartbeat_at IS NOT NULL
     AND now() - v_usage.last_heartbeat_at <= interval '45 seconds' THEN
    v_elapsed := greatest(
      0,
      floor(extract(epoch FROM now() - v_usage.last_heartbeat_at))::integer
    );
  END IF;

  UPDATE public.teacher_daily_usage AS usage_row
     SET used_seconds = least(v_limit, usage_row.used_seconds + v_elapsed),
         session_active = (usage_row.used_seconds + v_elapsed < v_limit),
         last_heartbeat_at = now(),
         updated_at = now()
   WHERE usage_row.user_id = v_user_id
     AND usage_row.usage_date = v_today;

  RETURN QUERY
  SELECT status_row.enabled,
         status_row.allowed_weekdays,
         status_row.used_seconds,
         status_row.limit_seconds,
         status_row.remaining_seconds,
         status_row.session_active,
         status_row.usage_date
    FROM public.teacher_usage_status() AS status_row;
END;
$$;

REVOKE ALL ON FUNCTION public.teacher_usage_heartbeat() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.teacher_usage_heartbeat() TO authenticated;
