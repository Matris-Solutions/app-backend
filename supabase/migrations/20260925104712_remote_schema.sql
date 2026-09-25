SET local check_function_bodies = off;

CREATE EXTENSION "postgis" SCHEMA "public";

CREATE TABLE "public"."daily_readings" (
  "id"                  uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "reading_date"        date                     NOT NULL,
  "liturgical_day"      text,
  "liturgical_color"    text,
  "first_reading_ref"   text,
  "first_reading_text"  text,
  "psalm_ref"           text,
  "psalm_text"          text,
  "second_reading_ref"  text,
  "second_reading_text" text,
  "gospel_ref"          text,
  "gospel_text"         text,
  "created_by"          uuid,
  "created_at"          timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"          timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "daily_readings_pkey" PRIMARY KEY (id),
  CONSTRAINT "daily_readings_reading_date_key" UNIQUE (reading_date)
);

ALTER TABLE "public"."daily_readings"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."events" (
  "id"               uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "parish_id"        uuid                     NOT NULL,
  "title"            text                     NOT NULL,
  "description"      text,
  "start_time"       timestamp with time zone NOT NULL,
  "end_time"         timestamp with time zone,
  "location_name"    text,
  "location_address" text,
  "created_by"       uuid,
  "created_at"       timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"       timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "events_end_after_start_check" CHECK (((end_time IS NULL) OR (end_time >= start_time))),
  CONSTRAINT "events_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."events"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."mass_times" (
  "id"            uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "parish_id"     uuid                     NOT NULL,
  "day_of_week"   smallint,
  "specific_date" date,
  "mass_time"     time without time zone   NOT NULL,
  "language"      text                     NOT NULL DEFAULT 'English'::text,
  "mass_type"     text                     NOT NULL DEFAULT 'Sunday'::text,
  "notes"         text,
  "created_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"    timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "mass_times_day_of_week_check" CHECK (((day_of_week >= 0) AND (day_of_week <= 6))),
  CONSTRAINT "mass_times_day_or_date_check" CHECK ((((day_of_week IS NOT NULL) AND (specific_date IS NULL)) OR ((day_of_week IS NULL) AND (specific_date IS NOT NULL)))),
  CONSTRAINT "mass_times_mass_type_check" CHECK ((mass_type = ANY (ARRAY['Sunday'::text, 'Saturday Vigil'::text, 'Weekday'::text, 'Holy Day'::text, 'Special'::text]))),
  CONSTRAINT "mass_times_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."mass_times"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."parishes" (
  "id"                 uuid                         NOT NULL DEFAULT gen_random_uuid(),
  "name"               text                         NOT NULL,
  "diocese"            text,
  "address_line1"      text                         NOT NULL,
  "address_line2"      text,
  "city"               text                         NOT NULL,
  "province"           text,
  "postal_code"        text,
  "country"            text                         NOT NULL DEFAULT 'South Africa'::text,
  "location"           public.geography(Point,4326),
  "phone"              text,
  "email"              text,
  "website"            text,
  "parish_priest_name" text,
  "activities"         text[],
  "image_url"          text,
  "is_active"          boolean                      NOT NULL DEFAULT true,
  "created_by"         uuid,
  "created_at"         timestamp with time zone     NOT NULL DEFAULT now(),
  "updated_at"         timestamp with time zone     NOT NULL DEFAULT now(),
  CONSTRAINT "parishes_pkey" PRIMARY KEY (id),
  CONSTRAINT "parishes_province_check"
    CHECK
    ((province = ANY (ARRAY['Eastern Cape'::text, 'Free State'::text, 'Gauteng'::text, 'KwaZulu-Natal'::text, 'Limpopo'::text, 'Mpumalanga'::text, 'North West'::text,
    'Northern Cape'::text, 'Western Cape'::text])))
);

ALTER TABLE "public"."parishes"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."profiles" (
  "id"                 uuid                     NOT NULL,
  "full_name"          text,
  "email"              text,
  "phone"              text,
  "assigned_parish_id" uuid,
  "created_at"         timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"         timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "profiles_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."profiles"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "public"."user_role" AS ENUM (
  'regular_user',
  'parish_admin',
  'super_admin'
);

ALTER TABLE "public"."profiles"
  ADD COLUMN "role" public.user_role NOT NULL DEFAULT 'regular_user'::public.user_role;

CREATE OR REPLACE FUNCTION public.get_my_role()
  RETURNS public.user_role
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select role from public.profiles where id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    'regular_user'
  )
  on conflict (id) do nothing;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.is_parish_admin_of (
  p_parish_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'parish_admin'
      and assigned_parish_id = p_parish_id
  );
$function$;

