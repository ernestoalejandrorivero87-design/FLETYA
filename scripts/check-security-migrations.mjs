import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const files = {
  profiles: 'supabase/migrations/20261018000000_guard_profile_role_changes.sql',
  rls: 'supabase/migrations/20261018001000_enforce_roles_in_rls.sql',
  functions: 'supabase/migrations/20261018002000_restrict_security_definer_execution.sql',
  jobs: 'supabase/migrations/20261018003000_guard_job_update_columns.sql',
  grants: 'supabase/migrations/20261018004000_restrict_table_privileges.sql',
  privateAdmin: 'supabase/migrations/20261022090000_move_is_admin_to_private_schema.sql',
};
const sql = Object.fromEntries(
  Object.entries(files).map(([key, path]) => [key, readFileSync(join(root, path), 'utf8')])
);

const checks = [
  ['signup metadata cannot assign admin', /when new\.raw_user_meta_data ->> 'role' = 'driver' then 'driver'\s+else 'client'/i.test(sql.profiles)],
  ['profile role changes are guarded', /before insert or update of role on public\.profiles/i.test(sql.profiles)],
  ['clients can only create their own requested jobs', /auth\.uid\(\) = client_id/i.test(sql.rls) && /p\.role = 'client'/i.test(sql.rls) && /driver_id is null/i.test(sql.rls)],
  ['driver job transitions check the driver role', /p\.role = 'driver'/i.test(sql.rls) && /status = 'completed'/i.test(sql.rls)],
  ['GPS writes are tied to the assigned en-route job', (sql.rls.match(/j\.driver_id = auth\.uid\(\)\s+and j\.status = 'en_route'/ig) || []).length >= 2],
  ['trigger-only functions have direct execute revoked', /revoke all on function public\.handle_new_user\(\) from authenticated/i.test(sql.functions) && /revoke all on function public\.notify_drivers_new_job\(\) from authenticated/i.test(sql.functions)],
  ['admin helper is moved out of the public API schema', /create schema if not exists private/i.test(sql.privateAdmin) && /create or replace function private\.is_admin\(\)/i.test(sql.privateAdmin) && /alter policy "Admins can view all profiles"\s+on public\.profiles\s+using \(private\.is_admin\(\)\)/i.test(sql.privateAdmin) && /drop function public\.is_admin\(\)/i.test(sql.privateAdmin)],
  ['job guard uses the private admin helper', /create or replace function public\.guard_job_updates\(\)/i.test(sql.privateAdmin) && /actor_role = 'admin' and private\.is_admin\(\)/i.test(sql.privateAdmin) && !/actor_role = 'admin' and public\.is_admin\(\)/i.test(sql.privateAdmin)],
  ['job guard covers inserts and updates', /before insert or update on public\.jobs/i.test(sql.jobs)],
  ['job creation rejects missing or invalid status', /new\.status is distinct from 'requested'/i.test(sql.jobs)],
  ['drivers cannot edit job details or payment flags', /new\.driver_paid is distinct from old\.driver_paid/i.test(sql.jobs) && /Drivers cannot edit job details or payment flags/i.test(sql.jobs)],
  ['admin payment changes require a completed unpaid job', /old\.status = 'completed' and coalesce\(old\.driver_paid, false\) = false and new\.driver_paid = true/i.test(sql.jobs)],
  ['anon table grants are revoked', /revoke all privileges on table public\.jobs from anon/i.test(sql.grants) && /revoke all privileges on table public\.profiles from anon/i.test(sql.grants)],
  ['authenticated grants exclude notification insert', /grant select on table public\.notifications to authenticated/i.test(sql.grants) && /grant update\s*\(\s*read\s*\)\s+on table public\.notifications to authenticated/i.test(sql.grants) && !/grant select,\s*(?:insert|update) on table public\.notifications to authenticated/i.test(sql.grants)],
  ['future default table and sequence grants are narrowed', /alter default privileges for role postgres in schema public\s+revoke all privileges on tables from anon, authenticated/i.test(sql.grants) && /alter default privileges for role postgres in schema public\s+revoke all privileges on sequences from anon, authenticated/i.test(sql.grants)],
];

let failed = false;
for (const [label, passed] of checks) {
  process.stdout.write((passed ? 'PASS' : 'FAIL') + '  ' + label + '\\n');
  if (!passed) failed = true;
}
process.stdout.write('\\n' + checks.filter(([, passed]) => passed).length + '/' + checks.length + ' static checks passed.\\n');
if (failed) {
  process.stderr.write('Static security checks failed. Review the migration files before proceeding.\\n');
  process.exitCode = 1;
} else {
  process.stdout.write('Note: these checks inspect expected SQL patterns only; they do not execute SQL or replace PostgreSQL integration tests.\\n');
}
