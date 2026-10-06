-- every sequence that feeds a column is set to the column's maximum plus one (ids beyond the sequence range, as in oc_jobs, are ignored) (occ db:convert-type copies the rows but not the counters)
DO $$ DECLARE r record; n int := 0; BEGIN
  FOR r IN SELECT c.table_name t, c.column_name col FROM information_schema.columns c
           WHERE c.table_schema = 'public' AND pg_get_serial_sequence(quote_ident(c.table_name), c.column_name) IS NOT NULL LOOP
    EXECUTE format('SELECT setval(pg_get_serial_sequence(%L, %L), COALESCE((SELECT MAX(%I) FROM %I WHERE %I < 2147483647), 0) + 1, false)', quote_ident(r.t), r.col, r.col, r.t, r.col);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'sequences reset: %', n;
END $$;