CREATE OR REPLACE FUNCTION public.nearest_parishes (
  user_lat        double precision,
  user_lng        double precision,
  max_distance_km double precision DEFAULT 50,
  result_limit    integer          DEFAULT 10
)
  RETURNS TABLE (
    id            uuid,
    name          text,
    address_line1 text,
    city          text,
    province      text,
    phone         text,
    distance_km   double precision,
    latitude      double precision,
    longitude     double precision
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
  AS $function$
  select
    p.id,
    p.name,
    p.address_line1,
    p.city,
    p.province,
    p.phone,
    st_distance(p.location, st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography) / 1000.0 as distance_km,
    st_y(p.location::geometry) as latitude,
    st_x(p.location::geometry) as longitude
  from public.parishes p
  where p.is_active
    and p.location is not null
    and st_dwithin(
          p.location,
          st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography,
          max_distance_km * 1000
        )
  order by p.location <-> st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography
  limit result_limit;
$function$;

CREATE OR REPLACE FUNCTION public.prevent_role_privilege_escalation()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
begin
  if (new.role is distinct from old.role
      or new.assigned_parish_id is distinct from old.assigned_parish_id)
     and public.get_my_role() is distinct from 'super_admin' then
    raise exception 'Only a super_admin may change role or assigned_parish_id.';
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

ALTER TABLE "public"."events"
  ADD CONSTRAINT "events_parish_id_fkey" FOREIGN KEY (parish_id) REFERENCES public.parishes(id) ON DELETE CASCADE;

ALTER TABLE "public"."mass_times"
  ADD CONSTRAINT "mass_times_parish_id_fkey" FOREIGN KEY (parish_id) REFERENCES public.parishes(id) ON DELETE CASCADE;

ALTER TABLE "public"."profiles"
  ADD CONSTRAINT "profiles_assigned_parish_id_fkey" FOREIGN KEY (assigned_parish_id) REFERENCES public.parishes(id) ON DELETE SET NULL;

ALTER TABLE "public"."profiles"
  ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."daily_readings"
  ADD CONSTRAINT "daily_readings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE "public"."events"
  ADD CONSTRAINT "events_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE "public"."parishes"
  ADD CONSTRAINT "parishes_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

CREATE INDEX idx_daily_readings_date ON public.daily_readings USING btree (reading_date);

CREATE INDEX idx_events_parish_id ON public.events USING btree (parish_id);

CREATE INDEX idx_events_start_time ON public.events USING btree (start_time);

CREATE INDEX idx_mass_times_day_of_week ON public.mass_times USING btree (day_of_week);

CREATE INDEX idx_mass_times_parish_id ON public.mass_times USING btree (parish_id);

CREATE INDEX idx_mass_times_specific_date ON public.mass_times USING btree (specific_date);

CREATE INDEX idx_parishes_is_active ON public.parishes USING btree (is_active);

CREATE INDEX idx_parishes_location_gist ON public.parishes USING gist (location);

CREATE INDEX idx_parishes_province ON public.parishes USING btree (province);

CREATE INDEX idx_profiles_assigned_parish_id ON public.profiles USING btree (assigned_parish_id);

CREATE INDEX idx_profiles_role ON public.profiles USING btree (ROLE);

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

CREATE TRIGGER trg_daily_readings_updated_at
  BEFORE UPDATE ON public.daily_readings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_events_updated_at
  BEFORE UPDATE ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_mass_times_updated_at
  BEFORE UPDATE ON public.mass_times
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_parishes_updated_at
  BEFORE UPDATE ON public.parishes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_prevent_role_escalation
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_role_privilege_escalation();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE POLICY "daily_readings_delete_super_admin" ON "public"."daily_readings"
  FOR DELETE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "daily_readings_insert_super_admin" ON "public"."daily_readings"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "daily_readings_select_public" ON "public"."daily_readings"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "daily_readings_update_super_admin" ON "public"."daily_readings"
  FOR UPDATE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role))
  WITH CHECK ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "events_delete_super_admin" ON "public"."events"
  FOR DELETE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "events_insert_own_or_super_admin" ON "public"."events"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)));

CREATE POLICY "events_select_public" ON "public"."events"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "events_update_own_or_super_admin" ON "public"."events"
  FOR UPDATE
  TO "authenticated"
  USING (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)))
  WITH CHECK (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)));

CREATE POLICY "mass_times_delete_super_admin" ON "public"."mass_times"
  FOR DELETE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "mass_times_insert_own_or_super_admin" ON "public"."mass_times"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)));

CREATE POLICY "mass_times_select_public" ON "public"."mass_times"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "mass_times_update_own_or_super_admin" ON "public"."mass_times"
  FOR UPDATE
  TO "authenticated"
  USING (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)))
  WITH CHECK (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(parish_id)));

CREATE POLICY "parishes_delete_super_admin" ON "public"."parishes"
  FOR DELETE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "parishes_insert_super_admin" ON "public"."parishes"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "parishes_select_public" ON "public"."parishes"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "parishes_update_own_or_super_admin" ON "public"."parishes"
  FOR UPDATE
  TO "authenticated"
  USING (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(id)))
  WITH CHECK (((public.get_my_role() = 'super_admin'::public.user_role) OR public.is_parish_admin_of(id)));

CREATE POLICY "profiles_delete_admin_only" ON "public"."profiles"
  FOR DELETE
  TO "authenticated"
  USING ((public.get_my_role() = 'super_admin'::public.user_role));

CREATE POLICY "profiles_insert_own" ON "public"."profiles"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((id = auth.uid()));

CREATE POLICY "profiles_select_own_or_admin" ON "public"."profiles"
  FOR SELECT
  TO "authenticated"
  USING (((id = auth.uid()) OR (public.get_my_role() = 'super_admin'::public.user_role)));

CREATE POLICY "profiles_update_own_or_admin" ON "public"."profiles"
  FOR UPDATE
  TO "authenticated"
  USING (((id = auth.uid()) OR (public.get_my_role() = 'super_admin'::public.user_role)))
  WITH CHECK (((id = auth.uid()) OR (public.get_my_role() = 'super_admin'::public.user_role)));

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

COMMENT ON EXTENSION "postgis" IS 'PostGIS geometry and geography spatial types and functions';

GRANT EXECUTE ON FUNCTION "public"."get_my_role"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."is_parish_admin_of"(uuid) TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."nearest_parishes"(double precision, double precision, double precision, integer) TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."prevent_role_privilege_escalation"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."set_updated_at"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."daily_readings" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."events" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."mass_times" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."parishes" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."profiles" TO "anon", "authenticated", "postgres", "service_role";

GRANT USAGE ON TYPE "public"."user_role" TO "postgres";

