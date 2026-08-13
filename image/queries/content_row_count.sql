-- Sums *actual* COUNT(*) (not pg_stat_user_tables.n_live_tup, which is an
-- autovacuum/ANALYZE-driven estimate and can be stale or zero on
-- rarely-touched tables even when they hold real rows) across every user
-- table except known Django/DRF/Celery framework and Plane instance-config
-- tables. Those are populated the instant migrations finish, before any
-- real onboarding or usage, and would otherwise make a genuinely empty
-- Plane instance look non-empty (see README.md's Troubleshooting section).
--
-- This excluded-table list was derived from a real side-by-side comparison
-- of a freshly-migrated (pre-onboarding) instance against a populated
-- production instance via scripts/check_table_rows.py, not guessed. If a
-- future Plane/chart version introduces new framework-only tables, re-run
-- that script against a fresh instance and extend the list below.
select coalesce(sum(cnt), 0)
from (
  select (
    xpath(
      '/row/c/text()',
      query_to_xml(format('select count(*) as c from %I.%I', schemaname, relname), false, true, '')
    )
  )[1]::text::bigint as cnt
  from pg_stat_user_tables
  where relname not in (
    'auth_permission', 'auth_group', 'auth_group_permissions',
    'django_content_type', 'django_migrations', 'django_admin_log', 'django_session',
    'instance_configurations', 'instances',
    'django_celery_beat_periodictask', 'django_celery_beat_periodictasks',
    'django_celery_beat_crontabschedule', 'django_celery_beat_intervalschedule',
    'django_celery_beat_clockedschedule'
  )
) t;
